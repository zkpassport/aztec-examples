use aztec::macros::aztec;

#[aztec]
pub contract SanctionsGate {
    use aztec::{
        macros::{functions::{external, initializer}, notes::note, storage::storage},
        messages::delivery::MessageDelivery,
        note::{note_getter_options::NoteGetterOptions, note_viewer_options::NoteViewerOptions},
        protocol::{address::AztecAddress, traits::{Deserialize, Packable, Serialize}},
        state_vars::{Owned, PrivateSet, PublicImmutable},
    };
    use zkpassport_aztec_verifier::query::Query;
    use zkpassport_aztec_verifier::verify::{
        emit_uniqueness_nullifier, ServiceConfig, verify_zkpassport_proof_for_user,
    };

    // Proofs requested from example.com, the domain the fixture proof was made for
    global SERVICE: ServiceConfig = ServiceConfig::new("example.com");

    /// The badge, a private note owned by the address the proof was bound to.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    #[note]
    pub struct BadgeNote {}

    #[storage]
    struct Storage<Context> {
        one_claim_per_passport: PublicImmutable<bool, Context>,
        badges: Owned<PrivateSet<BadgeNote, Context>, Context>,
    }

    /// `one_claim_per_passport` makes each passport claim once; otherwise the same passport can
    /// claim again, as in testing.
    #[external("public")]
    #[initializer]
    fn constructor(one_claim_per_passport: bool) {
        self.storage.one_claim_per_passport.initialize(one_claim_per_passport);
    }

    /// Claim the badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {sanctions, bind(user)}) that its holder is not on the sanctions lists,
    /// burns the unique identifier if the gate allows one claim per passport, and mints `user` a
    /// private badge note.
    ///
    /// The sanctions root the proof was screened against rides in its own capsule.
    /// verify_zkpassport_proof checks it against the proof, and in the registry at the proof's
    /// date.
    #[external("private")]
    fn claim(user: AztecAddress) {
        let query = Query::new().sanctions();

        // The capsules ride in the sender's PXE, so they are scoped to the sender, who may be a
        // relayer, not `user`.
        let verified =
            verify_zkpassport_proof_for_user(self.context, self.msg_sender(), user, SERVICE, query);

        if self.storage.one_claim_per_passport.read() {
            emit_uniqueness_nullifier(self.context, verified.unique_identifier);
        }

        // Constrained, so a relayer can't withhold the note from `user`
        self.storage.badges.at(user).insert(BadgeNote {}).deliver(
            MessageDelivery::onchain_constrained(),
        );
    }

    /// Fails unless `user` holds the badge. For other contracts' private functions, which pass
    /// their own `msg_sender` as `user`. The PXE that runs the transaction needs `user`'s notes.
    #[external("private")]
    fn assert_has_badge(user: AztecAddress) {
        let badges = self.storage.badges.at(user).get_notes(NoteGetterOptions::new().set_limit(1));
        assert(badges.len() == 1, "no badge");
    }

    /// Whether `user` holds the badge, as their own wallet sees it.
    #[external("utility")]
    unconstrained fn has_badge(user: AztecAddress) -> bool {
        self.storage.badges.at(user).view_notes(NoteViewerOptions::new().set_limit(1)).len() == 1
    }
}

// TXE no-ops the recursion opcode, so these tests prove the wiring (capsules → sanctions
// commitment → registry views → nullifier), NOT proof validity. Proof validity is covered by
// zkpassport-packages' test-harness.
mod test {
    use crate::SanctionsGate;
    use aztec::{
        oracle::capsules,
        protocol::{address::AztecAddress, traits::{FromField, ToField}},
        test::helpers::test_environment::TestEnvironment,
    };
    use zkpassport::commitments::{age_commitment, bind_commitment, sanctions_commitment};
    use zkpassport::constants::{PI_PARAMS_START, PROOF_FIELDS, VK_FIELDS};
    use zkpassport::fixtures::proof::{
        AGE_FIXTURE_BIND_ADDRESS, AGE_FIXTURE_CERT_ROOT, AGE_FIXTURE_CIRCUIT_ROOT,
        AGE_FIXTURE_CIRCUIT_VERSION, AGE_FIXTURE_CURRENT_DATE, AGE_FIXTURE_VK_HASH,
    };
    use zkpassport::fixtures::txe::{age_fixture_blob_for_txe, TXE_CHAIN_ID};
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
        setup_gate(sanctions_roots, true)
    }

    unconstrained fn setup_gate<let N: u32>(
        sanctions_roots: [(Field, u64); N],
        one_claim_per_passport: bool,
    ) -> (TestEnvironment, AztecAddress) {
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

        let deployer = env.create_light_account();
        let gate = env.deploy("SanctionsGate").with_public_initializer(
            deployer,
            SanctionsGate::interface().constructor(one_claim_per_passport),
        );
        (env, gate)
    }

    // The age fixture is a real outer_count_5 proof with param commitments {age(18, 0), bind}.
    // Swapping its age commitment for a sanctions commitment gives a proof of {sanctions, bind}
    // with the fixture's roots, date and vk. Its bind moves to `user` too: the fixture's own
    // address has no keys in TXE, so nobody could read a badge minted to it.
    fn sanctions_blob(root: Field, user: AztecAddress) -> [Field; 585] {
        let fixture_bind = bind_commitment(AGE_FIXTURE_BIND_ADDRESS, TXE_CHAIN_ID);
        let mut blob = age_fixture_blob_for_txe();
        let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
        for i in params_start..params_start + 2 {
            if blob[i] == age_commitment(18, 0) {
                blob[i] = sanctions_commitment(root, false);
            } else if blob[i] == fixture_bind {
                blob[i] = bind_commitment(user.to_field(), TXE_CHAIN_ID);
            }
        }
        blob
    }

    // The capsules are scoped to the account that sends the claim, not to the bound address
    unconstrained fn deliver_capsules(
        env: &mut TestEnvironment,
        gate: AztecAddress,
        sender: AztecAddress,
        user: AztecAddress,
        proven_root: Field,
        sanctions_root: Option<Field>,
    ) {
        env.utility_context_at(gate, |_| {
            capsules::store(
                gate,
                PROOF_CAPSULE_SLOT,
                sanctions_blob(proven_root, user),
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
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );

        assert(!env.execute_utility(SanctionsGate::at(gate).has_badge(user)));
        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
        assert(env.execute_utility(SanctionsGate::at(gate).has_badge(user)));
    }

    // The registry checks the root at the proof's date, so a list replaced after the proof was
    // made still counts, although it was replaced more than a day before the claim
    #[test]
    unconstrained fn claim_succeeds_with_a_root_replaced_after_the_proof_was_made() {
        let (mut env, gate) = setup([
            (OLD_SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - 3 * DAY),
            (SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE),
        ]);
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
            OLD_SANCTIONS_ROOT,
            Option::some(OLD_SANCTIONS_ROOT),
        );

        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
        assert(env.execute_utility(SanctionsGate::at(gate).has_badge(user)));
    }

    #[test(should_fail_with = "invalid sanctions registry root")]
    unconstrained fn claim_with_a_root_the_registry_does_not_have_fails() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
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
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
            OLD_SANCTIONS_ROOT,
            Option::some(OLD_SANCTIONS_ROOT),
        );

        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
    }

    #[test(should_fail_with = "missing sanctions capsule")]
    unconstrained fn claim_without_sanctions_capsule_fails() {
        let (mut env, gate) = setup([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)]);
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
            SANCTIONS_ROOT,
            Option::none(),
        );

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
            AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS),
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
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );
        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));

        deliver_capsules(
            &mut env,
            gate,
            relayer,
            user,
            SANCTIONS_ROOT,
            Option::some(SANCTIONS_ROOT),
        );
        let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
    }

    // A gate deployed without one claim per passport lets the same passport claim again
    #[test]
    unconstrained fn a_passport_claims_again_when_the_gate_allows_it() {
        let (mut env, gate) = setup_gate([(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)], false);
        let user = env.create_light_account();
        let relayer = env.create_light_account();

        for _ in 0..2 {
            deliver_capsules(
                &mut env,
                gate,
                relayer,
                user,
                SANCTIONS_ROOT,
                Option::some(SANCTIONS_ROOT),
            );
            let _ = env.call_private(relayer, SanctionsGate::at(gate).claim(user));
        }

        assert(env.execute_utility(SanctionsGate::at(gate).has_badge(user)));
    }
}
