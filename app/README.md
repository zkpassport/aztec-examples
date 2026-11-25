# Fortuna

An 18+ prediction market on the Aztec testnet. Orders go to a `FortunaMarket` contract, which
refuses them unless the trader holds Fortuna's 18+ badge. The user gets the badge by proving with
ZKPassport that they are 18 or older: the proof is bound to the user's Aztec address and verified by
an `AgeGate` contract, which mints that address a private badge note. Fortuna learns that the user
is over 18 and nothing else, and nothing public names the user.

- `src/`: the page (Vite + React). It asks the ZKPassport app for an age proof in `compressed` mode,
  bound to the user's Aztec address and the relayer's network, against the registries the network's
  ZKPassport registry mirrors (Sepolia's on the testnet and on a local network, which takes the
  SDK's dev mode), and sends the proof to the relayer. The address is an Aztec account the page
  makes in this browser, with an embedded wallet that keeps its secret key in `localStorage`. The
  account is never deployed: it receives the badge note and sends its own orders. The wallet reads
  the badge with the gate's `has_badge` utility function, looking for notes tagged from the
  relayer's account. An order is a `place_order` transaction the wallet proves in the browser; the
  market calls the gate's `assert_has_badge` for the sender, which only the holder's wallet can
  satisfy, from its own notes. Fees go through the network's sponsored fee contract. Clearing the
  browser's storage loses the account and its badge.
- `server/`: the relayer. On first start it deploys two `AgeGate`s for the page's domain, one that
  accepts only real passports and one in dev mode that also accepts ZKPassport's mock passports,
  and a `FortunaMarket` for each. It then proves and sends each `claim(user)` with the user's
  proof. It can't read the badges, which are private to their holders. Fees go through the
  testnet's sponsored fee contract. The proof's capsules come from the SDK's
  `getAztecVerifierParameters`, delivered to the gate with `toAztecCapsules`. That, ZKPassport's
  registry artifact and its registration with the relayer's wallet come from
  [`@zkpassport/aztec`](https://www.npmjs.com/package/@zkpassport/aztec).

## Running it

From the repo root, with the toolchain in `.aztecrc` active (see the root README):

```bash
scripts/fetch-zkpassport.sh   # the registry artifact and the age fixture, from the contracts' ref
aztec compile
cd app && npm ci
npm run server   # the relayer, on port 3001
npm start        # builds the page and serves it on http://localhost:5173
```

The page runs from a build because its Aztec wallet stores its data with a SQLite worker, which
Vite's dev server can't serve.

Scan the QR code with the ZKPassport app. The request travels through ZKPassport's bridge, so the
phone does not need to reach this machine.

The relayer reads:

- `AZTEC_NODE_URL`: the Aztec node, `https://aztec-testnet.drpc.org` by default;
- `REGISTRY_ADDRESS`: ZKPassport's registry on that network, the testnet's by default;
- `APP_DOMAIN`: the host the page is served from, `localhost` by default. Proofs commit to it, so
  the gates only accept proofs requested from that host;
- `ONE_CLAIM_PER_PASSPORT`: `1` deploys gates on which each passport claims once. By default a
  passport can claim again, so the same passport can test repeatedly. The two kinds of gate are
  recorded apart;
- `PORT`: 3001 by default.

`server/deployments.json` records the gates and markets it deployed, by node and domain. A recorded
contract the node no longer has, or has with older code, is deployed again.

## Local network

Point the relayer at a local network and it sets one up for proofs made against Sepolia's
registries, which dev-mode requests use:

```bash
aztec start --local-network   # in another shell
AZTEC_NODE_URL=http://localhost:8080 npm run server
npm start
```

On first start it deploys ZKPassport's registry where `verify_zkpassport_proof` looks for it on a
local network, with the network's test accounts as admin and operator. It seeds it with Sepolia's
latest certificate root, the circuit root of circuits 0.23.0 and their `outer_count_5` vk, and warps
the network's time past the registry's 24-hour delay. The relayer then sends from a test account,
paying with its Fee Juice.

A proof binds the network it is verified on, and a ZKPassport request can only name Aztec mainnet or
testnet, so the ZKPassport app can't make a proof the gates on a local network accept. The page says
so instead of requesting one.
