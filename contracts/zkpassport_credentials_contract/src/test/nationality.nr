use crate::test::fixtures::{
    age_blob, blob_with, bound_to, Deployment, fixture_address, POLICY, setup,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use aztec::protocol::address::AztecAddress;
use zkpassport::commitments::disclose_commitment;
use zkpassport::disclosed_data::{MRZ_DOC_TYPE_INDEX, TD3_NATIONALITY_INDEX};

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

fn disclose_blob(mask: [bool; 90], bytes: [u8; 90]) -> [Field; 585] {
    blob_with(disclose_commitment(mask, bytes))
}

// A deployment with a French nationality policy
unconstrained fn setup_french(one_claim_per_passport: bool) -> Deployment {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::nationality("FRA"), one_claim_per_passport);
    deployment
}

// Claims the policy's credential for `user` with a French passport's disclose proof
unconstrained fn claim_as_french(deployment: &mut Deployment, user: AztecAddress) {
    let relayer = deployment.env.create_light_account();
    let (mask, bytes) = passport_disclosure("FRA");
    deployment.deliver(
        relayer,
        bound_to(user, disclose_blob(mask, bytes)),
        Option::some(disclose_payload(mask, bytes)),
        Option::none(),
    );
    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_nationality(user, POLICY),
    );
}

#[test]
unconstrained fn claim_succeeds_with_accepted_nationality() {
    let mut deployment = setup_french(true);
    let user = deployment.env.create_light_account();

    assert(!deployment.has_credential(user, POLICY));
    claim_as_french(&mut deployment, user);
    assert(deployment.has_credential(user, POLICY));
}

#[test(should_fail_with = "nationality not accepted")]
unconstrained fn claim_with_other_nationality_fails() {
    let mut deployment = setup_french(true);
    let relayer = deployment.env.create_light_account();

    let (mask, bytes) = passport_disclosure("DEU");
    deployment.deliver(
        relayer,
        disclose_blob(mask, bytes),
        Option::some(disclose_payload(mask, bytes)),
        Option::none(),
    );

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_nationality(
            fixture_address(),
            POLICY,
        ),
    );
}

// The proof discloses DEU; the sender puts an FRA payload in the disclose capsule
#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_substituted_payload_fails() {
    let mut deployment = setup_french(true);
    let relayer = deployment.env.create_light_account();

    let (proved_mask, proved_bytes) = passport_disclosure("DEU");
    let (claimed_mask, claimed_bytes) = passport_disclosure("FRA");
    deployment.deliver(
        relayer,
        disclose_blob(proved_mask, proved_bytes),
        Option::some(disclose_payload(claimed_mask, claimed_bytes)),
        Option::none(),
    );

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_nationality(
            fixture_address(),
            POLICY,
        ),
    );
}

#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_proof_without_disclose_fails() {
    let mut deployment = setup_french(true);
    let relayer = deployment.env.create_light_account();

    let (mask, bytes) = passport_disclosure("FRA");
    deployment.deliver(
        relayer,
        age_blob(),
        Option::some(disclose_payload(mask, bytes)),
        Option::none(),
    );

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_nationality(
            fixture_address(),
            POLICY,
        ),
    );
}

#[test(should_fail_with = "missing disclose capsule")]
unconstrained fn claim_without_disclose_capsule_fails() {
    let mut deployment = setup_french(true);
    let relayer = deployment.env.create_light_account();

    let (mask, bytes) = passport_disclosure("FRA");
    deployment.deliver(relayer, disclose_blob(mask, bytes), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_nationality(
            fixture_address(),
            POLICY,
        ),
    );
}

// The nullifier collision fails outside the contract's asserts, so no message is pinned
#[test(should_fail)]
unconstrained fn second_claim_same_passport_fails() {
    let mut deployment = setup_french(true);
    let user = deployment.env.create_light_account();

    claim_as_french(&mut deployment, user);
    claim_as_french(&mut deployment, user);
}

#[test]
unconstrained fn a_passport_claims_again_under_a_repeatable_policy() {
    let mut deployment = setup_french(false);
    let user = deployment.env.create_light_account();

    claim_as_french(&mut deployment, user);
    claim_as_french(&mut deployment, user);

    assert(deployment.has_credential(user, POLICY));
}
