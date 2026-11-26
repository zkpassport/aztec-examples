# Fortuna

An 18+ prediction market on the Aztec testnet. Orders go to a `FortunaMarket` contract, which
refuses them unless the trader holds Fortuna's 18+ credential. The user gets the credential by
proving with ZKPassport that they are 18 or older: the proof is bound to the user's Aztec address
and verified by a `ZKPassportCredentials` contract, which mints that address a private credential
note of its 18+ policy. Fortuna learns that the user is over 18 and nothing else, and nothing public
names the user.

- `src/`: the page (Vite + React). Its "Verify my age" button is ZKPassport's hosted flow
  (`VerifyWithZKPassport` from [`@zkpassport/ui`](https://www.npmjs.com/package/@zkpassport/ui)),
  which opens ZKPassport's verification window. It asks for an age proof in `compressed` mode, bound
  to the user's Aztec address and the relayer's network, against the registries the network's
  ZKPassport registry mirrors (Sepolia's on the testnet and on a local network, which takes the
  SDK's dev mode), and the page sends the proof to the relayer. Each market card shows the orders
  the market contract has counted, and the result of your own order. The address is an Aztec account
  the page makes in this browser, with an embedded wallet that keeps its secret key in
  `localStorage`. The account is never deployed: it receives the credential note and sends its own
  orders. The wallet reads the credential with the contract's `has_credential` utility function,
  looking for notes tagged from the relayer's account. An order is a `place_order` transaction the
  wallet proves in the browser; the market calls `assert_has_credential` for the sender and its
  policy, which only the holder's wallet can satisfy, from its own notes. Fees go through the
  network's sponsored fee contract. Clearing the browser's storage loses the account and its
  credential.
- `server/`: the relayer. On first start it deploys two `ZKPassportCredentials` contracts for the
  page's domain, one that accepts only real passports and one in dev mode that also accepts
  ZKPassport's mock passports. On each it creates two 18+ policies, one that each passport claims
  once and one it can claim again, and it deploys a `FortunaMarket` for one of them. It then proves
  and sends each `claim_age(user, policy)` with the user's proof. It can't read the credentials,
  which are private to their holders. Fees go through the testnet's sponsored fee contract. The
  proof's capsules come from the SDK's `getAztecVerifierParameters`, delivered to the credentials
  contract with `toAztecCapsules`. That, ZKPassport's registry artifact and its registration with
  the relayer's wallet come from
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

Click **Verify my age** and scan the code in ZKPassport's window with the ZKPassport app. The
request travels through ZKPassport's bridge, so the phone does not need to reach this machine.

The relayer reads:

- `AZTEC_NODE_URL`: the Aztec node, `https://aztec-testnet.drpc.org` by default;
- `REGISTRY_ADDRESS`: ZKPassport's registry on that network, the testnet's by default;
- `APP_DOMAIN`: the host the page is served from, `localhost` by default. Proofs commit to it, so
  the credentials contracts only accept proofs requested from that host;
- `ONE_CLAIM_PER_PASSPORT`: `1` puts the markets on the policy each passport claims once. By default
  they take the repeatable policy, so the same passport can test repeatedly. The markets for the two
  policies are recorded apart;
- `PORT`: 3001 by default.

`server/deployments.json` records the contracts it deployed, by node and domain. A recorded contract
the node no longer has, or has with older code, is deployed again.

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
testnet, so the ZKPassport app can't make a proof the credentials contracts on a local network
accept. The page says so instead of requesting one.
