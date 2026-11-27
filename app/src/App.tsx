import type { AztecNetwork, ProofResult } from "@zkpassport/sdk"
import { VerifyWithZKPassport } from "@zkpassport/ui/react"
import { getIdFromChain, VerificationTier } from "@zkpassport/utils"
import { useCallback, useEffect, useState } from "react"
import { shortAddress } from "./account"
import { MARKETS, type Market } from "./markets"
import { type IdRead, outerProof } from "./proof"
import { TERMS, termsDigest } from "./terms"
import { FortunaWallet, type GateMode } from "./wallet"

type Side = "YES" | "NO"

/** The result of the latest order on a market card */
type OrderState =
  | { status: "placing"; side: Side }
  | { status: "placed"; side: Side; txHash: string }
  | { status: "refused"; side: Side; message: string }

type Claim =
  | { status: "idle" }
  | { status: "claiming" }
  | { status: "claimed"; txHash: string; read: IdRead }
  | { status: "failed"; message: string }

type Counts = Record<number, { yes: number; no: number }>

/** What the claimed credential says the trader verified with */
const READ_LABELS: Record<IdRead, string> = {
  chip: "an ID read from its chip",
  camera: "an ID read by the phone's camera",
  aadhaar: "an Aadhaar",
}

export function App() {
  const [wallet, setWallet] = useState<FortunaWallet | undefined>()
  const [walletError, setWalletError] = useState<string | undefined>()
  const [mode, setMode] = useState<GateMode>("dev")
  const [sourceChain, setSourceChain] = useState<string | undefined>()
  const [network, setNetwork] = useState<AztecNetwork | null>(null)
  const [credential, setCredential] = useState<boolean | undefined>()
  const [claim, setClaim] = useState<Claim>({ status: "idle" })
  const [orders, setOrders] = useState<Record<number, OrderState>>({})
  const [counts, setCounts] = useState<Counts>({})
  const [termsAccepted, setTermsAccepted] = useState(false)
  // The digest of the terms this page shows, and of the ones the relayer's policies bind
  const [digest, setDigest] = useState<string | undefined>()
  const [policyDigest, setPolicyDigest] = useState<string | undefined>()

  const account = wallet?.address.toString()

  const refreshCredential = useCallback(async () => {
    if (!wallet) {
      return
    }
    setCredential(undefined)
    setCredential(await wallet.hasCredential(mode))
  }, [wallet, mode])

  const refreshCounts = useCallback(async () => {
    if (!wallet) {
      return
    }
    const entries = await Promise.all(
      MARKETS.map(async (_, index) => [index, await wallet.orderCounts(mode, index + 1)] as const),
    )
    setCounts(Object.fromEntries(entries))
  }, [wallet, mode])

  useEffect(() => {
    fetch("/api/network")
      .then((response) => response.json())
      .then(
        async (body: {
          nodeUrl: string
          credentials: Record<GateMode, string>
          markets: Record<GateMode, string>
          policyId: number
          relayer: string
          sourceChain: string
          network: AztecNetwork | null
          termsDigest: string
        }) => {
          setSourceChain(body.sourceChain)
          setNetwork(body.network)
          setPolicyDigest(body.termsDigest)
          setWallet(await FortunaWallet.connect(body))
        },
      )
      .catch((error: unknown) =>
        setWalletError(error instanceof Error ? error.message : String(error)),
      )
  }, [])

  useEffect(() => {
    termsDigest(TERMS)
      .then(setDigest)
      .catch(() => setDigest(undefined))
  }, [])

  useEffect(() => {
    refreshCredential().catch(() => setCredential(false))
    refreshCounts().catch(() => setCounts({}))
    setOrders({})
    setClaim({ status: "idle" })
  }, [refreshCredential, refreshCounts])

  async function trade(marketIndex: number, side: Side) {
    if (!wallet) {
      return
    }
    setOrders((current) => ({ ...current, [marketIndex]: { status: "placing", side } }))
    try {
      // Market ids on chain start at 1
      const txHash = await wallet.placeOrder(mode, marketIndex + 1, side === "YES")
      setOrders((current) => ({ ...current, [marketIndex]: { status: "placed", side, txHash } }))
      await refreshCounts()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      setOrders((current) => ({
        ...current,
        [marketIndex]: {
          status: "refused",
          side,
          message: message.includes("no credential")
            ? "The market contract refused it: this account has no trader credential."
            : message,
        },
      }))
    }
  }

  // The hosted flow hands back the proofs; the relayer proves the claim with the outer one
  async function claimCredential(proofs: ProofResult[]): Promise<boolean> {
    const outer = outerProof(proofs)
    if (!outer) {
      setClaim({
        status: "failed",
        message: "ZKPassport sent no proof an Aztec contract verifies.",
      })
      return false
    }
    setClaim({ status: "claiming" })
    const response = await fetch("/api/claim", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode, user: account, proof: outer.proof }),
    })
    const body = (await response.json()) as { txHash?: string; error?: string }
    if (!body.txHash) {
      setClaim({
        status: "failed",
        message: body.error ?? `the relayer answered ${response.status}`,
      })
      return false
    }
    setClaim({ status: "claimed", txHash: body.txHash, read: outer.read })
    await refreshCredential()
    return true
  }

  return (
    <div className="page">
      <header className="header">
        <div className="brand">
          <img src="/fortuna.svg" alt="" width={36} height={36} />
          <div>
            <div className="brand-name">Fortuna</div>
            <div className="brand-tagline">Private prediction markets on Aztec</div>
          </div>
        </div>
        <AccountChip account={account} credential={credential} error={walletError} />
      </header>

      <main className="main">
        <section className="markets">
          <div className="markets-heading">
            <h1>Markets</h1>
            {credential === false && (
              <p className="locked-hint">
                Orders need the trader credential, which the market checks.
              </p>
            )}
          </div>
          <div className="market-list">
            {MARKETS.map((market, index) => (
              <MarketCard
                key={market.id}
                market={market}
                counts={counts[index]}
                order={orders[index]}
                disabled={!wallet || orders[index]?.status === "placing"}
                onTrade={(side) => trade(index, side)}
              />
            ))}
          </div>
        </section>

        <aside className="gate">
          {credential ? (
            <div className="panel verified">
              <div className="panel-kicker">Verified</div>
              <h2>You hold the trader credential</h2>
              <p>
                A private note in this browser's Aztec account. Fortuna learned that you're over 18
                and not on a sanctions list, and nothing else.
              </p>
              {claim.status === "claimed" && (
                <p className="mono">
                  Claimed in {shortHash(claim.txHash)} with {READ_LABELS[claim.read]}
                </p>
              )}
            </div>
          ) : (
            <div className="panel">
              <div className="panel-kicker">Verified traders only</div>
              <h2>Verify to trade</h2>
              <p>
                Your phone reads your passport and proves you're 18 or older and not on a sanctions
                list, without revealing your name, birth date or document.
              </p>
              <label className="dev-mode" htmlFor="dev-mode">
                <input
                  id="dev-mode"
                  type="checkbox"
                  checked={mode === "dev"}
                  onChange={(event) => setMode(event.target.checked ? "dev" : "live")}
                />
                <span>
                  <strong>Developer mode</strong>
                  <br />
                  Also accept ZKPassport's mock passports
                </span>
              </label>
              <Terms accepted={termsAccepted} digest={digest} onChange={setTermsAccepted} />
              <GateAction
                account={account}
                network={network}
                claim={claim}
                terms={
                  !digest || !policyDigest
                    ? "checking"
                    : digest !== policyDigest
                      ? "mismatch"
                      : termsAccepted
                        ? "accepted"
                        : "unaccepted"
                }
                verifier={
                  account && network && digest ? (
                    <VerifyWithZKPassport
                      purpose="Prove you're 18 or older and not on a sanctions list to trade on Fortuna"
                      query={{ age: { min: 18 }, sanctions: true }}
                      bind={{
                        account: account as `0x${string}`,
                        chainId: getIdFromChain(network),
                        data: digest,
                      }}
                      mode="compressed"
                      // Sepolia's registries, which the testnet's ZKPassport registry mirrors, take
                      // the SDK's dev mode; the credentials contract decides whether mock passports
                      // are accepted
                      service={{
                        devMode: sourceChain === "ethereum_sepolia",
                        uniqueIdentifierType: "non-salted",
                        // An ID its issuer signed, such as a chip read or an Aadhaar, or one read by
                        // the camera of ZKPassport's app
                        allowedVerificationMethods: [
                          VerificationTier.GOVERNMENT_SIGNED,
                          VerificationTier.DEVICE_ATTESTED,
                        ],
                      }}
                      style={{ label: "Verify with ZKPassport" }}
                      onSuccess={({ proofs }) => claimCredential(proofs)}
                      onError={(error) => setClaim({ status: "failed", message: error.message })}
                    />
                  ) : undefined
                }
              />
            </div>
          )}
        </aside>
      </main>

      <footer className="footer">
        A demo of ZKPassport on Aztec. An Aztec contract verifies the proof, the credential is a
        private note only this browser's account can see, and the passport data behind it never
        leaves your phone. No funds move.
      </footer>
    </div>
  )
}

function Terms(props: {
  accepted: boolean
  digest: string | undefined
  onChange: (accepted: boolean) => void
}) {
  return (
    <div className="terms">
      <pre className="terms-text">{TERMS}</pre>
      <label className="terms-accept" htmlFor="terms-accept">
        <input
          id="terms-accept"
          type="checkbox"
          checked={props.accepted}
          onChange={(event) => props.onChange(event.target.checked)}
        />
        <span>I accept these terms. My passport proof will be bound to them.</span>
      </label>
      {props.digest && (
        <p className="terms-digest" title={`SHA-256 ${props.digest}`}>
          SHA-256 <span className="mono">{props.digest.slice(0, 8)}…</span>
        </p>
      )}
    </div>
  )
}

function GateAction(props: {
  account: string | undefined
  network: AztecNetwork | null
  claim: Claim
  terms: "checking" | "mismatch" | "unaccepted" | "accepted"
  verifier: React.ReactNode
}) {
  if (!props.account) {
    return <Status text="Setting up your Aztec account in this browser…" />
  }
  if (!props.network) {
    return (
      <p className="notice">
        A ZKPassport proof can only be bound to Aztec mainnet or testnet, so it can't be requested
        on this network.
      </p>
    )
  }
  if (props.terms === "mismatch") {
    return (
      <p className="notice refused">
        The relayer's credentials contracts bind other terms. Restart the relayer from this
        checkout.
      </p>
    )
  }
  return (
    <div className="gate-action">
      {props.terms === "accepted" && props.verifier}
      {props.terms === "unaccepted" && <p className="notice">Accept the terms to verify.</p>}
      {props.claim.status === "claiming" && (
        <Status text="Fortuna's relayer is claiming your credential on Aztec…" />
      )}
      {props.claim.status === "failed" && (
        <p className="notice refused">Couldn't claim the credential: {props.claim.message}</p>
      )}
    </div>
  )
}

function AccountChip(props: {
  account: string | undefined
  credential: boolean | undefined
  error: string | undefined
}) {
  const [copied, setCopied] = useState(false)
  if (props.error) {
    return <div className="notice refused">Couldn't set up your Aztec account: {props.error}</div>
  }
  if (!props.account) {
    return <Status text="Setting up your Aztec account…" />
  }
  const account = props.account
  const copy = () => {
    navigator.clipboard
      ?.writeText(account)
      .then(() => {
        setCopied(true)
        setTimeout(() => setCopied(false), 1500)
      })
      .catch(() => {})
  }
  return (
    <div className="account">
      <span
        className={`pill ${props.credential ? "pill-verified" : ""}`}
        title={props.credential === undefined ? "Checking your notes" : undefined}
      >
        {props.credential === undefined
          ? "Checking…"
          : props.credential
            ? "Verified trader"
            : "Not verified"}
      </span>
      <button type="button" className="address" title={account} onClick={copy}>
        <code>{shortAddress(account)}</code>
        <span className="address-action">{copied ? "Copied" : "Copy"}</span>
      </button>
    </div>
  )
}

function MarketCard(props: {
  market: Market
  counts: { yes: number; no: number } | undefined
  order: OrderState | undefined
  disabled: boolean
  onTrade: (side: Side) => void
}) {
  const { market, counts, order } = props
  return (
    <article className="market">
      <div className="market-category">{market.category}</div>
      <h3>{market.question}</h3>
      <div className="market-meta">
        <span>Closes {market.closes}</span>
        <span className="mono" title="Orders the market contract has counted">
          {counts ? `${counts.yes} yes · ${counts.no} no on chain` : "…"}
        </span>
      </div>
      <div className="market-actions">
        <button
          type="button"
          className="yes"
          disabled={props.disabled}
          onClick={() => props.onTrade("YES")}
        >
          Yes {market.yes}¢
        </button>
        <button
          type="button"
          className="no"
          disabled={props.disabled}
          onClick={() => props.onTrade("NO")}
        >
          No {100 - market.yes}¢
        </button>
      </div>
      <div className="order-slot">{order && <OrderLine order={order} />}</div>
    </article>
  )
}

function OrderLine(props: { order: OrderState }) {
  const { order } = props
  switch (order.status) {
    case "placing":
      return <Status text={`Proving your ${order.side} order in this browser…`} />
    case "placed":
      return (
        <p className="order-line placed" role="status">
          {order.side} order placed · <span className="mono">{shortHash(order.txHash)}</span>
        </p>
      )
    case "refused":
      return (
        <p className="order-line refused" role="alert">
          {order.side} order refused. {order.message}
        </p>
      )
  }
}

function Status(props: { text: string }) {
  return (
    <p className="status">
      <span className="spinner" aria-hidden="true" />
      {props.text}
    </p>
  )
}

function shortHash(hash: string): string {
  return `${hash.slice(0, 10)}…`
}
