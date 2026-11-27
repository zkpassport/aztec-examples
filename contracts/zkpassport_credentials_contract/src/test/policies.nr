use crate::test::fixtures::{age_blob, bound_to, NO_CUSTOM_DATA, OTHER_POLICY, POLICY, setup};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;

#[test(should_fail_with = "only the deployer creates policies")]
unconstrained fn only_the_deployer_creates_policies() {
    let mut deployment = setup();
    let stranger = deployment.env.create_light_account();

    let _ = deployment.env.call_public(
        stranger,
        ZKPassportCredentials::at(deployment.credentials).create_policy(
            POLICY,
            Requirement::age_min(18),
            true,
            false,
            NO_CUSTOM_DATA,
        ),
    );
}

// A policy never changes, so a repeatable one can't replace a one-claim one
#[test(should_fail_with = "duplicate nullifier")]
unconstrained fn a_policy_cannot_be_created_twice() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    deployment.create_policy(POLICY, Requirement::age_min(18), false);
}

#[test(should_fail_with = "no claim function for this requirement")]
unconstrained fn a_policy_no_claim_function_verifies_fails() {
    let mut deployment = setup();
    deployment.create_policy(
        POLICY,
        Requirement { min_age: 18, sanctions: false, nationality: "FRA".as_bytes() },
        true,
    );
}

#[test(should_fail_with = "no claim function for this requirement")]
unconstrained fn a_policy_that_asks_for_nothing_fails() {
    let mut deployment = setup();
    deployment.create_policy(
        POLICY,
        Requirement { min_age: 0, sanctions: false, nationality: [0; 3] },
        true,
    );
}

#[test(should_fail_with = "uninitialized PublicImmutable")]
unconstrained fn a_claim_under_a_policy_nobody_created_fails() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(user, POLICY),
    );
}

#[test(should_fail_with = "policy asks for another proof")]
unconstrained fn a_claim_of_another_kind_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_nationality(user, POLICY),
    );
}

// Each one-claim policy has its own nullifier, so the same passport claims both
#[test]
unconstrained fn a_passport_claims_once_under_each_one_claim_policy() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    deployment.create_policy(OTHER_POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    let credentials = ZKPassportCredentials::at(deployment.credentials);

    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());
    let _ = deployment.env.call_private(relayer, credentials.claim_age(user, POLICY));
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());
    let _ = deployment.env.call_private(relayer, credentials.claim_age(user, OTHER_POLICY));

    assert(deployment.has_credential(user, POLICY));
    assert(deployment.has_credential(user, OTHER_POLICY));
}

#[test(should_fail_with = "no credential")]
unconstrained fn a_credential_of_another_policy_does_not_count() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    deployment.create_policy(OTHER_POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    let credentials = ZKPassportCredentials::at(deployment.credentials);
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());
    let _ = deployment.env.call_private(relayer, credentials.claim_age(user, POLICY));

    assert(!deployment.has_credential(user, OTHER_POLICY));
    let _ =
        deployment.env.call_private(user, credentials.assert_has_credential(user, OTHER_POLICY));
}
