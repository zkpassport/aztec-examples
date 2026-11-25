// TXE no-ops the recursion opcode, so these tests prove the wiring (capsules → parse → disclose
// commitment → policy → registry views → nullifier), NOT proof validity. Proof validity is
// covered by test-harness.
use crate::NationalityGate;
use aztec::{
    oracle::capsules,
    protocol::{address::AztecAddress, traits::{FromField, ToField}},
    test::helpers::test_environment::TestEnvironment,
};
use zkpassport::commitments::{age_commitment, bind_commitment, disclose_commitment};
use zkpassport::constants::{PI_PARAMS_START, PROOF_FIELDS, VK_FIELDS};
use zkpassport::disclosed_data::{MRZ_DOC_TYPE_INDEX, TD3_NATIONALITY_INDEX};
use zkpassport::fixtures::proof::{
    AGE_FIXTURE_BIND_ADDRESS, AGE_FIXTURE_CERT_ROOT, AGE_FIXTURE_CIRCUIT_ROOT,
    AGE_FIXTURE_CIRCUIT_VERSION, AGE_FIXTURE_CURRENT_DATE, AGE_FIXTURE_VK_HASH,
};
use zkpassport::fixtures::txe::{age_fixture_blob_for_txe, TXE_CHAIN_ID};
use zkpassport_aztec_verifier::constants::{DISCLOSE_CAPSULE_SLOT, PROOF_CAPSULE_SLOT};
use zkpassport_registry_contract::local_network_registry::{
    deploy_local_network_registry, seed_local_network_registry,
};

// Deploys the local network registry seeded with the age fixture's roots and vk, which the blobs
// below keep, and NationalityGate.
unconstrained fn setup() -> (TestEnvironment, AztecAddress) {
    setup_gate(true)
}

unconstrained fn setup_gate(one_claim_per_passport: bool) -> (TestEnvironment, AztecAddress) {
    let mut env = TestEnvironment::new();

    let _ = deploy_local_network_registry(
        &mut env,
        "zkpassport@zkpassport_registry_contract/ZKPassportRegistry",
    );
    seed_local_network_registry(
        &mut env,
        AGE_FIXTURE_CIRCUIT_VERSION,
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
    let gate = env.deploy("NationalityGate").with_public_initializer(
        deployer,
        NationalityGate::interface().constructor(one_claim_per_passport),
    );
    (env, gate)
}

// A passport MRZ disclosing its document type ("P<") and nationality, nothing else
fn passport_disclosure(nationality: str<3>) -> ([bool; 90], [u8; 90]) {
    let mut mask = [false; 90];
    let mut bytes = [0 as u8; 90];
    for i in 0..2 {
        mask[MRZ_DOC_TYPE_INDEX + i] = true;
        bytes[MRZ_DOC_TYPE_INDEX + i] = "P<".as_bytes()[i];
    }
    for i in 0..3 {
        mask[TD3_NATIONALITY_INDEX + i] = true;
        bytes[TD3_NATIONALITY_INDEX + i] = nationality.as_bytes()[i];
    }

    (mask, bytes)
}

// The disclose capsule's layout: mask ‖ bytes, one value per Field
fn disclose_payload(mask: [bool; 90], bytes: [u8; 90]) -> [Field; 180] {
    let mut payload = [0; 180];
    for i in 0..90 {
        payload[i] = mask[i] as Field;
        payload[90 + i] = bytes[i] as Field;
    }
    payload
}

// The age fixture is a real outer_count_5 proof with param commitments {age(18, 0), bind}.
// Swapping its age commitment for a disclose commitment gives a proof of {disclose, bind} with
// the fixture's roots, date, vk and bound address. Its proof bytes no longer match its public
// inputs, which these tests cannot notice: TXE does not run the recursion opcode.
fn disclose_blob(mask: [bool; 90], bytes: [u8; 90]) -> [Field; 585] {
    let mut blob = age_fixture_blob_for_txe();
    let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
    let mut swapped = 0;
    for i in params_start..params_start + 2 {
        if blob[i] == age_commitment(18, 0) {
            blob[i] = disclose_commitment(mask, bytes);
            swapped += 1;
        }
    }
    assert(swapped == 1, "age fixture has no age commitment to swap");
    blob
}

// The fixture is bound to AGE_FIXTURE_BIND_ADDRESS, which has no keys in TXE, so nobody could
// read a badge minted to it. Re-binding it to `user`, a TXE account, lets `user` see the note.
fn bound_to(user: AztecAddress, mut blob: [Field; 585]) -> [Field; 585] {
    let fixture_bind = bind_commitment(AGE_FIXTURE_BIND_ADDRESS, TXE_CHAIN_ID);
    let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
    let mut swapped = 0;
    for i in params_start..params_start + 2 {
        if blob[i] == fixture_bind {
            blob[i] = bind_commitment(user.to_field(), TXE_CHAIN_ID);
            swapped += 1;
        }
    }
    assert(swapped == 1, "age fixture has no bind commitment to swap");
    blob
}

// The capsules are scoped to the account that will send the claim transaction, not to the
// address the proof is bound to.
unconstrained fn deliver_capsules(
    env: &mut TestEnvironment,
    gate: AztecAddress,
    sender: AztecAddress,
    blob: [Field; 585],
    payload: Option<[Field; 180]>,
) {
    env.utility_context_at(gate, |_| {
        capsules::store(gate, PROOF_CAPSULE_SLOT, blob, sender);
        if payload.is_some() {
            capsules::store(gate, DISCLOSE_CAPSULE_SLOT, payload.unwrap(), sender);
        }
    });
}

#[test]
unconstrained fn claim_succeeds_with_accepted_nationality() {
    let (mut env, gate) = setup();
    let user = env.create_light_account();
    let relayer = env.create_light_account();

    let (mask, bytes) = passport_disclosure("FRA");
    deliver_capsules(
        &mut env,
        gate,
        relayer,
        bound_to(user, disclose_blob(mask, bytes)),
        Option::some(disclose_payload(mask, bytes)),
    );

    assert(!env.execute_utility(NationalityGate::at(gate).has_badge(user)));
    let _ = env.call_private(relayer, NationalityGate::at(gate).claim(user));
    assert(env.execute_utility(NationalityGate::at(gate).has_badge(user)));
    assert(!env.execute_utility(NationalityGate::at(gate).has_badge(relayer)));
}

#[test(should_fail_with = "nationality not accepted")]
unconstrained fn claim_with_other_nationality_fails() {
    let (mut env, gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
    let relayer = env.create_light_account();

    let (mask, bytes) = passport_disclosure("DEU");
    deliver_capsules(
        &mut env,
        gate,
        relayer,
        disclose_blob(mask, bytes),
        Option::some(disclose_payload(mask, bytes)),
    );

    let _ = env.call_private(relayer, NationalityGate::at(gate).claim(user));
}

// The proof discloses DEU; the sender puts an FRA payload in the disclose capsule.
#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_substituted_payload_fails() {
    let (mut env, gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
    let relayer = env.create_light_account();

    let (proved_mask, proved_bytes) = passport_disclosure("DEU");
    let (claimed_mask, claimed_bytes) = passport_disclosure("FRA");
    deliver_capsules(
        &mut env,
        gate,
        relayer,
        disclose_blob(proved_mask, proved_bytes),
        Option::some(disclose_payload(claimed_mask, claimed_bytes)),
    );

    let _ = env.call_private(relayer, NationalityGate::at(gate).claim(user));
}

#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_proof_without_disclose_fails() {
    let (mut env, gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
    let relayer = env.create_light_account();

    let (mask, bytes) = passport_disclosure("FRA");
    deliver_capsules(
        &mut env,
        gate,
        relayer,
        age_fixture_blob_for_txe(),
        Option::some(disclose_payload(mask, bytes)),
    );

    let _ = env.call_private(relayer, NationalityGate::at(gate).claim(user));
}

#[test(should_fail_with = "missing disclose capsule")]
unconstrained fn claim_without_disclose_capsule_fails() {
    let (mut env, gate) = setup();
    let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
    let relayer = env.create_light_account();

    let (mask, bytes) = passport_disclosure("FRA");
    deliver_capsules(
        &mut env,
        gate,
        relayer,
        disclose_blob(mask, bytes),
        Option::none(),
    );

    let _ = env.call_private(relayer, NationalityGate::at(gate).claim(user));
}

// Claims the badge for `user` with a French passport's disclose proof
unconstrained fn claim_as_french(
    env: &mut TestEnvironment,
    gate: AztecAddress,
    user: AztecAddress,
) {
    let relayer = env.create_light_account();
    let (mask, bytes) = passport_disclosure("FRA");
    deliver_capsules(
        env,
        gate,
        relayer,
        bound_to(user, disclose_blob(mask, bytes)),
        Option::some(disclose_payload(mask, bytes)),
    );
    let _ = env.call_private(relayer, NationalityGate::at(gate).claim(user));
}

// The nullifier collision fails outside the contract's asserts, so no message is pinned
#[test(should_fail)]
unconstrained fn second_claim_same_passport_fails() {
    let (mut env, gate) = setup();
    let user = env.create_light_account();

    claim_as_french(&mut env, gate, user);
    claim_as_french(&mut env, gate, user);
}

// A gate deployed without one claim per passport lets the same passport claim again
#[test]
unconstrained fn a_passport_claims_again_when_the_gate_allows_it() {
    let (mut env, gate) = setup_gate(false);
    let user = env.create_light_account();

    claim_as_french(&mut env, gate, user);
    claim_as_french(&mut env, gate, user);

    assert(env.execute_utility(NationalityGate::at(gate).has_badge(user)));
}
