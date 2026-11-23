mod test;

use aztec::macros::aztec;

#[aztec]
pub contract AgeGate {
    use aztec::{
        macros::{functions::{external, only_self, view}, storage::storage},
        protocol::address::AztecAddress,
        state_vars::{Map, PublicMutable},
    };
    use zkpassport_aztec_verifier::query::Query;
    use zkpassport_aztec_verifier::verify::{
        emit_uniqueness_nullifier, ServiceConfig, verify_zkpassport_proof_for_user,
    };

    global MIN_AGE: u8 = 18;

    // Proofs requested from example.com, the domain the fixture proof was made for
    global SERVICE: ServiceConfig = ServiceConfig::new("example.com");

    #[storage]
    struct Storage<Context> {
        // The 18+ badge: a public, soulbound flag per address. The passport proof that earns
        // it stays private; what becomes public is only that `user` holds the badge.
        badges: Map<AztecAddress, PublicMutable<bool, Context>, Context>,
    }

    /// Claim the 18+ badge for `user`: verifies a ZKPassport proof (outer_count_5, param
    /// commitments = {age(18, 0), bind(user)}), burns the unique identifier — one claim
    /// per passport — and grants `user` the public badge.
    ///
    /// The bind commitment ties the proof itself to `user` (the passport holder asked
    /// ZKPassport to bind that address when the proof was made).
    #[external("private")]
    fn claim(user: AztecAddress) {
        let query = Query::new().age_min(MIN_AGE);

        // The capsule rides in the sender's PXE, so it is scoped to the sender — who may be a
        // relayer, not `user`.
        let verified =
            verify_zkpassport_proof_for_user(self.context, self.msg_sender(), user, SERVICE, query);

        // Make sure this can only be done once per passport
        emit_uniqueness_nullifier(self.context, verified.unique_identifier);

        // Deliberately public: the enqueued call reveals `user` in the transaction's public
        // phase. The badge is meant to be readable by anyone (other contracts included);
        // only the passport proof behind it is private.
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
