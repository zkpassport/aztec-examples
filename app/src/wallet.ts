import {
  type ContractArtifact,
  type NoirCompiledContract,
  loadContractArtifact,
} from "@aztec-labs/aztec.js/abi"
import { AztecAddress } from "@aztec-labs/aztec.js/addresses"
import { Contract } from "@aztec-labs/aztec.js/contracts"
import { Fr } from "@aztec-labs/aztec.js/fields"
import { createAztecNodeClient } from "@aztec-labs/aztec.js/node"
import { deriveMasterMessageSigningSecretKey } from "@aztec-labs/stdlib/keys"
import { EmbeddedWallet } from "@aztec-labs/wallets/embedded"
import AgeGateJson from "../../target/age_gate_contract-AgeGate.json"

export type GateMode = "live" | "dev"

const SECRET_KEY_STORAGE = "fortuna.secret"

/**
 * The Aztec account this browser trades as, with a wallet that holds its keys. The age gate mints
 * the badge as a private note to the account, so only this wallet can see it.
 */
export class FortunaWallet {
  private constructor(
    private readonly gates: Record<GateMode, Contract>,
    readonly address: AztecAddress,
  ) {}

  /**
   * Opens the browser's account on `nodeUrl` and gets ready to read its badge on `gates`.
   * `relayer` is the account that sends claims: the wallet looks for notes tagged from it.
   */
  static async connect(
    nodeUrl: string,
    gates: Record<GateMode, string>,
    relayer: string,
  ): Promise<FortunaWallet> {
    const node = createAztecNodeClient(nodeUrl)
    const wallet = await EmbeddedWallet.create(node, { ephemeral: true })

    // The account is never deployed: it only receives notes and reads them
    const secret = loadSecretKey()
    const account = await wallet.createSchnorrInitializerlessAccount(
      secret,
      Fr.ZERO,
      deriveMasterMessageSigningSecretKey(secret),
    )

    await wallet.registerSender(AztecAddress.fromStringUnsafe(relayer), "Fortuna relayer")

    const ageGate = artifact(AgeGateJson)
    const contracts = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      const instance = await node.getContract(AztecAddress.fromStringUnsafe(gates[mode]))
      if (!instance) {
        throw new Error(`the ${mode} age gate ${gates[mode]} is not on this network`)
      }
      await wallet.registerContract(instance, ageGate)
      contracts[mode] = await Contract.at(instance.address, ageGate, wallet)
    }

    return new FortunaWallet(contracts, account.address)
  }

  /** Whether this account holds the badge of the `mode` gate, from its own notes */
  async hasBadge(mode: GateMode): Promise<boolean> {
    const { result } = await this.gates[mode].methods
      .has_badge(this.address)
      .simulate({ from: this.address })
    return Boolean(result)
  }
}

// The secret key stays in this browser, so the badge goes with it. Losing it loses the badge, and
// a passport claims once per gate.
function loadSecretKey(): Fr {
  try {
    const saved = localStorage.getItem(SECRET_KEY_STORAGE)
    if (saved) {
      return Fr.fromString(saved)
    }
  } catch {
    // Storage can be unavailable (private windows); the account then lasts until the page reloads
  }
  const secret = Fr.random()
  try {
    localStorage.setItem(SECRET_KEY_STORAGE, secret.toString())
  } catch {
    // As above
  }
  return secret
}

function artifact(json: unknown): ContractArtifact {
  return loadContractArtifact(json as NoirCompiledContract)
}
