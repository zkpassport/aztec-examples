// TXE no-ops the recursion opcode, so this test proves the wiring (capsule → parse → policy →
// registry views → nullifier), NOT proof validity. Proof validity is covered by test-harness.
use crate::AgeGate;
use aztec::{
    oracle::capsules,
    protocol::{address::AztecAddress, traits::FromField},
    test::helpers::test_environment::TestEnvironment,
};
use zkpassport::fixtures::proof::{
    AGE_FIXTURE_BIND_ADDRESS, AGE_FIXTURE_CERT_ROOT, AGE_FIXTURE_CIRCUIT_ROOT,
    AGE_FIXTURE_CURRENT_DATE, AGE_FIXTURE_VK_HASH,
};
use zkpassport::fixtures::txe::age_fixture_blob_for_txe;
use zkpassport_aztec_verifier::verify::scope_hash;
use zkpassport_registry_contract::{
    local_network_registry::{
        deploy_local_network_registry, LOCAL_NETWORK_REGISTRY_ADDRESS, LOCAL_NETWORK_REGISTRY_ADMIN,
        seed_local_network_registry,
    },
    types::{INITIAL_DELAY, REGISTRY_CERTIFICATE},
    ZKPassportRegistry,
};

// Must match AgeGate's CIRCUIT_MANIFEST_VERSION (main.nr): packed("0.22.0"), the version the
// app passes to the registry.
global CIRCUIT_MANIFEST_VERSION: Field =
    0x0000001600000000000000000000000000000000000000000000000000000000;

// The domain the fixture proof was made for.
global FIXTURE_DOMAIN: Field = scope_hash("example.com");

// Deploys the local network registry seeded with the age fixture's roots and vk, and an AgeGate
// for the fixture's domain.
unconstrained fn setup() -> (TestEnvironment, AztecAddress) {
    setup_gate(FIXTURE_DOMAIN, false)
}

unconstrained fn setup_gate(domain: Field, dev_mode: bool) -> (TestEnvironment, AztecAddress) {
    let mut env = TestEnvironment::new();

    let _ = deploy_local_network_registry(
        &mut env,
        "zkpassport@zkpassport_registry_contract/ZKPassportRegistry",
    );
    seed_local_network_registry(
        &mut env,
        CIRCUIT_MANIFEST_VERSION,
        AGE_FIXTURE_CERT_ROOT,
        AGE_FIXTURE_CIRCUIT_ROOT,
        AGE_FIXTURE_VK_HASH,
        AGE_FIXTURE_CURRENT_DATE - 100,
    );

    // The registry's 24h delay counts from TXE's start, real wall-clock time, and time only moves
    // forward. The fixture is dated 2050-01-01, so one jump lands every scheduled change and
    // keeps the proof inside the 7-day validity period.
    env.mine_block_at(AGE_FIXTURE_CURRENT_DATE + 86401);

    let deployer = env.create_light_account();
    let age_gate = env.deploy("AgeGate").with_public_initializer(
        deployer,
        AgeGate::interface().constructor(domain, dev_mode),
    );
    (env, age_gate)
}

// The capsule is scoped to the account that will send the claim transaction (the capsule
// rides in the sender's PXE), not to the address the proof is bound to.
unconstrained fn deliver_capsule(
    env: &mut TestEnvironment,
    age_gate: AztecAddress,
    sender: AztecAddress,
) {
    env.utility_context_at(age_gate, |_| {
        capsules::store(
            age_gate,
            zkpassport_aztec_verifier::constants::PROOF_CAPSULE_SLOT,
            age_fixture_blob_for_txe(),
            sender,
        );
    });
}

// The fixture proof is bound to AGE_FIXTURE_BIND_ADDRESS (its bind subproof's user_address),
// so `user` must be that address. The submitting account is deliberately a different one:
// the bind commitment, not the transaction sender, is what authorizes the claim, so any
// relayer may carry the transaction.
#[test]
unconstrained fn claim_succeeds_with_fixture() {
    let (mut env, age_gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);

    let relayer = env.create_light_account();
    deliver_capsule(&mut env, age_gate, relayer);

    assert(!env.view_public(AgeGate::at(age_gate).has_badge(user)));

    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));

    // The badge goes to the bound address, not to the account that submitted the claim.
    assert(env.view_public(AgeGate::at(age_gate).has_badge(user)));
    assert(!env.view_public(AgeGate::at(age_gate).has_badge(relayer)));
}

// A gate deployed with dev mode still accepts a real passport's proof.
#[test]
unconstrained fn dev_mode_gate_accepts_a_real_passport() {
    let (mut env, age_gate) = setup_gate(FIXTURE_DOMAIN, true);
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);

    let relayer = env.create_light_account();
    deliver_capsule(&mut env, age_gate, relayer);
    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));

    assert(env.view_public(AgeGate::at(age_gate).has_badge(user)));
}

#[test(should_fail_with = "wrong service domain")]
unconstrained fn claim_for_another_domain_fails() {
    let (mut env, age_gate) = setup_gate(scope_hash("fortuna.example"), false);
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);

    let relayer = env.create_light_account();
    deliver_capsule(&mut env, age_gate, relayer);
    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));
}

// A proof bound to one address must not claim for another: same capsule blob, delivered for
// and claimed by an address the proof was NOT bound to.
#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_for_unbound_address_fails() {
    let (mut env, age_gate) = setup();

    let thief = env.create_light_account();
    deliver_capsule(&mut env, age_gate, thief);
    let _ = env.call_private(thief, AgeGate::at(age_gate).claim(thief));
}

#[test(should_fail_with = "missing zkpassport proof capsule")]
unconstrained fn claim_without_capsule_fails() {
    let (mut env, age_gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
    let relayer = env.create_light_account();

    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));
}

#[test(should_fail_with = "invalid certificate registry root")]
unconstrained fn claim_fails_when_root_revoked() {
    let (mut env, age_gate) = setup();

    let _ = env.call_public(
        LOCAL_NETWORK_REGISTRY_ADMIN,
        ZKPassportRegistry::at(LOCAL_NETWORK_REGISTRY_ADDRESS).set_revocation_status(
            REGISTRY_CERTIFICATE,
            AGE_FIXTURE_CERT_ROOT,
            true,
        ),
    );
    env.mine_block_at(env.last_block_timestamp() + INITIAL_DELAY);

    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
    let relayer = env.create_light_account();
    deliver_capsule(&mut env, age_gate, relayer);

    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));
}

// Collision message text is kernel-owned (nullifier-already-exists check happens outside our
// asserts), thus we do not specify a fail message.
#[test(should_fail)]
unconstrained fn second_claim_same_passport_fails() {
    let (mut env, age_gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);

    let relayer = env.create_light_account();
    deliver_capsule(&mut env, age_gate, relayer);

    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));

    // Same fixture again → same unique identifier → tx must be rejected (nullifier collision).
    deliver_capsule(&mut env, age_gate, relayer);
    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));
}
