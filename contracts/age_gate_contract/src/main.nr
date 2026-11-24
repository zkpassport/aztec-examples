mod test;

use aztec::macros::aztec;

#[aztec]
pub contract AgeGate {
    use aztec::{
        macros::{functions::external, notes::note, storage::storage},
        messages::delivery::MessageDelivery,
        note::{note_getter_options::NoteGetterOptions, note_viewer_options::NoteViewerOptions},
        protocol::{address::AztecAddress, traits::{Deserialize, Packable, Serialize}},
        state_vars::{Owned, PrivateSet},
    };
    use zkpassport_aztec_verifier::query::Query;
    use zkpassport_aztec_verifier::verify::{
        emit_uniqueness_nullifier, ServiceConfig, verify_zkpassport_proof_for_user,
    };

    global MIN_AGE: u8 = 18;

    // Proofs requested from example.com, the domain the fixture proof was made for
    global SERVICE: ServiceConfig = ServiceConfig::new("example.com");

    /// The 18+ badge, a private note owned by the address the proof was bound to.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    #[note]
    pub struct BadgeNote {}

    #[storage]
    struct Storage<Context> {
        badges: Owned<PrivateSet<BadgeNote, Context>, Context>,
    }

    /// Claim the 18+ badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {age(18, 0), bind(user)}), burns the unique identifier (one claim per
    /// passport) and mints `user` a private badge note.
    ///
    /// The bind commitment, not the sender, authorizes the claim, so any relayer may send it.
    /// Nothing in the transaction names `user`.
    #[external("private")]
    fn claim(user: AztecAddress) {
        let query = Query::new().age_min(MIN_AGE);

        // The capsule rides in the sender's PXE, so it is scoped to the sender, who may be a
        // relayer, not `user`.
        let verified =
            verify_zkpassport_proof_for_user(self.context, self.msg_sender(), user, SERVICE, query);

        // Make sure this can only be done once per passport
        emit_uniqueness_nullifier(self.context, verified.unique_identifier);

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
