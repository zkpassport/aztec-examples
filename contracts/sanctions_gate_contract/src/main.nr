use aztec::macros::aztec;

#[aztec]
pub contract SanctionsGate {
    use aztec::{
        macros::{functions::{external, only_self, view}, storage::storage},
        protocol::address::AztecAddress,
        state_vars::{Map, PublicMutable},
    };
    use zkpassport_aztec_verifier::constants::NULLIFIER_TYPE_NON_SALTED;
    use zkpassport_aztec_verifier::query::Query;
    use zkpassport_aztec_verifier::verify::{
        emit_uniqueness_nullifier, scope_hash, ServiceConfig, verify_zkpassport_proof,
    };

    // The domain this app's ZKPassport requests come from. The fixture proof was made for it.
    global DOMAIN: Field = scope_hash("example.com");

    // Circuit-manifest version this app accepts; the tests seed the registry with it.
    // This is packed("0.22.0"), the circuits release the fixtures and the app prove with.
    pub global CIRCUIT_MANIFEST_VERSION: Field =
        0x0000001600000000000000000000000000000000000000000000000000000000;

    #[storage]
    struct Storage<Context> {
        badges: Map<AztecAddress, PublicMutable<bool, Context>, Context>,
    }

    /// Claim the badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {sanctions, bind(user)}) that its holder is not on the sanctions lists,
    /// burns the unique identifier (one claim per passport) and grants `user` the public badge.
    ///
    /// The sanctions root the proof was screened against rides in its own capsule.
    /// verify_zkpassport_proof checks it against the proof, and in the registry at the proof's
    /// date.
    #[external("private")]
    fn claim(user: AztecAddress) {
        let config = ServiceConfig {
            version: CIRCUIT_MANIFEST_VERSION,
            domain: DOMAIN,
            scope: 0,
            unique_identifier_type: NULLIFIER_TYPE_NON_SALTED,
            validity_period: 7 * 86400,
            dev_mode: false,
        };

        let query = Query::new().sanctions().bind_user_address(user);

        // The capsules ride in the sender's PXE, so they are scoped to the sender, who may be a
        // relayer, not `user`.
        let verified = verify_zkpassport_proof(self.context, self.msg_sender(), config, query);

        emit_uniqueness_nullifier(self.context, verified.unique_identifier);

        self.enqueue_self._grant_badge(user);
    }

    #[external("public")]
    #[only_self]
    fn _grant_badge(user: AztecAddress) {
        self.storage.badges.at(user).write(true);
    }

    #[external("public")]
    #[view]
    fn has_badge(user: AztecAddress) -> bool {
        self.storage.badges.at(user).read()
    }
}

// TXE no-ops the recursion opcode, so these tests prove the wiring (capsules → sanctions
// commitment → registry views → nullifier), NOT proof validity. Proof validity is covered by
// zkpassport-packages' test-harness.
mod test {
    use crate::SanctionsGate;
    use aztec::{
        oracle::capsules,
        protocol::{address::AztecAddress, traits::FromField},
        test::helpers::test_environment::TestEnvironment,
    };
    use zkpassport::commitments::{age_commitment, sanctions_commitment};
    use zkpassport::constants::{PI_PARAMS_START, PROOF_FIELDS, VK_FIELDS};
    use zkpassport::fixtures::proof::{
        AGE_FIXTURE_BIND_ADDRESS, AGE_FIXTURE_CERT_ROOT, AGE_FIXTURE_CIRCUIT_ROOT,
        AGE_FIXTURE_CURRENT_DATE, AGE_FIXTURE_VK_HASH,
    };
    use zkpassport::fixtures::txe::age_fixture_blob_for_txe;
    use zkpassport_aztec_verifier::constants::{PROOF_CAPSULE_SLOT, SANCTIONS_CAPSULE_SLOT};
    use zkpassport_registry_contract::{
        local_network_registry::{
            deploy_local_network_registry, LOCAL_NETWORK_REGISTRY_ADDRESS,
            LOCAL_NETWORK_REGISTRY_OPERATOR, seed_local_network_registry,
        },
        types::REGISTRY_SANCTIONS,
        ZKPassportRegistry,
    };

    global DAY: u64 = 86400;
    global SANCTIONS_ROOT: Field = 0x5a5a;
    global OLD_SANCTIONS_ROOT: Field = 0x5b5b;

    // Deploys the local network registry, seeded with the age fixture's roots and vk and with
    // `sanctions_roots` as (root, valid from) in publishing order, and SanctionsGate. Time ends a
    // day and a second after the proof's date: past the registry's 24h delay, which counts from
    // TXE's start, and inside the proof's 7-day validity period.
    unconstrained fn setup<let N: u32>(
        sanctions_roots: [(Field, u64); N],
    ) -> (TestEnvironment, AztecAddress) {
        let mut env = TestEnvironment::new();

        let _ = deploy_local_network_registry(
            &mut env,
            "zkpassport@zkpassport_registry_contract/ZKPassportRegistry",
        );
        seed_local_network_registry(
            &mut env,
            SanctionsGate::CIRCUIT_MANIFEST_VERSION,
            AGE_FIXTURE_CERT_ROOT,
            AGE_FIXTURE_CIRCUIT_ROOT,
            AGE_FIXTURE_VK_HASH,
            AGE_FIXTURE_CURRENT_DATE - 100,
        );

        let registry = ZKPassportRegistry::at(LOCAL_NETWORK_REGISTRY_ADDRESS);
        let mut current_root = 0;
        for i in 0..N {
            let (root, valid_from) = sanctions_roots[i];
            let _ = env.call_public(
                LOCAL_NETWORK_REGISTRY_OPERATOR,
                registry.update_root(REGISTRY_SANCTIONS, root, current_root, valid_from),
            );
            current_root = root;
        }

        env.mine_block_at(AGE_FIXTURE_CURRENT_DATE + DAY + 1);

        let gate = env.deploy("SanctionsGate").without_initializer();
        (env, gate)
    }

    // The age fixture is a real outer_count_5 proof with param commitments {age(18, 0), bind}.
    // Swapping its age commitment for a sanctions commitment gives a proof of {sanctions, bind}
    // with the fixture's roots, date, vk and bound address.
    fn sanctions_blob(root: Field) -> [Field; 583] {
        let mut blob = age_fixture_blob_for_txe();
        let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
        for i in params_start..params_start + 2 {
            if blob[i] == age_commitment(18, 0) {
                blob[i] = sanctions_commitment(root, false);
            }
        }
        blob
    }

    // The capsules are scoped to the account that sends the claim, not to the bound address
    unconstrained fn deliver_capsules(
        env: &mut TestEnvironment,
        gate: AztecAddress,
        sender: AztecAddress,
        proven_root: Field,
        sanctions_root: Option<Field>,
    ) {
        env.utility_context_at(gate, |_| {
            capsules::store(
                gate,
                PROOF_CAPSULE_SLOT,
                sanctions_blob(proven_root),
                sender,
            );
            if sanctions_root.is_some() {
                capsules::store(
                    gate,
                    SANCTIONS_CAPSULE_SLOT,
                    sanctions_root.unwrap(),
                    sender,
                );
            }
        });
    }

    #[test]
    unconstrained fn claim_succeeds_with_the_latest_sanctions_root() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );

        assert(!env.view_public(SanctionsGate::at(gate).has_badge(user)));
        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
        assert(env.view_public(SanctionsGate::at(gate).has_badge(user)));
    }

    // The registry checks the root at the proof's date, so a list replaced after the proof was
    // made still counts, although it was replaced more than a day before the claim
    #[test]
    unconstrained fn claim_succeeds_with_a_root_replaced_after_the_proof_was_made() {
        let (mut env, gate) = setup([
            (OLD_SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 3 * DAY),
            (SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE),
        ]);
        let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            OLD_SANCTIONS_ROOT,
            Option::some(OLD_SANCTIONS_ROOT),
        );

        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
        assert(env.view_public(SanctionsGate::at(gate).has_badge(user)));
    }

    #[test(should_fail_with = "invalid sanctions registry root")]
    unconstrained fn claim_with_a_root_the_registry_does_not_have_fails() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            OLD_SANCTIONS_ROOT,
            Option::some(OLD_SANCTIONS_ROOT),
        );

        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
    }

    // The registry's validity window is a day: a root replaced two days before the proof is stale
    #[test(should_fail_with = "invalid sanctions registry root")]
    unconstrained fn claim_with_a_root_replaced_before_the_proof_fails() {
        let (mut env, gate) = setup([
            (OLD_SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 3 * DAY),
            (SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 2 * DAY),
        ]);
        let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            OLD_SANCTIONS_ROOT,
            Option::some(OLD_SANCTIONS_ROOT),
        );

        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
    }

    #[test(should_fail_with = "missing sanctions capsule")]
    unconstrained fn claim_without_sanctions_capsule_fails() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
        let relayer = env.create_light_account();

        deliver_capsules(&mut env, gate, relayer, SANCTIONS_ROOT, Option::none());

        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
    }

    // A proof bound to one address must not claim for another
    #[test(should_fail_with = "param commitment mismatch")]
    unconstrained fn claim_for_unbound_address_fails() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let thief = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            thief,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );

        let _ = env.call_private(thief, SanctionsGate::at(gate).claim(thief));
    }

    // Collision message text is kernel-owned (nullifier-already-exists check happens outside our
    // asserts), thus we do not specify a fail message.
    #[test(should_fail)]
    unconstrained fn second_claim_same_passport_fails() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let user = AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS);
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );
        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );
        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
    }
}
