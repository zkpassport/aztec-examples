# Fortuna

An 18+ prediction market on the Aztec testnet. Trading unlocks once the user proves with ZKPassport
that they are 18 or older. The proof is bound to the user's Aztec address and verified by an
`AgeGate` contract, which grants that address a public badge. Fortuna learns that the user is over
18 and nothing else.

- `src/`: the page (Vite + React). It asks the ZKPassport app for an age proof in `compressed` mode,
  bound to the user's Aztec address, and sends the proof to the relayer. The address is one the page
  made for this browser, or one the user enters.
- `server/`: the relayer. On first start it deploys two `AgeGate`s for the page's domain: one that
  accepts only real passports, and one in dev mode that also accepts ZKPassport's mock passports. It
  then proves and sends each `claim(user)` with the user's proof, and reads badges. Fees go through
  the testnet's sponsored fee contract.

## Running it

From the repo root, with the toolchain in `.aztecrc` active (see the root README):

```bash
scripts/fetch-zkpassport.sh
aztec compile
cd app && npm ci
npm run server   # the relayer, on port 3001
npm run dev      # the page, on http://localhost:5173
```

Scan the QR code with the ZKPassport app. The request travels through ZKPassport's bridge, so the
phone does not need to reach this machine.

The relayer reads:

- `AZTEC_NODE_URL`: the Aztec node, `https://aztec-testnet.drpc.org` by default;
- `REGISTRY_ADDRESS`: ZKPassport's registry on that network, the testnet's by default;
- `APP_DOMAIN`: the host the page is served from, `localhost` by default. Proofs commit to it, so
  the gates only accept proofs requested from that host;
- `PORT`: 3001 by default.

`server/deployments.json` records the gates it deployed, by node and domain.
