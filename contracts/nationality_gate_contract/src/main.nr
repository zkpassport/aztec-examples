mod test;

use aztec::macros::aztec;

#[aztec]
pub contract NationalityGate {
    use aztec::{
        macros::{functions::{external, only_self, view}, storage::storage},
        protocol::address::AztecAddress,
        state_vars::{Map, PublicMutable},
    };
    use zkpassport_aztec_verifier::query::Query;
    use zkpassport_aztec_verifier::verify::{
        emit_uniqueness_nullifier, ServiceConfig, verify_zkpassport_proof,
    };

    // The nationality the badge is for, as the MRZ writes it
    global NATIONALITY: str<3> = "FRA";

    // Proofs requested from example.com, the domain the fixture proof was made for
    global SERVICE: ServiceConfig = ServiceConfig::new("example.com");

    #[storage]
    struct Storage<Context> {
        badges: Map<AztecAddress, PublicMutable<bool, Context>, Context>,
    }

    /// Claim the badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {disclose, bind(user)}) whose disclosed nationality is NATIONALITY, burns
    /// the unique identifier (one claim per passport) and grants `user` the public badge.
    ///
    /// The disclose payload rides in its own capsule, which verify_zkpassport_proof loads and
    /// checks against the proof. The proof must disclose the document type as well as the
    /// nationality: passports and ID cards keep the nationality at different MRZ offsets.
    #[external("private")]
    fn claim(user: AztecAddress) {
        let query = Query::new().disclose_nationality().bind_user_address(user);

        // The capsules ride in the sender's PXE, so they are scoped to the sender, who may be a
        // relayer, not `user`.
        let verified = verify_zkpassport_proof(self.context, self.msg_sender(), SERVICE, query);

        assert(verified.nationality() == NATIONALITY.as_bytes(), "nationality not accepted");

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
