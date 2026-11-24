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
import { deriveMasterMessageSigningSecretKey } from "@aztec-labs/stdlib/keys"
import { EmbeddedWallet } from "@aztec-labs/wallets/embedded"
import { registerInitialLocalNetworkAccountsInWallet } from "@aztec-labs/wallets/testing"
import { registerZKPassportRegistry, toAztecCapsules } from "@zkpassport/aztec"
import { type AztecNetwork, type ProofResult, ZKPassport } from "@zkpassport/sdk"
import { getIdFromChain } from "@zkpassport/utils"
import { getScopeHash } from "@zkpassport/utils/circuit-matcher"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import AgeGateJson from "../../target/age_gate_contract-AgeGate.json" with { type: "json" }
import { LOCAL_NETWORK_L1_CHAIN_ID, setUpLocalNetworkRegistry } from "./local-network"

export type GateMode = "live" | "dev"

/** The chain whose registries the network's ZKPassport registry mirrors, which proofs must be made against */
export type SourceChain = "ethereum" | "ethereum_sepolia"

export interface RelayerConfig {
  nodeUrl: string
  /** ZKPassport's registry on the network; on a local network the relayer deploys its own */
  registryAddress: string
  /** The domain the app is served from, which its ZKPassport requests carry */
  domain: string
  deploymentsPath: string
}

type Fee = { paymentMethod: SponsoredFeePaymentMethod } | undefined

const WAIT = { timeout: 3600, interval: 2 } as const

/**
 * Submits users' age proofs to Fortuna's two AgeGates, one that accepts only real passports and
 * one in dev mode that also accepts ZKPassport's mock passports, and reads their badges.
 */
export class Relayer {
  private queue: Promise<unknown> = Promise.resolve()

  private constructor(
    private readonly gates: Record<GateMode, Contract>,
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

    const ageGate = artifact(AgeGateJson)
    const deployments = readDeployments(config.deploymentsPath)
    const key = `${config.nodeUrl}|${config.domain}`
    const gates = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      const recorded = deployments[key]?.[mode]
      const instance = recorded
        ? await node.getContract(AztecAddress.fromStringUnsafe(recorded))
        : undefined
      if (instance) {
        await wallet.registerContract(instance, ageGate)
        gates[mode] = await Contract.at(instance.address, ageGate, wallet)
      } else {
        console.log(`Deploying the ${mode} AgeGate for ${config.domain}...`)
        const domainHash = new Fr(getScopeHash(config.domain))
        const { contract } = await Contract.deploy(wallet, ageGate, [
          domainHash,
          mode === "dev",
        ]).send({
          from: account,
          ...(fee ? { fee } : {}),
          wait: WAIT,
        })
        gates[mode] = contract
        deployments[key] = { ...deployments[key], [mode]: contract.address.toString() }
        writeFileSync(config.deploymentsPath, JSON.stringify(deployments, null, 2) + "\n")
      }
      console.log(`${mode} AgeGate: ${gates[mode].address}`)
    }

    // A local network's registry is seeded from Sepolia
    const sourceChain = l1ChainId === 1 ? "ethereum" : "ethereum_sepolia"
    // A bind covers the network by its rollup version, which only Aztec mainnet and testnet have a
    // name for in a ZKPassport request
    const network = (["aztec", "aztec_testnet"] as const).find(
      (name) => getIdFromChain(name) === rollupVersion,
    )
    const zkpassport = new ZKPassport(config.domain)
    return new Relayer(gates, account, fee, zkpassport, sourceChain, network)
  }

  gateAddresses(): Record<GateMode, string> {
    return { live: this.gates.live.address.toString(), dev: this.gates.dev.address.toString() }
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

  async hasBadge(mode: GateMode, user: string): Promise<boolean> {
    const { result } = await this.gates[mode].methods
      .has_badge(AztecAddress.fromStringUnsafe(user))
      .simulate({ from: this.account })
    return Boolean(result)
  }
}

function artifact(json: unknown): ContractArtifact {
  return loadContractArtifact(json as NoirCompiledContract)
}

function readDeployments(path: string): Record<string, Partial<Record<GateMode, string>>> {
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf-8")) : {}
}
