use crate::test::fixtures::{
    age_blob, blob_with, bound_to, bound_to_with, DAY, Deployment, FIXTURE_DOMAIN, POLICY, setup,
    setup_with,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use aztec::protocol::address::AztecAddress;
use zkpassport::commitments::sanctions_commitment;
use zkpassport::fixtures::proof::AGE_FIXTURE_CURRENT_DATE;

// A SHA-256 digest in lowercase hex, as of terms a user accepts
global TERMS: str<64> = "2575dc5405d2bf5b88d4439e187966cd748145c96833e11d15780e2d60db515e";
global OTHER_TERMS: str<64> = "0b8d3c0f1e0a1f3b6e9d2c4a5b7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

// A deployment with an 18+ policy whose proofs must be bound to TERMS
unconstrained fn setup_terms() -> Deployment {
    let mut deployment = setup();
    deployment.create_policy_bound_to(POLICY, Requirement::age_min(18), true, TERMS.as_bytes());
    deployment
}

unconstrained fn claim_age(deployment: &mut Deployment, user: AztecAddress, blob: [Field; 585]) {
    deployment.deliver(user, blob, Option::none(), Option::none());
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age(user, POLICY),
    );
}

#[test]
unconstrained fn claim_with_the_policys_custom_data_succeeds() {
    let mut deployment = setup_terms();
    let user = deployment.env.create_light_account();

    claim_age(
        &mut deployment,
        user,
        bound_to_with(user, TERMS.as_bytes(), age_blob()),
    );

    assert(deployment.has_credential(user, POLICY));
}

#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_other_custom_data_fails() {
    let mut deployment = setup_terms();
    let user = deployment.env.create_light_account();

    claim_age(
        &mut deployment,
        user,
        bound_to_with(user, OTHER_TERMS.as_bytes(), age_blob()),
    );
}

#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_without_the_policys_custom_data_fails() {
    let mut deployment = setup_terms();
    let user = deployment.env.create_light_account();

    claim_age(&mut deployment, user, bound_to(user, age_blob()));
}

#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_with_custom_data_a_policy_does_not_ask_for_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();

    claim_age(
        &mut deployment,
        user,
        bound_to_with(user, TERMS.as_bytes(), age_blob()),
    );
}

#[test]
unconstrained fn a_sanctions_policy_binds_its_custom_data_too() {
    let root = 0x5a5a;
    let mut deployment = setup_with(
        FIXTURE_DOMAIN,
        false,
        [(root, AGE_FIXTURE_CURRENT_DATE - DAY)],
    );
    deployment.create_policy_bound_to(POLICY, Requirement::sanctions(), true, TERMS.as_bytes());
    let user = deployment.env.create_light_account();

    deployment.deliver(
        user,
        bound_to_with(
            user,
            TERMS.as_bytes(),
            blob_with(sanctions_commitment(root, true)),
        ),
        Option::none(),
        Option::some(root),
    );
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_sanctions(user, POLICY),
    );

    assert(deployment.has_credential(user, POLICY));
}
