# Fortuna

A prediction market on the Aztec testnet for traders who are 18 or older and not on a sanctions
list. Orders go to a `FortunaMarket` contract, which refuses them unless the trader holds Fortuna's
trader credential. The user gets the credential with one ZKPassport proof that they are 18 or older
and not on the sanctions lists, from an ID read from its chip or by the phone's camera, or from an
Aadhaar: the proof is bound to the user's Aztec address and verified by a
`ZKPassportCredentials` contract's `claim_age_and_sanctions` (or
`claim_age_and_sanctions_from_camera_read` for a camera read, and
`claim_age_and_sanctions_with_face_match` for an Aadhaar), which mints that address a private
credential note of its trader policy. Before verifying, the user accepts Fortuna's terms, and the
proof is bound to their SHA-256 digest as well, so the credential records which terms its holder
accepted. Fortuna learns that the user is over 18 and not on a sanctions list, and nothing else, and
nothing public names the user.

- `src/`: the page (Vite + React). Its "Verify with ZKPassport" button is ZKPassport's hosted flow
  (`VerifyWithZKPassport` from [`@zkpassport/ui`](https://www.npmjs.com/package/@zkpassport/ui)),
  which opens ZKPassport's verification window. It shows the terms (`src/terms.ts`) and offers the
  button once they're accepted. It asks for a proof of age and sanctions screening in `compressed`
  mode, bound to the user's Aztec address, the relayer's network and the terms' digest, against the
  registries the network's ZKPassport registry mirrors (Sepolia's on the testnet and on a local
  network, which takes the SDK's dev mode). It accepts an ID its issuer signed, read from its chip or an
  Aadhaar, or one read by the camera of ZKPassport's app (verification tiers 1 and 2); the app only
  reads by camera for the domains ZKPassport lists for it, and adds a strict face match to an
  Aadhaar's proof. The page sends the proof to the relayer. Each market
  card shows the orders the market contract has counted, and the result of your own order. The
  address is an Aztec account the page makes in this browser, with an embedded wallet that keeps its
  secret key in `localStorage`. The account is never deployed: it receives the credential note and
  sends its own orders. The wallet reads the credential with the contract's `has_credential` utility
  function, looking for notes tagged from the relayer's account. An order is a `place_order`
  transaction the wallet proves in the browser; the market calls `assert_has_credential` for the
  sender and its policy, which only the holder's wallet can satisfy, from its own notes. Fees go
  through the network's sponsored fee contract. Clearing the browser's storage loses the account and
  its credential.
- `server/`: the relayer. On first start it deploys two `ZKPassportCredentials` contracts for the
  page's domain, one that accepts only real passports and one in dev mode that also accepts
  ZKPassport's mock passports. On each it creates two trader policies bound to the terms' digest
  and accepting camera reads, one that each passport claims once and one it can claim again, and it deploys a `FortunaMarket`
  for one of them. It then proves and sends each claim with the user's proof:
  `claim_age_and_sanctions(user, policy)` for a chip read's `outer_count_<n>` proof,
  `claim_age_and_sanctions_from_camera_read` for a camera read's `outer_attested_id_count_<n>`,
  `claim_age_and_sanctions_with_face_match` for an Aadhaar's `outer_aadhaar_count_<n>`. It can't read the credentials, which are private to their holders. Fees go through
  the testnet's sponsored fee contract. The proof's capsules come from the SDK's
  `getAztecVerifierParameters`, delivered to the credentials contract with `toAztecCapsules`. That,
  ZKPassport's registry artifact and its registration with the relayer's wallet come from
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

Click **Verify with ZKPassport** and scan the code in ZKPassport's window with the ZKPassport app.
The request travels through ZKPassport's bridge, so the phone does not need to reach this machine.

The relayer reads:

- `AZTEC_NODE_URL`: the Aztec node, `https://aztec-testnet.drpc.org` by default;
- `REGISTRY_ADDRESS`: ZKPassport's registry on that network, the testnet's by default;
- `APP_DOMAIN`: the host the page is served from, `localhost` by default. Proofs commit to it, so
  the credentials contracts only accept proofs requested from that host;
- `ONE_CLAIM_PER_PASSPORT`: `1` puts the markets on the policy each passport claims once. By default
  they take the repeatable policy, so the same passport can test repeatedly. The markets for the two
  policies are recorded apart;
- `PORT`: 3001 by default.

`server/deployments.json` records the contracts it deployed, by node, domain and terms digest, so
changing the terms deploys new contracts. A recorded contract the node no longer has, or has with
older code, is deployed again.

## Local network

Point the relayer at a local network and it sets one up for proofs made against Sepolia's
registries, which dev-mode requests use:

```bash
aztec start --local-network   # in another shell
AZTEC_NODE_URL=http://localhost:8080 npm run server
npm start
```

On first start it deploys ZKPassport's registry from `zkpassport/target/` (see
`scripts/fetch-zkpassport.sh` above), where `verify_zkpassport_proof` looks for it on a local
network, with the network's test accounts as admin and operator. It seeds it with Sepolia's latest
certificate root, the circuit root of circuits 0.23.0 and their `outer_count_5` vk, and warps the
network's time past the registry's 24-hour delay. The relayer then sends from a test account, paying
with its Fee Juice.

A proof binds the network it is verified on, and a ZKPassport request can only name Aztec mainnet or
testnet, so the ZKPassport app can't make a proof the credentials contracts on a local network
accept. The page says so instead of requesting one.
