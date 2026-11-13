import QRCode from "qrcode"
import { useCallback, useEffect, useState } from "react"
import { demoAddress, isAztecAddress, loadAccount, saveAccount, shortAddress } from "./account"
import { MARKETS, type Market } from "./markets"
import { requestAgeProof } from "./verify"

type GateMode = "live" | "dev"

type Flow =
  | { step: "idle" }
  | { step: "scan"; url: string; qr: string }
  | { step: "received" }
  | { step: "proving" }
  | { step: "submitting" }
  | { step: "done"; txHash: string }
  | { step: "failed"; message: string }

export function App() {
  const [account, setAccount] = useState(loadAccount)
  const [mode, setMode] = useState<GateMode>("dev")
  const [sourceChain, setSourceChain] = useState<string | undefined>()
  const [badge, setBadge] = useState<boolean | undefined>()
  const [flow, setFlow] = useState<Flow>({ step: "idle" })
  const [order, setOrder] = useState<string | undefined>()

  const refreshBadge = useCallback(async () => {
    setBadge(undefined)
    const response = await fetch(`/api/badge?mode=${mode}&user=${account}`)
    const body = (await response.json()) as { badge?: boolean; error?: string }
    setBadge(body.badge ?? false)
  }, [account, mode])

  useEffect(() => {
    fetch("/api/network")
      .then((response) => response.json())
      .then((network: { sourceChain: string }) => setSourceChain(network.sourceChain))
      .catch(() => setSourceChain(undefined))
  }, [])

  useEffect(() => {
    refreshBadge().catch(() => setBadge(false))
  }, [refreshBadge])

  async function verify() {
    setFlow({ step: "idle" })
    // The proof must use the registries the network's ZKPassport registry mirrors; Sepolia's need
    // the SDK's dev mode. The gate decides whether mock passports are accepted.
    await requestAgeProof(account, sourceChain === "ethereum_sepolia", async (event) => {
      if (event.kind === "url") {
        setFlow({
          step: "scan",
          url: event.url,
          qr: await QRCode.toDataURL(event.url, { margin: 1, width: 240 }),
        })
      } else if (event.kind === "received" || event.kind === "proving") {
        setFlow({ step: event.kind })
      } else if (event.kind === "rejected") {
        setFlow({ step: "failed", message: "The request was declined in the ZKPassport app." })
      } else if (event.kind === "error") {
        setFlow({ step: "failed", message: event.message })
      } else if (event.kind === "proof") {
        setFlow({ step: "submitting" })
        const response = await fetch("/api/claim", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ mode, user: account, proof: event.proof }),
        })
        const body = (await response.json()) as { txHash?: string; error?: string }
        if (body.txHash) {
          setFlow({ step: "done", txHash: body.txHash })
          await refreshBadge()
        } else {
          setFlow({
            step: "failed",
            message: body.error ?? `the relayer answered ${response.status}`,
          })
        }
      }
    })
  }

  function switchAccount(address: string) {
    setAccount(saveAccount(address))
    setFlow({ step: "idle" })
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
        <AccountBox account={account} badge={badge} onChange={switchAccount} />
      </header>

      <main className="main">
        <section className="markets">
          <h1>Markets</h1>
          {badge === false && (
            <p className="locked-hint">Verify that you're 18 or older to trade.</p>
          )}
          <div className="market-list">
            {MARKETS.map((market) => (
              <MarketCard
                key={market.id}
                market={market}
                unlocked={badge === true}
                onTrade={(side) => setOrder(`${side} on “${market.question}”`)}
              />
            ))}
          </div>
          {order && (
            <div className="toast" role="status" onClick={() => setOrder(undefined)}>
              Order placed: {order}. This is a demo; no funds move.
            </div>
          )}
        </section>

        <aside className="gate">
          {badge ? (
            <div className="panel verified">
              <h2>You're verified</h2>
              <p>
                Your Aztec account holds Fortuna's 18+ badge. Fortuna learned that you are over 18,
                and nothing else about you.
              </p>
            </div>
          ) : (
            <div className="panel">
              <h2>18+ only</h2>
              <p>
                Trading on Fortuna requires being 18 or older. Prove it with ZKPassport: your phone
                reads your passport and proves your age without revealing your name, birth date or
                document.
              </p>
              <label className="dev-mode">
                <input
                  type="checkbox"
                  checked={mode === "dev"}
                  onChange={(event) => setMode(event.target.checked ? "dev" : "live")}
                />
                Developer mode: also accept ZKPassport's mock passports
              </label>
              <VerifyFlow flow={flow} onStart={verify} />
            </div>
          )}
        </aside>
      </main>

      <footer className="footer">
        A demo of ZKPassport on Aztec. Proofs are verified by an Aztec contract, and the badge is
        public; the passport data behind it never leaves your phone.
      </footer>
    </div>
  )
}

function AccountBox(props: {
  account: string
  badge: boolean | undefined
  onChange: (address: string) => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState("")

  if (editing) {
    return (
      <form
        className="account"
        onSubmit={(event) => {
          event.preventDefault()
          if (isAztecAddress(draft)) {
            props.onChange(draft)
            setEditing(false)
          }
        }}
      >
        <input
          className="account-input"
          placeholder="0x… your Aztec address"
          value={draft}
          onChange={(event) => setDraft(event.target.value.trim())}
        />
        <button type="submit" disabled={!isAztecAddress(draft)}>
          Use
        </button>
        <button type="button" className="link" onClick={() => setEditing(false)}>
          Cancel
        </button>
      </form>
    )
  }

  return (
    <div className="account">
      <span
        className={`badge-dot ${props.badge ? "on" : ""}`}
        title={props.badge ? "18+ verified" : "Not verified"}
      />
      <code title={props.account}>{shortAddress(props.account)}</code>
      <button type="button" className="link" onClick={() => setEditing(true)}>
        Use my address
      </button>
      <button type="button" className="link" onClick={() => props.onChange(demoAddress())}>
        New demo account
      </button>
    </div>
  )
}

function MarketCard(props: {
  market: Market
  unlocked: boolean
  onTrade: (side: "YES" | "NO") => void
}) {
  const { market } = props
  return (
    <article className="market">
      <div className="market-category">{market.category}</div>
      <h3>{market.question}</h3>
      <div className="market-meta">
        {market.volume} volume · closes {market.closes}
      </div>
      <div className="market-actions">
        <button
          type="button"
          className="yes"
          disabled={!props.unlocked}
          onClick={() => props.onTrade("YES")}
        >
          Yes {market.yes}¢
        </button>
        <button
          type="button"
          className="no"
          disabled={!props.unlocked}
          onClick={() => props.onTrade("NO")}
        >
          No {100 - market.yes}¢
        </button>
      </div>
    </article>
  )
}

function VerifyFlow(props: { flow: Flow; onStart: () => void }) {
  const { flow } = props
  switch (flow.step) {
    case "idle":
      return (
        <button type="button" className="primary" onClick={props.onStart}>
          Verify my age with ZKPassport
        </button>
      )
    case "scan":
      return (
        <div className="scan">
          <img src={flow.qr} alt="ZKPassport request QR code" width={240} height={240} />
          <p>
            Scan with the ZKPassport app, or <a href={flow.url}>open the request</a> on this device.
          </p>
        </div>
      )
    case "received":
      return <Status text="Request received on your phone. Confirm it in the ZKPassport app." />
    case "proving":
      return <Status text="Your phone is generating the proof…" />
    case "submitting":
      return (
        <Status text="Proof received. Fortuna's relayer is proving the claim and sending it to Aztec…" />
      )
    case "done":
      return <Status text={`Badge granted in transaction ${flow.txHash.slice(0, 10)}…`} />
    case "failed":
      return (
        <div className="failed">
          <p>Verification failed: {flow.message}</p>
          <button type="button" className="primary" onClick={props.onStart}>
            Try again
          </button>
        </div>
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
