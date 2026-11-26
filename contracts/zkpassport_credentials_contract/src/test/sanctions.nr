use crate::test::fixtures::{
    blob_with, bound_to, DAY, Deployment, FIXTURE_DOMAIN, POLICY, setup_with,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use aztec::protocol::address::AztecAddress;
use zkpassport::commitments::sanctions_commitment;
use zkpassport::fixtures::proof::AGE_FIXTURE_CURRENT_DATE;

global SANCTIONS_ROOT: Field = 0x5a5a;
global OLD_SANCTIONS_ROOT: Field = 0x5b5b;

// A deployment with a sanctions policy, the registry holding `sanctions_roots` as
// (root, valid from) in publishing order
unconstrained fn setup_sanctions<let N: u32>(
    sanctions_roots: [(Field, u64); N],
    one_claim_per_passport: bool,
) -> Deployment {
    let mut deployment = setup_with(FIXTURE_DOMAIN, false, sanctions_roots);
    deployment.create_policy(POLICY, Requirement::sanctions(), one_claim_per_passport);
    deployment
}

// A proof of {sanctions(proven_root), bind(user)}, with `sanctions_root` in its capsule
unconstrained fn claim(
    deployment: &mut Deployment,
    sender: AztecAddress,
    user: AztecAddress,
    proven_root: Field,
    sanctions_root: Option<Field>,
) {
    deployment.deliver(
        sender,
        bound_to(user, blob_with(sanctions_commitment(proven_root, false))),
        Option::none(),
        sanctions_root,
    );
    let _ = deployment.env.call_private(
        sender,
        ZKPassportCredentials::at(deployment.credentials).claim_sanctions(user, POLICY),
    );
}

#[test]
unconstrained fn claim_succeeds_with_the_latest_sanctions_root() {
    let mut deployment = setup_sanctions([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    assert(!deployment.has_credential(user, POLICY));
    claim(
        &mut deployment,
        relayer,
        user,
        SANCTIONS_ROOT,
        Option::some(SANCTIONS_ROOT),
    );
    assert(deployment.has_credential(user, POLICY));
}

// The registry checks the root at the proof's date, so a list replaced after the proof was made
// still counts, although it was replaced more than a day before the claim
#[test]
unconstrained fn claim_succeeds_with_a_root_replaced_after_the_proof_was_made() {
    let mut deployment = setup_sanctions(
        [
            (OLD_SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 3 * DAY),
            (SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE),
        ],
        true,
    );
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    claim(
        &mut deployment,
        relayer,
        user,
        OLD_SANCTIONS_ROOT,
        Option::some(OLD_SANCTIONS_ROOT),
    );
    assert(deployment.has_credential(user, POLICY));
}

#[test(should_fail_with = "invalid sanctions registry root")]
unconstrained fn claim_with_a_root_the_registry_does_not_have_fails() {
    let mut deployment = setup_sanctions([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    claim(
        &mut deployment,
        relayer,
        user,
        OLD_SANCTIONS_ROOT,
        Option::some(OLD_SANCTIONS_ROOT),
    );
}

// The registry's validity window is a day: a root replaced two days before the proof is stale
#[test(should_fail_with = "invalid sanctions registry root")]
unconstrained fn claim_with_a_root_replaced_before_the_proof_fails() {
    let mut deployment = setup_sanctions(
        [
            (OLD_SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 3 * DAY),
            (SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 2 * DAY),
        ],
        true,
    );
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    claim(
        &mut deployment,
        relayer,
        user,
        OLD_SANCTIONS_ROOT,
        Option::some(OLD_SANCTIONS_ROOT),
    );
}

#[test(should_fail_with = "missing sanctions capsule")]
unconstrained fn claim_without_sanctions_capsule_fails() {
    let mut deployment = setup_sanctions([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    claim(
        &mut deployment,
        relayer,
        user,
        SANCTIONS_ROOT,
        Option::none(),
    );
}

// A proof bound to one address must not claim for another
#[test(should_fail_with = "param commitment mismatch")]
unconstrained fn claim_for_unbound_address_fails() {
    let mut deployment = setup_sanctions([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], true);
    let owner = deployment.env.create_light_account();
    let thief = deployment.env.create_light_account();

    deployment.deliver(
        thief,
        bound_to(
            owner,
            blob_with(sanctions_commitment(SANCTIONS_ROOT, false)),
        ),
        Option::none(),
        Option::some(SANCTIONS_ROOT),
    );
    let _ = deployment.env.call_private(
        thief,
        ZKPassportCredentials::at(deployment.credentials).claim_sanctions(thief, POLICY),
    );
}

// The nullifier collision fails outside the contract's asserts, so no message is pinned
#[test(should_fail)]
unconstrained fn second_claim_same_passport_fails() {
    let mut deployment = setup_sanctions([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], true);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    claim(
        &mut deployment,
        relayer,
        user,
        SANCTIONS_ROOT,
        Option::some(SANCTIONS_ROOT),
    );
    claim(
        &mut deployment,
        relayer,
        user,
        SANCTIONS_ROOT,
        Option::some(SANCTIONS_ROOT),
    );
}

#[test]
unconstrained fn a_passport_claims_again_under_a_repeatable_policy() {
    let mut deployment = setup_sanctions([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], false);
    let user = deployment.env.create_light_account();
    let relayer = deployment.env.create_light_account();

    claim(
        &mut deployment,
        relayer,
        user,
        SANCTIONS_ROOT,
        Option::some(SANCTIONS_ROOT),
    );
    claim(
        &mut deployment,
        relayer,
        user,
        SANCTIONS_ROOT,
        Option::some(SANCTIONS_ROOT),
    );

    assert(deployment.has_credential(user, POLICY));
}
