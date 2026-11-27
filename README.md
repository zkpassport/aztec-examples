# aztec-examples

Example Aztec contracts that verify ZKPassport proofs with the ZKPassport Aztec library in
[zkpassport-packages](https://github.com/zkpassport/zkpassport-packages/tree/main/packages/aztec).

| Contract                                    | What it shows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `contracts/zkpassport_credentials_contract` | Private ZKPassport credentials. The deployer sets the domain its requests come from and whether it also accepts ZKPassport's mock passports, and creates policies with `create_policy`. A policy is a requirement (a minimum age, not being on the sanctions lists, both, or a nationality), whether each passport claims its credential once (a uniqueness nullifier per policy) or can claim it again, as in testing, whether an ID read by the camera of ZKPassport's app earns it as well as one read from its chip, and optionally 64 bytes of custom data the proof must be bound to, such as the SHA-256 digest of terms the user accepts. |
| `contracts/fortuna_market_contract`         | Fortuna's market. `place_order` calls the credentials contract's `assert_has_credential` for the sender and the market's policy, so only an account whose wallet holds that credential note can trade.                                                                                                                                                                                                                                                                                                                                           |

A user claims a policy's credential with `claim_age`, `claim_sanctions`, `claim_age_and_sanctions`
or `claim_nationality`, one per combination of checks, which verify a proof bound to the user on the
contract's network and mint the user a private credential note of that policy. Since the proof is
bound to the user, anyone may submit the transaction, and nothing public names the user. Other
contracts check the note with `assert_has_credential(user, policy_id)`, and the holder's wallet
reads it with `has_credential`.

A policy that accepts camera reads also issues its credential through
`claim_age_and_sanctions_from_camera_read`, which verifies the proof of an ID read by the camera of
ZKPassport's app and attested by the device (an `outer_attested_id_count_<n>` proof). The client
stashes the device's attestation, the proof result's `committedInputs.attested_id_ios` or
`attested_id_android`, in the attested ID capsule (`ATTESTED_ID_CAPSULE_SLOT`, 5), as the SDK's
`getAztecVerifierParameters` does. A camera read and a chip read of the same ID have different
unique identifiers, so on a policy that each passport claims once, an ID can claim once by each
read.

A policy with custom data only issues its credential for a proof bound to that data as well as to
the user: the ZKPassport request binds it as `custom_data`, byte for byte.

`claim_nationality` reads the nationality from the proof's disclosed bytes, which ride in the
disclose capsule. For `claim_sanctions` and `claim_age_and_sanctions`, the client asks the
ZKPassport SDK for `.sanctions()` and the bind, and stashes the sanctions root the proof was
screened against, the proof result's `committedInputs.exclusion_check_sanctions.rootHash`, in the
sanctions capsule (`SANCTIONS_CAPSULE_SLOT`, 3) next to the proof capsule.

[`app/`](app/README.md) is Fortuna, a prediction market on the Aztec testnet for traders who are 18
or older and not on a sanctions list, with one credential from one proof of both, made by the
ZKPassport app.

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
`deploy_local_network_registry(&mut env, "zkpassport@zkpassport_registry_contract/ZKPassportRegistry")`,
and the e2e and the app's relayer deploy it from there on a local network.
`scripts/fetch-zkpassport.sh` puts the registry artifact there and the age proof fixture the e2e
uses in `zkpassport/fixtures/`. It takes both from the zkpassport-packages ref the contracts depend
on, and compiles the registry with the toolchain in `.aztecrc`.

```bash
scripts/fetch-zkpassport.sh
aztec compile
aztec test
```

The tests check the contracts' logic, not the proofs: the TXE does not enforce the recursive
verification opcode. The e2e below verifies a real proof.

## End-to-end test on a local network

`scripts/e2e/run-e2e.ts` deploys the local network registry and the credentials contract with an 18+
policy to a local Aztec network, seeds the registry, makes a real `claim_age()` transaction with the
age fixture, and checks that a second claim with the same passport and a claim with a tampered proof
both fail.

Like an app, it takes the registry's artifact and the proof capsule from
[`@zkpassport/aztec`](https://www.npmjs.com/package/@zkpassport/aztec), at the version published
from the zkpassport-packages commit the contracts depend on. Its registry is then the contract class
the contracts compile, and lands where `verify_zkpassport_proof` looks for it. When the contracts
move to another zkpassport-packages ref, move the ZKPassport npm packages to the versions published
from it.

```bash
aztec start --local-network   # in another shell
scripts/fetch-zkpassport.sh
aztec compile
cd scripts && npm ci && npm run e2e
```

`AZTEC_NODE_URL` sets the node (default `http://localhost:8080`).

`scripts/artifacts/` holds the credentials contract's TS binding, which the e2e uses. After a change
to its ABI, regenerate it from the repo root:

```bash
aztec codegen target/zkpassport_credentials_contract-ZKPassportCredentials.json -o scripts/artifacts
```
