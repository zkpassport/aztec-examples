mod test;

use aztec::macros::aztec;

/// Private ZKPassport credentials. The deployer creates policies, each a requirement a proof must
/// meet; a user who meets one gets a private credential note for that policy, which other
/// contracts check with `assert_has_credential`.
#[aztec]
pub contract ZKPassportCredentials {
    use aztec::{
        macros::{functions::{external, initializer, internal}, notes::note, storage::storage},
        messages::delivery::MessageDelivery,
        note::{
            note_getter_options::NoteGetterOptions, note_interface::NoteProperties,
            note_viewer_options::NoteViewerOptions,
        },
        protocol::{
            address::AztecAddress,
            hash::poseidon2_hash,
            traits::{Deserialize, Packable, Serialize},
        },
        state_vars::{Map, Owned, PrivateSet, PublicImmutable},
        utils::comparison::Comparator,
    };
    use zkpassport_aztec_verifier::query::Query;
    use zkpassport_aztec_verifier::verify::{
        emit_uniqueness_nullifier, ServiceConfig, verify_zkpassport_proof_for_user,
    };

    /// A requirement that a proof of age shows the holder is at least `min_age`
    pub global AGE_MIN: u8 = 1;
    /// A requirement that a proof discloses `nationality`
    pub global NATIONALITY: u8 = 2;
    /// A requirement that a proof shows the holder is not on the sanctions lists
    pub global SANCTIONS: u8 = 3;

    /// What a ZKPassport proof must show to earn a policy's credential. `kind` is AGE_MIN,
    /// NATIONALITY or SANCTIONS; `min_age` counts for AGE_MIN and `nationality`, as the MRZ writes it
    /// ("FRA"), for NATIONALITY.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    pub struct Requirement {
        pub kind: u8,
        pub min_age: u8,
        pub nationality: [u8; 3],
    }

    impl Requirement {
        pub fn age_min(min_age: u8) -> Self {
            Requirement { kind: AGE_MIN, min_age, nationality: [0; 3] }
        }

        pub fn nationality(nationality: str<3>) -> Self {
            Requirement { kind: NATIONALITY, min_age: 0, nationality: nationality.as_bytes() }
        }

        pub fn sanctions() -> Self {
            Requirement { kind: SANCTIONS, min_age: 0, nationality: [0; 3] }
        }
    }

    /// A policy: the requirement its credential stands for, and whether each passport earns the
    /// credential once or can claim it again, as in testing.
    #[derive(Eq, Packable)]
    pub struct Policy {
        requirement: Requirement,
        one_claim_per_passport: bool,
    }

    /// Set when the contract is deployed: who creates policies, the `scope_hash` of the domain the
    /// app's ZKPassport requests come from, and whether ZKPassport's mock passports are accepted.
    #[derive(Eq, Packable)]
    pub struct Config {
        admin: AztecAddress,
        domain: Field,
        dev_mode: bool,
    }

    /// A credential of policy `policy_id`, a private note owned by the address the proof was
    /// bound to.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    #[note]
    pub struct CredentialNote {
        policy_id: Field,
    }

    #[storage]
    struct Storage<Context> {
        config: PublicImmutable<Config, Context>,
        policies: Map<Field, PublicImmutable<Policy, Context>, Context>,
        credentials: Owned<PrivateSet<CredentialNote, Context>, Context>,
    }

    /// `domain` is the `scope_hash` of the domain the app's ZKPassport requests come from, and
    /// `dev_mode` also accepts ZKPassport's mock passports. The deployer creates the policies.
    #[external("public")]
    #[initializer]
    fn constructor(domain: Field, dev_mode: bool) {
        self.storage.config.initialize(Config { admin: self.msg_sender(), domain, dev_mode });
    }

    /// Creates policy `policy_id`. Only the deployer can, and a policy never changes.
    #[external("public")]
    fn create_policy(policy_id: Field, requirement: Requirement, one_claim_per_passport: bool) {
        assert(
            self.msg_sender() == self.storage.config.read().admin,
            "only the deployer creates policies",
        );
        let kind = requirement.kind;
        assert(
            (kind == AGE_MIN) | (kind == NATIONALITY) | (kind == SANCTIONS),
            "unknown requirement",
        );

        self.storage.policies.at(policy_id).initialize(
            Policy { requirement, one_claim_per_passport },
        );
    }

    /// Claims an AGE_MIN policy's credential for `user` with a proof of age (outer_count_5, param
    /// commitments = {age(min_age, 0), bind(user)}).
    ///
    /// The bind commitment, not the sender, authorizes the claim, so any relayer may send it, and
    /// nothing in the transaction names `user`. The proof's capsule is scoped to the sender.
    #[external("private")]
    fn claim_age(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.kind == AGE_MIN, "not an age policy");

        let query = Query::new().age_min(policy.requirement.min_age);
        let verified = verify_zkpassport_proof_for_user(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            query,
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// Claims a NATIONALITY policy's credential for `user` with a proof that discloses the
    /// nationality (outer_count_5, param commitments = {disclose, bind(user)}). The proof must
    /// disclose the document type as well: passports and ID cards keep the nationality at
    /// different MRZ offsets. The disclosed bytes ride in their own capsule.
    #[external("private")]
    fn claim_nationality(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.kind == NATIONALITY, "not a nationality policy");

        let query = Query::new().disclose_nationality();
        let verified = verify_zkpassport_proof_for_user(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            query,
        );
        assert(
            verified.nationality() == policy.requirement.nationality,
            "nationality not accepted",
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// Claims a SANCTIONS policy's credential for `user` with a proof that its holder is not on
    /// the sanctions lists (outer_count_5, param commitments = {sanctions, bind(user)}). The
    /// sanctions root the proof was screened against rides in its own capsule, and the registry
    /// checks it at the proof's date.
    #[external("private")]
    fn claim_sanctions(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.kind == SANCTIONS, "not a sanctions policy");

        let query = Query::new().sanctions();
        let verified = verify_zkpassport_proof_for_user(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            query,
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// Fails unless `user` holds a credential of `policy_id`. For other contracts' private
    /// functions, which pass their own `msg_sender` as `user`. The PXE that runs the transaction
    /// needs `user`'s notes.
    #[external("private")]
    fn assert_has_credential(user: AztecAddress, policy_id: Field) {
        let options = NoteGetterOptions::new()
            .select(CredentialNote::properties().policy_id, Comparator.EQ, policy_id)
            .set_limit(1);
        assert(self.storage.credentials.at(user).get_notes(options).len() == 1, "no credential");
    }

    /// Whether `user` holds a credential of `policy_id`, as their own wallet sees it.
    #[external("utility")]
    unconstrained fn has_credential(user: AztecAddress, policy_id: Field) -> bool {
        let options = NoteViewerOptions::new()
            .select(CredentialNote::properties().policy_id, Comparator.EQ, policy_id)
            .set_limit(1);
        self.storage.credentials.at(user).view_notes(options).len() == 1
    }

    #[internal("private")]
    fn service() -> ServiceConfig {
        let config = self.storage.config.read();
        let mut service = ServiceConfig::from_domain_hash(config.domain);
        service.dev_mode = config.dev_mode;
        service
    }

    // A one-claim policy burns a nullifier of the passport and the policy, so claiming one
    // policy leaves the passport free to claim the others
    #[internal("private")]
    fn issue(
        user: AztecAddress,
        policy_id: Field,
        one_claim_per_passport: bool,
        unique_identifier: Field,
    ) {
        if one_claim_per_passport {
            // A proof with a hidden identifier has 0 here, and every such proof would share one
            // nullifier, so the first would block all later claims
            assert(unique_identifier != 0, "no unique identifier in this proof");
            emit_uniqueness_nullifier(self.context, poseidon2_hash([unique_identifier, policy_id]));
        }

        // Constrained, so a relayer can't withhold the note from `user`
        self.storage.credentials.at(user).insert(CredentialNote { policy_id }).deliver(
            MessageDelivery::onchain_constrained(),
        );
    }
}
