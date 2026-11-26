use crate::test::fixtures::{
    age_blob, bound_to, bound_to_with, DAY, Deployment, FIXTURE_DOMAIN, POLICY, setup_with,
    with_commitment_added,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use aztec::protocol::address::AztecAddress;
use zkpassport::commitments::{nationality_inclusion_commitment, sanctions_commitment};
use zkpassport::fixtures::proof::AGE_FIXTURE_CURRENT_DATE;

global SANCTIONS_ROOT: Field = 0x5a5a;
global TERMS: str<64> = "2575dc5405d2bf5b88d4439e187966cd748145c96833e11d15780e2d60db515e";

// A deployment with the registry holding SANCTIONS_ROOT since a day before the proof
unconstrained fn setup() -> Deployment {
    setup_with(
        FIXTURE_DOMAIN,
        false,
        [(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)],
    )
}

// A proof of {age(18, 0), bind(user), sanctions(SANCTIONS_ROOT)}
fn proof_for(user: AztecAddress) -> [Field; 586] {
    with_commitment_added(
        bound_to(user, age_blob()),
        sanctions_commitment(SANCTIONS_ROOT, true),
    )
}

unconstrained fn claim<let N: u32>(
    deployment: &mut Deployment,
    user: AztecAddress,
    blob: [Field; N],
    sanctions_root: Option<Field>,
) {
    deployment.deliver(user, blob, Option::none(), sanctions_root);
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions(user, POLICY),
    );
}

#[test]
unconstrained fn claim_succeeds_with_a_proof_of_age_and_sanctions() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    let user = deployment.env.create_light_account();

    claim(
        &mut deployment,
        user,
        proof_for(user),
        Option::some(SANCTIONS_ROOT),
    );

    assert(deployment.has_credential(user, POLICY));
}

#[test]
unconstrained fn claim_binds_the_policys_custom_data_too() {
    let mut deployment = setup();
    deployment.create_policy_bound_to(
        POLICY,
        Requirement::age_min_and_sanctions(18),
        true,
        TERMS.as_bytes(),
    );
    let user = deployment.env.create_light_account();
    let blob = with_commitment_added(
        bound_to_with(user, TERMS.as_bytes(), age_blob()),
        sanctions_commitment(SANCTIONS_ROOT, true),
    );

    claim(&mut deployment, user, blob, Option::some(SANCTIONS_ROOT));

    assert(deployment.has_credential(user, POLICY));
}

#[test(should_fail_with = "Expected 586 but got 585")]
unconstrained fn claim_with_a_proof_of_age_alone_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    let user = deployment.env.create_light_account();

    claim(
        &mut deployment,
        user,
        bound_to(user, age_blob()),
        Option::some(SANCTIONS_ROOT),
    );
}

#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_another_check_in_place_of_sanctions_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    let user = deployment.env.create_light_account();
    let blob = with_commitment_added(
        bound_to(user, age_blob()),
        nationality_inclusion_commitment(["FRA"]),
    );

    claim(&mut deployment, user, blob, Option::some(SANCTIONS_ROOT));
}

#[test(should_fail_with = "missing sanctions capsule")]
unconstrained fn claim_without_the_sanctions_capsule_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    let user = deployment.env.create_light_account();

    claim(&mut deployment, user, proof_for(user), Option::none());
}

#[test(should_fail_with = "policy asks for another proof")]
unconstrained fn an_age_policy_does_not_take_a_proof_of_age_and_sanctions() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();

    claim(
        &mut deployment,
        user,
        proof_for(user),
        Option::some(SANCTIONS_ROOT),
    );
}

#[test(should_fail_with = "duplicate nullifiers")]
unconstrained fn second_claim_same_passport_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    let user = deployment.env.create_light_account();
    let other = deployment.env.create_light_account();

    claim(
        &mut deployment,
        user,
        proof_for(user),
        Option::some(SANCTIONS_ROOT),
    );
    claim(
        &mut deployment,
        other,
        proof_for(other),
        Option::some(SANCTIONS_ROOT),
    );
}
