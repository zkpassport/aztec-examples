# aztec-examples

Example Aztec contracts that verify ZKPassport proofs with the ZKPassport Aztec library in
[zkpassport-packages](https://github.com/zkpassport/zkpassport-packages/tree/main/packages/aztec).

| Contract                              | What it shows                                                                                                                                                                                                                                                         |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `contracts/age_gate_contract`         | An 18+ gate. `claim(user)` verifies a proof of age that is bound to `user` on the gate's network, emits a uniqueness nullifier so each passport claims once, and grants `user` a public badge. Since the proof is bound to `user`, anyone may submit the transaction. |
| `contracts/nationality_gate_contract` | A gate on disclosed data. `claim(user)` verifies a proof that discloses the nationality, reads it from the disclosed bytes, and grants the badge only to French nationals.                                                                                            |
| `contracts/sanctions_gate_contract`   | A sanctions-screened gate. `claim(user)` verifies a proof, bound to `user` on the gate's network, that its holder is not on the sanctions lists, and grants the badge once per passport.                                                                              |

The sanctions gate's client asks the ZKPassport SDK for `.sanctions()` and the bind, and stashes the
sanctions root the proof was screened against, the proof result's
`committedInputs.exclusion_check_sanctions.rootHash`, in the gate's sanctions capsule
(`SANCTIONS_CAPSULE_SLOT`, 3) next to the proof capsule.

## Depending on the library

A contract depends on the library over git, pinned to a zkpassport-packages tag, as the manifests in
`contracts/` do:

```toml
[dependencies]
aztec = { git = "https://github.com/aztec-labs-eng/aztec-nr", tag = "v6.0.0", directory = "aztec" }
zkpassport_aztec_verifier = { git = "https://github.com/zkpassport/zkpassport-packages", tag = "<tag>", directory = "packages/aztec/noir/verifier" }
```

The examples also depend on `zkpassport` (`packages/aztec/noir/core`), for the proof fixtures their
tests use, and on `zkpassport_registry_contract` (`packages/aztec/noir/registry_contract`), for the
local network registry their tests deploy and seed.

`verify_zkpassport_proof` finds ZKPassport's registry on the network by its L1 chain id and rollup
version. In TXE and on a local network that is the local network registry, which the tests and the
e2e deploy at its fixed address.

## Running the tests

The toolchain version is in `.aztecrc`:

```bash
aztec-up install "$(cat .aztecrc)"
eval "$(aztec-up env)"
```

The tests deploy the registry from `zkpassport/target/`, with
`deploy_local_network_registry(&mut env, "zkpassport@zkpassport_registry_contract/ZKPassportRegistry")`.
`scripts/fetch-zkpassport.sh` puts the registry artifact there, and the age proof fixture the e2e
uses in `zkpassport/fixtures/`. It builds both from the zkpassport-packages ref the contracts depend
on, with the toolchain in `.aztecrc`.

```bash
scripts/fetch-zkpassport.sh
aztec compile
aztec test
```

The tests check the contracts' logic, not the proofs: the TXE does not enforce the recursive
verification opcode. The e2e below verifies a real proof.

## End-to-end test on a local network

`scripts/e2e/run-e2e.ts` deploys the local network registry and the age gate to a local Aztec
network, seeds the registry, makes a real `claim()` transaction with the age fixture, and checks
that a second claim with the same passport and a claim with a tampered proof both fail.

```bash
aztec start --local-network   # in another shell
scripts/fetch-zkpassport.sh
aztec compile
cd scripts && npm ci && npm run e2e
```

`AZTEC_NODE_URL` sets the node (default `http://localhost:8080`).

`scripts/artifacts/` holds the TS bindings the e2e uses. After a change to a contract's ABI,
regenerate them from the repo root:

```bash
aztec codegen target/age_gate_contract-AgeGate.json -o scripts/artifacts
aztec codegen zkpassport/target -o scripts/artifacts
```
