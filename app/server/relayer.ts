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
import AgeGateJson from "../../target/age_gate_contract-AgeGate.json" with { type: "json" }
import FortunaMarketJson from "../../target/fortuna_market_contract-FortunaMarket.json" with { type: "json" }
import { LOCAL_NETWORK_L1_CHAIN_ID, setUpLocalNetworkRegistry } from "./local-network"

// The SDK's ESM build doesn't load in Node: it imports `buffer/` and named exports of a CommonJS
// package. Its CommonJS build does.
const { ZKPassport } = createRequire(import.meta.url)(
  "@zkpassport/sdk",
) as typeof import("@zkpassport/sdk")
type ZKPassport = InstanceType<typeof ZKPassport>

export type GateMode = "live" | "dev"

/** The chain whose registries the network's ZKPassport registry mirrors, which proofs must be made against */
export type SourceChain = "ethereum" | "ethereum_sepolia"

export interface RelayerConfig {
  nodeUrl: string
  /** ZKPassport's registry on the network; on a local network the relayer deploys its own */
  registryAddress: string
  /** The domain the app is served from, which its ZKPassport requests carry */
  domain: string
  /** Whether each passport claims once on the gates, or can claim again, as in testing */
  oneClaimPerPassport: boolean
  deploymentsPath: string
}

type Fee = { paymentMethod: SponsoredFeePaymentMethod } | undefined

const WAIT = { timeout: 3600, interval: 2 } as const

/**
 * Submits users' age proofs to Fortuna's two AgeGates, one that accepts only real passports and
 * one in dev mode that also accepts ZKPassport's mock passports.
 */
export class Relayer {
  private queue: Promise<unknown> = Promise.resolve()

  private constructor(
    private readonly gates: Record<GateMode, Contract>,
    /** The market each gate's badge opens */
    private readonly markets: Record<GateMode, Contract>,
    private readonly account: AztecAddress,
    private readonly fee: Fee,
    private readonly zkpassport: ZKPassport,
    readonly sourceChain: SourceChain,
    /** The network a proof must be bound to, if ZKPassport can bind one to this network */
    readonly network: AztecNetwork | undefined,
  ) {}

  /**
   * Connects the relayer's account and deploys the gates the deployments file does not list on the
   * node. On a local network the account is a test account, and the relayer sets up the registry.
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
    // and deploys it otherwise
    async function deployed(
      name: string,
      contractArtifact: ContractArtifact,
      args: unknown[],
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
      deployments[key] = { ...deployments[key], [name]: contract.address.toString() }
      writeFileSync(config.deploymentsPath, JSON.stringify(deployments, null, 2) + "\n")
      return contract
    }

    const ageGate = artifact(AgeGateJson)
    const fortunaMarket = artifact(FortunaMarketJson)
    const domainHash = new Fr(getScopeHash(config.domain))
    const gates = {} as Record<GateMode, Contract>
    const markets = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      // Gates with either uniqueness setting are recorded apart, so switching it never reuses the other
      const name = config.oneClaimPerPassport ? mode : `${mode}Repeatable`
      gates[mode] = await deployed(name, ageGate, [
        domainHash,
        mode === "dev",
        config.oneClaimPerPassport,
      ])
      markets[mode] = await deployed(`${name}Market`, fortunaMarket, [gates[mode].address])
      console.log(
        `${mode} AgeGate: ${gates[mode].address}, FortunaMarket: ${markets[mode].address}`,
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
    return new Relayer(gates, markets, account, fee, zkpassport, sourceChain, network)
  }

  gateAddresses(): Record<GateMode, string> {
    return { live: this.gates.live.address.toString(), dev: this.gates.dev.address.toString() }
  }

  marketAddresses(): Record<GateMode, string> {
    return { live: this.markets.live.address.toString(), dev: this.markets.dev.address.toString() }
  }

  /** The account that sends the claims, which the badge notes are tagged from */
  address(): string {
    return this.account.toString()
  }

  /** Proves and sends `claim(user)` with the user's proof, one claim at a time. */
  claim(mode: GateMode, user: string, proof: ProofResult): Promise<string> {
    const run = this.queue.then(async () => {
      const gate = this.gates[mode]
      const params = await this.zkpassport.getAztecVerifierParameters({
        proof,
        network: this.network,
      })
      const { receipt } = await gate.methods.claim(AztecAddress.fromStringUnsafe(user)).send({
        from: this.account,
        capsules: toAztecCapsules(params, gate.address, this.account),
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
