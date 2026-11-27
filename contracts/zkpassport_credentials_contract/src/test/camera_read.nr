use crate::test::fixtures::{
    age_blob, bound_to, DAY, Deployment, FIXTURE_DOMAIN, ios_attestation, POLICY, read_by_camera,
    setup_with, with_commitment_added,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use aztec::protocol::address::AztecAddress;
use zkpassport::commitments::sanctions_commitment;
use zkpassport::fixtures::proof::AGE_FIXTURE_CURRENT_DATE;

global SANCTIONS_ROOT: Field = 0x5a5a;

// A deployment with the registry holding SANCTIONS_ROOT since a day before the proof
unconstrained fn setup() -> Deployment {
    setup_with(
        FIXTURE_DOMAIN,
        false,
        [(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)],
    )
}

// A chip read's proof of {age(18, 0), bind(user), sanctions(SANCTIONS_ROOT)}
fn chip_proof_for(user: AztecAddress) -> [Field; 586] {
    with_commitment_added(
        bound_to(user, age_blob()),
        sanctions_commitment(SANCTIONS_ROOT, true),
    )
}

// The same proof from an ID read by the iOS app's camera
fn camera_proof_for(user: AztecAddress) -> [Field; 587] {
    read_by_camera(chip_proof_for(user), ios_attestation())
}

unconstrained fn claim_from_camera_read<let N: u32>(
    deployment: &mut Deployment,
    user: AztecAddress,
    blob: [Field; N],
) {
    deployment.deliver(user, blob, Option::none(), Option::some(SANCTIONS_ROOT));
    deployment.deliver_attestation(user, ios_attestation());
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions_from_camera_read(
            user,
            POLICY,
        ),
    );
}

#[test]
unconstrained fn a_camera_read_earns_the_credential_of_a_policy_that_accepts_one() {
    let mut deployment = setup();
    deployment.create_policy_accepting_camera_reads(
        POLICY,
        Requirement::age_min_and_sanctions(18),
        true,
    );
    let user = deployment.env.create_light_account();

    claim_from_camera_read(&mut deployment, user, camera_proof_for(user));

    assert(deployment.has_credential(user, POLICY));
}

#[test]
unconstrained fn a_chip_read_still_earns_the_credential_of_a_policy_that_accepts_camera_reads() {
    let mut deployment = setup();
    deployment.create_policy_accepting_camera_reads(
        POLICY,
        Requirement::age_min_and_sanctions(18),
        true,
    );
    let user = deployment.env.create_light_account();

    deployment.deliver(user, chip_proof_for(user), Option::none(), Option::some(SANCTIONS_ROOT));
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions(user, POLICY),
    );

    assert(deployment.has_credential(user, POLICY));
}

#[test(should_fail_with = "policy doesn't accept camera reads")]
unconstrained fn a_policy_that_accepts_only_chip_reads_refuses_a_camera_read() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    let user = deployment.env.create_light_account();

    claim_from_camera_read(&mut deployment, user, camera_proof_for(user));
}

#[test(should_fail_with = "policy asks for another proof")]
unconstrained fn an_age_policy_does_not_take_a_camera_read_of_age_and_sanctions() {
    let mut deployment = setup();
    deployment.create_policy_accepting_camera_reads(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();

    claim_from_camera_read(&mut deployment, user, camera_proof_for(user));
}

#[test(should_fail_with = "Expected 587 but got 586")]
unconstrained fn a_chip_read_sent_to_the_camera_read_claim_fails() {
    let mut deployment = setup();
    deployment.create_policy_accepting_camera_reads(
        POLICY,
        Requirement::age_min_and_sanctions(18),
        true,
    );
    let user = deployment.env.create_light_account();

    claim_from_camera_read(&mut deployment, user, chip_proof_for(user));
}

#[test(should_fail_with = "Expected 586 but got 587")]
unconstrained fn a_camera_read_sent_to_the_chip_claim_fails() {
    let mut deployment = setup();
    deployment.create_policy_accepting_camera_reads(
        POLICY,
        Requirement::age_min_and_sanctions(18),
        true,
    );
    let user = deployment.env.create_light_account();

    deployment.deliver(user, camera_proof_for(user), Option::none(), Option::some(SANCTIONS_ROOT));
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions(user, POLICY),
    );
}

#[test(should_fail_with = "missing attested ID capsule")]
unconstrained fn a_camera_read_without_its_attestation_fails() {
    let mut deployment = setup();
    deployment.create_policy_accepting_camera_reads(
        POLICY,
        Requirement::age_min_and_sanctions(18),
        true,
    );
    let user = deployment.env.create_light_account();

    deployment.deliver(user, camera_proof_for(user), Option::none(), Option::some(SANCTIONS_ROOT));
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions_from_camera_read(
            user,
            POLICY,
        ),
    );
}
