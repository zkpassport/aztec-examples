import {
  type ContractArtifact,
  type NoirCompiledContract,
  loadContractArtifact,
} from "@aztec-labs/aztec.js/abi"
import { AztecAddress } from "@aztec-labs/aztec.js/addresses"
import {
  Contract,
  getContractInstanceFromInstantiationParams,
} from "@aztec-labs/aztec.js/contracts"
import { SponsoredFeePaymentMethod } from "@aztec-labs/aztec.js/fee"
import { Fr } from "@aztec-labs/aztec.js/fields"
import { createAztecNodeClient } from "@aztec-labs/aztec.js/node"
import { SPONSORED_FPC_SALT } from "@aztec-labs/constants"
import { SponsoredFPCContractArtifact } from "@aztec-labs/noir-contracts.js/SponsoredFPC"
import { getContractClassFromArtifact } from "@aztec-labs/stdlib/contract"
import { deriveMasterMessageSigningSecretKey } from "@aztec-labs/stdlib/keys"
import { EmbeddedWallet } from "@aztec-labs/wallets/embedded"
import { registerInitialLocalNetworkAccountsInWallet } from "@aztec-labs/wallets/testing"
import { registerZKPassportRegistry, toAztecCapsules } from "@zkpassport/aztec"
import type { AztecNetwork, ProofResult } from "@zkpassport/sdk"
import { getIdFromChain } from "@zkpassport/utils"
import { getScopeHash } from "@zkpassport/utils/circuit-matcher"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import FortunaMarketJson from "../../target/fortuna_market_contract-FortunaMarket.json" with { type: "json" }
import ZKPassportCredentialsJson from "../../target/zkpassport_credentials_contract-ZKPassportCredentials.json" with { type: "json" }
import { LOCAL_NETWORK_L1_CHAIN_ID, setUpLocalNetworkRegistry } from "./local-network"

// The SDK's ESM build doesn't load in Node: it imports `buffer/` and named exports of a CommonJS
// package. Its CommonJS build does.
const { ZKPassport } = createRequire(import.meta.url)(
  "@zkpassport/sdk",
) as typeof import("@zkpassport/sdk")
type ZKPassport = InstanceType<typeof ZKPassport>

export type GateMode = "live" | "dev"

/**
 * The 18+ policies the relayer creates on each credentials contract: one claim per passport, or
 * repeatable
 */
const ADULTS_ONCE = 1
const ADULTS_REPEATABLE = 2

/** ZKPassportCredentials' AGE_MIN requirement */
const AGE_MIN = 1

/** The chain whose registries the network's ZKPassport registry mirrors, which proofs must be made against */
export type SourceChain = "ethereum" | "ethereum_sepolia"

export interface RelayerConfig {
  nodeUrl: string
  /** ZKPassport's registry on the network; on a local network the relayer deploys its own */
  registryAddress: string
  /** The domain the app is served from, which its ZKPassport requests carry */
  domain: string
  /**
   * Whether the markets take the 18+ policy each passport claims once, or the repeatable one, as in
   * testing
   */
  oneClaimPerPassport: boolean
  deploymentsPath: string
}

type Fee = { paymentMethod: SponsoredFeePaymentMethod } | undefined

const WAIT = { timeout: 3600, interval: 2 } as const

/**
 * Submits users' age proofs to Fortuna's two ZKPassportCredentials contracts, one that accepts only
 * real passports and one in dev mode that also accepts ZKPassport's mock passports.
 */
export class Relayer {
  private queue: Promise<unknown> = Promise.resolve()

  private constructor(
    private readonly credentials: Record<GateMode, Contract>,
    /** The market each credentials contract's policy opens */
    private readonly markets: Record<GateMode, Contract>,
    /** The 18+ policy the markets take */
    readonly policyId: number,
    private readonly account: AztecAddress,
    private readonly fee: Fee,
    private readonly zkpassport: ZKPassport,
    readonly sourceChain: SourceChain,
    /** The network a proof must be bound to, if ZKPassport can bind one to this network */
    readonly network: AztecNetwork | undefined,
  ) {}

  /**
   * Connects the relayer's account and deploys the contracts the deployments file does not list on
   * the node. On a local network the account is a test account, and the relayer sets up the registry.
   */
  static async start(config: RelayerConfig): Promise<Relayer> {
    const node = createAztecNodeClient(config.nodeUrl)
    const wallet = await EmbeddedWallet.create(config.nodeUrl, {
      ephemeral: true,
      pxe: { proverEnabled: true },
    })
    const { l1ChainId, rollupVersion } = await node.getNodeInfo()

    let account: AztecAddress
    let fee: Fee
    if (l1ChainId === LOCAL_NETWORK_L1_CHAIN_ID) {
      const [admin, operator] = await registerInitialLocalNetworkAccountsInWallet(wallet)
      await setUpLocalNetworkRegistry(node, config.nodeUrl, wallet, admin, operator)
      account = admin
    } else {
      const secret = Fr.random()
      account = (
        await wallet.createSchnorrInitializerlessAccount(
          secret,
          new Fr(0),
          deriveMasterMessageSigningSecretKey(secret),
        )
      ).address
      const fpc = await getContractInstanceFromInstantiationParams(SponsoredFPCContractArtifact, {
        salt: new Fr(SPONSORED_FPC_SALT),
      })
      await wallet.registerContract(fpc, SponsoredFPCContractArtifact)
      fee = { paymentMethod: new SponsoredFeePaymentMethod(fpc.address) }

      await registerZKPassportRegistry(wallet, node, config.registryAddress)
    }

    const deployments = readDeployments(config.deploymentsPath)
    const key = `${config.nodeUrl}|${config.domain}`

    // Reuses the contract recorded under `name` while the node has it with this artifact's code,
    // and deploys it otherwise, running `setUp` on it before recording it
    async function deployed(
      name: string,
      contractArtifact: ContractArtifact,
      args: unknown[],
      setUp?: (contract: Contract) => Promise<void>,
    ): Promise<Contract> {
      const recorded = deployments[key]?.[name]
      const instance = recorded
        ? await node.getContract(AztecAddress.fromStringUnsafe(recorded))
        : undefined
      const { id: classId } = await getContractClassFromArtifact(contractArtifact)
      if (instance?.currentContractClassId.equals(classId)) {
        await wallet.registerContract(instance, contractArtifact)
        return Contract.at(instance.address, contractArtifact, wallet)
      }

      console.log(`Deploying ${contractArtifact.name} (${name}) for ${config.domain}...`)
      const { contract } = await Contract.deploy(wallet, contractArtifact, args).send({
        from: account,
        ...(fee ? { fee } : {}),
        wait: WAIT,
      })
      await setUp?.(contract)
      deployments[key] = { ...deployments[key], [name]: contract.address.toString() }
      writeFileSync(config.deploymentsPath, JSON.stringify(deployments, null, 2) + "\n")
      return contract
    }

    const zkpassportCredentials = artifact(ZKPassportCredentialsJson)
    const fortunaMarket = artifact(FortunaMarketJson)
    const domainHash = new Fr(getScopeHash(config.domain))
    const policyId = config.oneClaimPerPassport ? ADULTS_ONCE : ADULTS_REPEATABLE
    const credentials = {} as Record<GateMode, Contract>
    const markets = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      credentials[mode] = await deployed(
        `${mode}Credentials`,
        zkpassportCredentials,
        [domainHash, mode === "dev"],
        async (contract) => {
          for (const [id, oneClaimPerPassport] of [
            [ADULTS_ONCE, true],
            [ADULTS_REPEATABLE, false],
          ] as const) {
            await contract.methods
              .create_policy(
                id,
                { kind: AGE_MIN, min_age: 18, nationality: [0, 0, 0] },
                oneClaimPerPassport,
              )
              .send({ from: account, ...(fee ? { fee } : {}), wait: WAIT })
          }
        },
      )
      // A market per policy, so switching the policy never reuses the other's market
      const marketName = config.oneClaimPerPassport ? `${mode}Market` : `${mode}RepeatableMarket`
      markets[mode] = await deployed(marketName, fortunaMarket, [
        credentials[mode].address,
        policyId,
      ])
      console.log(
        `${mode} ZKPassportCredentials: ${credentials[mode].address}, FortunaMarket: ${markets[mode].address}`,
      )
    }

    // A local network's registry is seeded from Sepolia
    const sourceChain = l1ChainId === 1 ? "ethereum" : "ethereum_sepolia"
    // A bind covers the network by its rollup version, which only Aztec mainnet and testnet have a
    // name for in a ZKPassport request
    const network = (["aztec", "aztec_testnet"] as const).find(
      (name) => getIdFromChain(name) === rollupVersion,
    )
    const zkpassport = new ZKPassport(config.domain)
    return new Relayer(
      credentials,
      markets,
      policyId,
      account,
      fee,
      zkpassport,
      sourceChain,
      network,
    )
  }

  credentialsAddresses(): Record<GateMode, string> {
    return {
      live: this.credentials.live.address.toString(),
      dev: this.credentials.dev.address.toString(),
    }
  }

  marketAddresses(): Record<GateMode, string> {
    return { live: this.markets.live.address.toString(), dev: this.markets.dev.address.toString() }
  }

  /** The account that sends the claims, which the credential notes are tagged from */
  address(): string {
    return this.account.toString()
  }

  /** Proves and sends `claim_age(user, policy)` with the user's proof, one claim at a time. */
  claim(mode: GateMode, user: string, proof: ProofResult): Promise<string> {
    const run = this.queue.then(async () => {
      const credentials = this.credentials[mode]
      const params = await this.zkpassport.getAztecVerifierParameters({
        proof,
        network: this.network,
      })
      const { receipt } = await credentials.methods
        .claim_age(AztecAddress.fromStringUnsafe(user), this.policyId)
        .send({
          from: this.account,
          capsules: toAztecCapsules(params, credentials.address, this.account),
          ...(this.fee ? { fee: this.fee } : {}),
          wait: WAIT,
        })
      return receipt.txHash.toString()
    })
    this.queue = run.catch(() => undefined)
    return run
  }
}

function artifact(json: unknown): ContractArtifact {
  return loadContractArtifact(json as NoirCompiledContract)
}

function readDeployments(path: string): Record<string, Record<string, string>> {
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf-8")) : {}
}
