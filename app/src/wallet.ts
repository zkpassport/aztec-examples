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
import AgeGateJson from "../../target/age_gate_contract-AgeGate.json"
import FortunaMarketJson from "../../target/fortuna_market_contract-FortunaMarket.json"

export type GateMode = "live" | "dev"

const SECRET_KEY_STORAGE = "fortuna.secret"

const WAIT = { timeout: 600, interval: 2 } as const

/**
 * The Aztec account this browser trades as, with a wallet that holds its keys. The age gate mints
 * the badge as a private note to the account, so only this wallet can see it, and only this wallet
 * can prove the account holds it when it places an order.
 */
export class FortunaWallet {
  private constructor(
    private readonly gates: Record<GateMode, Contract>,
    private readonly markets: Record<GateMode, Contract>,
    private readonly fee: { paymentMethod: SponsoredFeePaymentMethod },
    readonly address: AztecAddress,
  ) {}

  /**
   * Opens the browser's account on `nodeUrl` and gets ready to read its badge on `gates` and to
   * trade on `markets`. `relayer` is the account that sends claims: the wallet looks for notes
   * tagged from it.
   */
  static async connect(network: {
    nodeUrl: string
    gates: Record<GateMode, string>
    markets: Record<GateMode, string>
    relayer: string
  }): Promise<FortunaWallet> {
    const node = createAztecNodeClient(network.nodeUrl)
    const wallet = await EmbeddedWallet.create(node, {
      ephemeral: true,
      pxe: { proverEnabled: true },
    })

    // An initializerless account needs no deployment to receive notes or send transactions
    const secret = loadSecretKey()
    const account = await wallet.createSchnorrInitializerlessAccount(
      secret,
      Fr.ZERO,
      deriveMasterMessageSigningSecretKey(secret),
    )

    await wallet.registerSender(AztecAddress.fromStringUnsafe(network.relayer), "Fortuna relayer")

    // The network's sponsored fee contract pays for the account's orders
    const fpc = await getContractInstanceFromInstantiationParams(SponsoredFPCContractArtifact, {
      salt: new Fr(SPONSORED_FPC_SALT),
    })
    await wallet.registerContract(fpc, SponsoredFPCContractArtifact)
    const fee = { paymentMethod: new SponsoredFeePaymentMethod(fpc.address) }

    async function contract(address: string, json: unknown, name: string): Promise<Contract> {
      const instance = await node.getContract(AztecAddress.fromStringUnsafe(address))
      if (!instance) {
        throw new Error(`${name} ${address} is not on this network`)
      }
      const contractArtifact = artifact(json)
      await wallet.registerContract(instance, contractArtifact)
      return Contract.at(instance.address, contractArtifact, wallet)
    }

    const gates = {} as Record<GateMode, Contract>
    const markets = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      gates[mode] = await contract(network.gates[mode], AgeGateJson, `the ${mode} age gate`)
      markets[mode] = await contract(network.markets[mode], FortunaMarketJson, `the ${mode} market`)
    }

    return new FortunaWallet(gates, markets, fee, account.address)
  }

  /** Whether this account holds the badge of the `mode` gate, from its own notes */
  async hasBadge(mode: GateMode): Promise<boolean> {
    const { result } = await this.gates[mode].methods
      .has_badge(this.address)
      .simulate({ from: this.address })
    return Boolean(result)
  }

  /** The orders placed on `market` of the `mode` gate's market, as the contract counts them */
  async orderCounts(mode: GateMode, market: number): Promise<{ yes: number; no: number }> {
    const count = async (yes: boolean) => {
      const { result } = await this.markets[mode].methods
        .orders(market, yes)
        .simulate({ from: this.address })
      return Number(result)
    }
    const [yes, no] = await Promise.all([count(true), count(false)])
    return { yes, no }
  }

  /**
   * Proves and sends an order on `market` of the `mode` gate's market. The market's contract
   * refuses it with "no badge" unless this account holds the gate's badge.
   */
  async placeOrder(mode: GateMode, market: number, yes: boolean): Promise<string> {
    const { receipt } = await this.markets[mode].methods
      .place_order(market, yes)
      .send({ from: this.address, fee: this.fee, wait: WAIT })
    return receipt.txHash.toString()
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
