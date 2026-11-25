mod test;

use aztec::macros::aztec;

#[aztec]
pub contract NationalityGate {
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

    // The nationality the badge is for, as the MRZ writes it
    global NATIONALITY: str<3> = "FRA";

    // Proofs requested from example.com, the domain the fixture proof was made for
    global SERVICE: ServiceConfig = ServiceConfig::new("example.com");

    /// The badge, a private note owned by the address the proof was bound to.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    #[note]
    pub struct BadgeNote {}

    #[storage]
    struct Storage<Context> {
        badges: Owned<PrivateSet<BadgeNote, Context>, Context>,
    }

    /// Claim the badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {disclose, bind(user)}) whose disclosed nationality is NATIONALITY, burns
    /// the unique identifier (one claim per passport) and mints `user` a private badge note.
    ///
    /// The disclose payload rides in its own capsule, which verify_zkpassport_proof loads and
    /// checks against the proof. The proof must disclose the document type as well as the
    /// nationality: passports and ID cards keep the nationality at different MRZ offsets.
    #[external("private")]
    fn claim(user: AztecAddress) {
        let query = Query::new().disclose_nationality();

        // The capsules ride in the sender's PXE, so they are scoped to the sender, who may be a
        // relayer, not `user`.
        let verified =
            verify_zkpassport_proof_for_user(self.context, self.msg_sender(), user, SERVICE, query);

        assert(verified.nationality() == NATIONALITY.as_bytes(), "nationality not accepted");

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
