// TXE no-ops the recursion opcode, so these tests cover the market's use of the age gate's badge,
// not proof validity, which the age gate's own tests and test-harness cover.
use crate::FortunaMarket;
use age_gate_contract::AgeGate;
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
use zkpassport_registry_contract::local_network_registry::{
    deploy_local_network_registry, seed_local_network_registry,
};

global MARKET: Field = 1;

// The local network registry seeded with the age fixture's roots and vk, an AgeGate for the
// fixture's domain, and a FortunaMarket that checks its badge.
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
    let age_gate = env.deploy("@age_gate_contract/AgeGate").with_public_initializer(
        deployer,
        AgeGate::interface().constructor(scope_hash("example.com"), false),
    );
    let market = env.deploy("FortunaMarket").with_public_initializer(
        deployer,
        FortunaMarket::interface().constructor(age_gate),
    );
    (env, age_gate, market)
}

// A relayer claims `user`'s badge with the age fixture, re-bound to `user`: the fixture's own
// address has no keys in TXE, so it couldn't read its note
unconstrained fn claim_badge(
    env: &mut TestEnvironment,
    age_gate: AztecAddress,
    user: AztecAddress,
) {
    let relayer = env.create_light_account();

    let fixture_bind = bind_commitment(AGE_FIXTURE_BIND_ADDRESS, TXE_CHAIN_ID);
    let mut blob = age_fixture_blob_for_txe();
    let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
    for i in params_start..params_start + 2 {
        if blob[i] == fixture_bind {
            blob[i] = bind_commitment(user.to_field(), TXE_CHAIN_ID);
        }
    }
    env.utility_context_at(age_gate, |_| {
        capsules::store(age_gate, PROOF_CAPSULE_SLOT, blob, relayer);
    });

    let _ = env.call_private(relayer, AgeGate::at(age_gate).claim(user));
}

#[test(should_fail_with = "no badge")]
unconstrained fn an_order_without_the_badge_fails() {
    let (mut env, _, market) = setup();
    let trader = env.create_light_account();

    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));
}

#[test]
unconstrained fn an_order_with_the_badge_is_placed() {
    let (mut env, age_gate, market) = setup();
    let trader = env.create_light_account();
    claim_badge(&mut env, age_gate, trader);

    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));
    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, false));
    let _ = env.call_private(trader, FortunaMarket::at(market).place_order(MARKET, true));

    assert_eq(env.view_public(FortunaMarket::at(market).orders(MARKET, true)), 2);
    assert_eq(env.view_public(FortunaMarket::at(market).orders(MARKET, false)), 1);
}

// The badge belongs to the account it was claimed for: another trader's wallet has no such note
#[test(should_fail_with = "no badge")]
unconstrained fn another_traders_badge_does_not_open_the_market() {
    let (mut env, age_gate, market) = setup();
    let holder = env.create_light_account();
    claim_badge(&mut env, age_gate, holder);
    let other = env.create_light_account();

    let _ = env.call_private(other, FortunaMarket::at(market).place_order(MARKET, true));
}
