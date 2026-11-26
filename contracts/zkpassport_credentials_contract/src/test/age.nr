use crate::test::fixtures::{
    age_blob, bound_to, fixture_address, FIXTURE_DOMAIN, POLICY, setup, setup_with,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use zkpassport::fixtures::proof::AGE_FIXTURE_CERT_ROOT;
use zkpassport_aztec_verifier::verify::scope_hash;
use zkpassport_registry_contract::{
    local_network_registry::{LOCAL_NETWORK_REGISTRY_ADDRESS, LOCAL_NETWORK_REGISTRY_ADMIN},
    types::{INITIAL_DELAY, REGISTRY_CERTIFICATE},
    ZKPassportRegistry,
};

// The bind commitment, not the transaction sender, authorizes the claim, so the submitting account
// is deliberately another one: any relayer may carry the transaction.
#[test]
unconstrained fn claim_succeeds_with_fixture() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());

    assert(!deployment.has_credential(user, POLICY));

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(user, POLICY),
    );

    // The credential goes to the bound address, not to the account that submitted the claim
    assert(deployment.has_credential(user, POLICY));
    assert(!deployment.has_credential(relayer, POLICY));
}

// Another contract's private function can check the credential, with `user`'s notes
#[test]
unconstrained fn assert_has_credential_passes_for_holder() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());
    let credentials = ZKPassportCredentials::at(deployment.credentials);
    let _ = deployment.env.call_private(relayer, credentials.claim_age(user, POLICY));

    let _ = deployment.env.call_private(user, credentials.assert_has_credential(user, POLICY));
}

#[test(should_fail_with = "no credential")]
unconstrained fn assert_has_credential_fails_without_claim() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();

    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).assert_has_credential(user, POLICY),
    );
}

// A contract deployed with dev mode still accepts a real passport's proof
#[test]
unconstrained fn dev_mode_contract_accepts_a_real_passport() {
    let mut deployment = setup_with(FIXTURE_DOMAIN, true, []);
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(user, POLICY),
    );

    assert(deployment.has_credential(user, POLICY));
}

// The policy's minimum age is the one the proof must commit to: the fixture proves 18, not 21
#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_under_a_higher_minimum_age_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(21), true);
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, age_blob(), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(fixture_address(), POLICY),
    );
}

#[test(should_fail_with = "wrong service domain")]
unconstrained fn claim_for_another_domain_fails() {
    let mut deployment = setup_with(scope_hash("fortuna.example"), false, []);
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, age_blob(), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(fixture_address(), POLICY),
    );
}

// A proof bound to one address must not claim for another
#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_for_unbound_address_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let thief = deployment.env.create_light_account();
    deployment.deliver(thief, age_blob(), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        thief,
        ZKPassportCredentials::at(deployment.credentials).claim_age(thief, POLICY),
    );
}

#[test(should_fail_with = "missing zkpassport proof capsule")]
unconstrained fn claim_without_capsule_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let relayer = deployment.env.create_light_account();

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(fixture_address(), POLICY),
    );
}

#[test(should_fail_with = "invalid certificate registry root")]
unconstrained fn claim_fails_when_root_revoked() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);

    let _ = deployment.env.call_public(
        LOCAL_NETWORK_REGISTRY_ADMIN,
        ZKPassportRegistry::at(LOCAL_NETWORK_REGISTRY_ADDRESS).set_revocation_status(
            REGISTRY_CERTIFICATE,
            AGE_FIXTURE_CERT_ROOT,
            true,
        ),
    );
    deployment.env.mine_block_at(deployment.env.last_block_timestamp() + INITIAL_DELAY);

    let relayer = deployment.env.create_light_account();
    deployment.deliver(relayer, age_blob(), Option::none(), Option::none());

    let _ = deployment.env.call_private(
        relayer,
        ZKPassportCredentials::at(deployment.credentials).claim_age(fixture_address(), POLICY),
    );
}

// The nullifier collision fails outside the contract's asserts, so no message is pinned
#[test(should_fail)]
unconstrained fn second_claim_same_passport_fails() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), true);
    let relayer = deployment.env.create_light_account();
    let credentials = ZKPassportCredentials::at(deployment.credentials);

    deployment.deliver(relayer, age_blob(), Option::none(), Option::none());
    let _ = deployment.env.call_private(relayer, credentials.claim_age(fixture_address(), POLICY));

    deployment.deliver(relayer, age_blob(), Option::none(), Option::none());
    let _ = deployment.env.call_private(relayer, credentials.claim_age(fixture_address(), POLICY));
}

#[test]
unconstrained fn a_passport_claims_again_under_a_repeatable_policy() {
    let mut deployment = setup();
    deployment.create_policy(POLICY, Requirement::age_min(18), false);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();
    let credentials = ZKPassportCredentials::at(deployment.credentials);

    for _ in 0..2 {
        deployment.deliver(relayer, bound_to(user, age_blob()), Option::none(), Option::none());
        let _ = deployment.env.call_private(relayer, credentials.claim_age(user, POLICY));
    }

    assert(deployment.has_credential(user, POLICY));
}
