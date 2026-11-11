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
import { Capsule } from "@aztec-labs/aztec.js/tx"
import { SPONSORED_FPC_SALT } from "@aztec-labs/constants"
import { SponsoredFPCContractArtifact } from "@aztec-labs/noir-contracts.js/SponsoredFPC"
import { deriveMasterMessageSigningSecretKey } from "@aztec-labs/stdlib/keys"
import { EmbeddedWallet } from "@aztec-labs/wallets/embedded"
import type { ProofResult } from "@zkpassport/sdk"
import { getScopeHash } from "@zkpassport/utils/circuit-matcher"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import AgeGateJson from "../../target/age_gate_contract-AgeGate.json" with { type: "json" }
import RegistryJson from "../../zkpassport/target/zkpassport_registry_contract-ZKPassportRegistry.json" with { type: "json" }
import { proofCapsuleFields } from "./capsule"

export type GateMode = "live" | "dev"

export interface RelayerConfig {
  nodeUrl: string
  /** ZKPassport's registry on the network, which the gates verify proofs against */
  registryAddress: string
  /** The domain the app is served from, which its ZKPassport requests carry */
  domain: string
  deploymentsPath: string
}

// Must match zkpassport_aztec_verifier::constants::PROOF_CAPSULE_SLOT
const PROOF_CAPSULE_SLOT = new Fr(1n)
// AgeGate::claim verifies an outer_count_5 proof: the passport's three subproofs, age and bind
const AGE_GATE_SUBPROOFS = 5
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
    private readonly fee: { paymentMethod: SponsoredFeePaymentMethod },
  ) {}

  /** Connects a fresh relayer account, and deploys the gates on first start. */
  static async start(config: RelayerConfig): Promise<Relayer> {
    const node = createAztecNodeClient(config.nodeUrl)
    const wallet = await EmbeddedWallet.create(config.nodeUrl, {
      ephemeral: true,
      pxe: { proverEnabled: true },
    })
    const secret = Fr.random()
    const { address } = await wallet.createSchnorrInitializerlessAccount(
      secret,
      new Fr(0),
      deriveMasterMessageSigningSecretKey(secret),
    )

    const fpc = await getContractInstanceFromInstantiationParams(SponsoredFPCContractArtifact, {
      salt: new Fr(SPONSORED_FPC_SALT),
    })
    await wallet.registerContract(fpc, SponsoredFPCContractArtifact)
    const fee = { paymentMethod: new SponsoredFeePaymentMethod(fpc.address) }

    const registry = await node.getContract(AztecAddress.fromStringUnsafe(config.registryAddress))
    if (!registry) {
      throw new Error(`no ZKPassport registry at ${config.registryAddress} on ${config.nodeUrl}`)
    }
    await wallet.registerContract(registry, artifact(RegistryJson))

    const ageGate = artifact(AgeGateJson)
    const deployments = readDeployments(config.deploymentsPath)
    const key = `${config.nodeUrl}|${config.domain}`
    const gates = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      const deployed = deployments[key]?.[mode]
      if (deployed) {
        const instance = await node.getContract(AztecAddress.fromStringUnsafe(deployed))
        if (!instance) {
          throw new Error(
            `no AgeGate at ${deployed}; remove ${config.deploymentsPath} to deploy new ones`,
          )
        }
        await wallet.registerContract(instance, ageGate)
        gates[mode] = await Contract.at(instance.address, ageGate, wallet)
      } else {
        console.log(`Deploying the ${mode} AgeGate for ${config.domain}...`)
        const domainHash = new Fr(getScopeHash(config.domain))
        const { contract } = await Contract.deploy(wallet, ageGate, [
          domainHash,
          mode === "dev",
        ]).send({
          from: address,
          fee,
          wait: WAIT,
        })
        gates[mode] = contract
        deployments[key] = { ...deployments[key], [mode]: contract.address.toString() }
        writeFileSync(config.deploymentsPath, JSON.stringify(deployments, null, 2) + "\n")
      }
      console.log(`${mode} AgeGate: ${gates[mode].address}`)
    }

    return new Relayer(gates, address, fee)
  }

  gateAddresses(): Record<GateMode, string> {
    return { live: this.gates.live.address.toString(), dev: this.gates.dev.address.toString() }
  }

  /** Proves and sends `claim(user)` with the user's proof, one claim at a time. */
  claim(mode: GateMode, user: string, proof: ProofResult): Promise<string> {
    const run = this.queue.then(async () => {
      const gate = this.gates[mode]
      const fields = await proofCapsuleFields(proof, AGE_GATE_SUBPROOFS)
      const capsule = new Capsule(gate.address, PROOF_CAPSULE_SLOT, fields, this.account)
      const { receipt } = await gate.methods.claim(AztecAddress.fromStringUnsafe(user)).send({
        from: this.account,
        capsules: [capsule],
        fee: this.fee,
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
