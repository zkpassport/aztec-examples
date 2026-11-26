// TXE no-ops the recursion opcode, so these tests cover the market's use of the credential, not
// proof validity, which the credentials contract's own tests and test-harness cover.
use crate::FortunaMarket;
use aztec::{
    oracle::capsules,
    protocol::{address::AztecAddress, traits::ToField},
    test::helpers::test_environment::TestEnvironment,
};
use zkpassport::commitments::bind_commitment;
use zkpassport::constants::{PI_PARAMS_START, PROOF_FIELDS, VK_FIELDS};
use zkpassport::fixtures::proof::{
    AGE_FIXTURE_BIND_ADDRESS, AGE_FIXTURE_CERT_ROOT, AGE_FIXTURE_CIRCUIT_ROOT,
    AGE_FIXTURE_CIRCUIT_VERSION, AGE_FIXTURE_CURRENT_DATE, AGE_FIXTURE_VK_HASH,
};
use zkpassport::fixtures::txe::{age_fixture_blob_for_txe, TXE_CHAIN_ID};
use zkpassport_aztec_verifier::{constants::PROOF_CAPSULE_SLOT, verify::scope_hash};
use zkpassport_credentials_contract::ZKPassportCredentials;
use zkpassport_credentials_contract::ZKPassportCredentials::Requirement;
use zkpassport_registry_contract::local_network_registry::{
    deploy_local_network_registry, seed_local_network_registry,
};

global MARKET: Field = 1;

global ADULTS: Field = 1;
global OTHER_ADULTS: Field = 2;

// The local network registry seeded with the age fixture's roots and vk, a ZKPassportCredentials
// contract for the fixture's domain with two 18+ policies, and a FortunaMarket that requires
// ADULTS' credential
unconstrained fn setup() -> (TestEnvironment, AztecAddress, AztecAddress) {
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
    // Lands the registry's scheduled changes and keeps the fixture inside its validity period
    env.mine_block_at(AGE_FIXTURE_CURRENT_DATE + 86401);

    let deployer = env.create_light_account();
    let credentials = env
        .deploy("@zkpassport_credentials_contract/ZKPassportCredentials")
        .with_public_initializer(
            deployer,
            ZKPassportCredentials::interface().constructor(scope_hash("example.com"), false),
        );
    for policy_id in [ADULTS, OTHER_ADULTS] {
        let _ = env.call_public(
            deployer,
            ZKPassportCredentials::at(credentials).create_policy(
                policy_id,
                Requirement::age_min(18),
                true,
                [0; 64],
            ),
        );
    }
    let market = env.deploy("FortunaMarket").with_public_initializer(
        deployer,
        FortunaMarket::interface().constructor(credentials, ADULTS),
    );
    (env, credentials, market)
}

// A relayer claims `user`'s credential of `policy_id` with the age fixture, re-bound to `user`:
// the fixture's own address has no keys in TXE, so it couldn't read its note
unconstrained fn claim_credential(
    env: &mut TestEnvironment,
    credentials: AztecAddress,
    user: AztecAddress,
    policy_id: Field,
) {
    let relayer = env.create_light_account();

    let fixture_bind = bind_commitment(
        Option::some(AGE_FIXTURE_BIND_ADDRESS),
        TXE_CHAIN_ID,
        Option::none(),
    );
    let mut blob = age_fixture_blob_for_txe();
    let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
    for i in params_start..params_start + 2 {
        if blob[i] == fixture_bind {
            blob[i] = bind_commitment(Option::some(user.to_field()), TXE_CHAIN_ID, Option::none());
        }
    }
    env.utility_context_at(credentials, |_| {
        capsules::store(credentials, PROOF_CAPSULE_SLOT, blob, relayer);
    });

    let _ = env.call_private(
        relayer,
        ZKPassportCredentials::at(credentials).claim_age(user, policy_id),
    );
}

#[test(should_fail_with = "no credential")]
unconstrained fn an_order_without_the_credential_fails() {
    let (mut env, _, market) = setup();
    let trader = env.create_light_account();

    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));
}

#[test]
unconstrained fn an_order_with_the_credential_is_placed() {
    let (mut env, credentials, market) = setup();
    let trader = env.create_light_account();
    claim_credential(&mut env, credentials, trader, ADULTS);

    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));
    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, false));
    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));

    assert_eq(env.view_public(FortunaMarket::at(market).orders(MARKET, true)), 2);
    assert_eq(env.view_public(FortunaMarket::at(market).orders(MARKET, false)), 1);
}

// The credential belongs to the account it was claimed for: another trader's wallet has no such
// note
#[test(should_fail_with = "no credential")]
unconstrained fn another_traders_credential_does_not_open_the_market() {
    let (mut env, credentials, market) = setup();
    let holder = env.create_light_account();
    claim_credential(&mut env, credentials, holder, ADULTS);
    let other = env.create_light_account();

    let _ = env.call_private(other, FortunaMarket::at(market).place_order(MARKET, true));
}

// The market requires its own policy's credential, even where another policy asks the same
#[test(should_fail_with = "no credential")]
unconstrained fn a_credential_of_another_policy_does_not_open_the_market() {
    let (mut env, credentials, market) = setup();
    let trader = env.create_light_account();
    claim_credential(&mut env, credentials, trader, OTHER_ADULTS);

    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));
}
