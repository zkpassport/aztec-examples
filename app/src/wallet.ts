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
import FortunaMarketJson from "../../target/fortuna_market_contract-FortunaMarket.json"
import ZKPassportCredentialsJson from "../../target/zkpassport_credentials_contract-ZKPassportCredentials.json"

export type GateMode = "live" | "dev"

const SECRET_KEY_STORAGE = "fortuna.secret"

const WAIT = { timeout: 600, interval: 2 } as const

/**
 * The Aztec account this browser trades as, with a wallet that holds its keys. The credentials
 * contract mints the 18+ credential as a private note to the account, so only this wallet can see
 * it, and only this wallet can prove the account holds it when it places an order.
 */
export class FortunaWallet {
  private constructor(
    private readonly credentials: Record<GateMode, Contract>,
    private readonly markets: Record<GateMode, Contract>,
    private readonly policyId: number,
    private readonly fee: { paymentMethod: SponsoredFeePaymentMethod },
    readonly address: AztecAddress,
  ) {}

  /**
   * Opens the browser's account on `nodeUrl` and gets ready to read its credential of `policyId` on
   * `credentials` and to trade on `markets`. `relayer` is the account that sends claims: the wallet
   * looks for notes tagged from it.
   */
  static async connect(network: {
    nodeUrl: string
    credentials: Record<GateMode, string>
    markets: Record<GateMode, string>
    policyId: number
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

    const credentials = {} as Record<GateMode, Contract>
    const markets = {} as Record<GateMode, Contract>
    for (const mode of ["live", "dev"] as const) {
      credentials[mode] = await contract(
        network.credentials[mode],
        ZKPassportCredentialsJson,
        `the ${mode} credentials contract`,
      )
      markets[mode] = await contract(network.markets[mode], FortunaMarketJson, `the ${mode} market`)
    }

    return new FortunaWallet(credentials, markets, network.policyId, fee, account.address)
  }

  /** Whether this account holds the `mode` contract's 18+ credential, from its own notes */
  async hasCredential(mode: GateMode): Promise<boolean> {
    const { result } = await this.credentials[mode].methods
      .has_credential(this.address, this.policyId)
      .simulate({ from: this.address })
    return Boolean(result)
  }

  /** The orders placed on `market` of the `mode` market, as the contract counts them */
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
   * Proves and sends an order on `market` of the `mode` market. The market's contract refuses it
   * with "no credential" unless this account holds the 18+ credential.
   */
  async placeOrder(mode: GateMode, market: number, yes: boolean): Promise<string> {
    const { receipt } = await this.markets[mode].methods
      .place_order(market, yes)
      .send({ from: this.address, fee: this.fee, wait: WAIT })
    return receipt.txHash.toString()
  }
}

// The secret key stays in this browser, so the credential goes with it. Losing it loses the
// credential, and under a one-claim policy the passport can't claim it again.
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
