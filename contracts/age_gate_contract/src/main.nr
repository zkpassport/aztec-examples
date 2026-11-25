mod test;

use aztec::macros::aztec;

#[aztec]
pub contract AgeGate {
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

    global MIN_AGE: u8 = 18;

    // The service this gate accepts proofs for, set when it is deployed.
    #[derive(Eq, Packable)]
    pub struct GateConfig {
        // scope_hash of the domain the app's ZKPassport requests come from
        domain: Field,
        // Also accepts proofs from ZKPassport's mock passports
        dev_mode: bool,
        // Each passport claims once; otherwise the same passport can claim again, as in testing
        one_claim_per_passport: bool,
    }

    /// The 18+ badge, a private note owned by the address the proof was bound to.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    #[note]
    pub struct BadgeNote {}

    #[storage]
    struct Storage<Context> {
        config: PublicImmutable<GateConfig, Context>,
        badges: Owned<PrivateSet<BadgeNote, Context>, Context>,
    }

    /// `domain` is the `scope_hash` of the domain the app's ZKPassport requests come from.
    /// `one_claim_per_passport` makes each passport claim once.
    #[external("public")]
    #[initializer]
    fn constructor(domain: Field, dev_mode: bool, one_claim_per_passport: bool) {
        self.storage.config.initialize(GateConfig { domain, dev_mode, one_claim_per_passport });
    }

    /// Claim the 18+ badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {age(18, 0), bind(user)}), burns the unique identifier if the gate allows
    /// one claim per passport, and mints `user` a private badge note.
    ///
    /// The bind commitment, not the sender, authorizes the claim, so any relayer may send it.
    /// Nothing in the transaction names `user`.
    #[external("private")]
    fn claim(user: AztecAddress) {
        let gate = self.storage.config.read();
        let mut config = ServiceConfig::from_domain_hash(gate.domain);
        config.dev_mode = gate.dev_mode;

        let query = Query::new().age_min(MIN_AGE);

        // The capsule rides in the sender's PXE, so it is scoped to the sender, who may be a
        // relayer, not `user`.
        let verified =
            verify_zkpassport_proof_for_user(self.context, self.msg_sender(), user, config, query);

        if gate.one_claim_per_passport {
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
