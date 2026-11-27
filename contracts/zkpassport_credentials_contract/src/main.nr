mod bound;
mod test;

use aztec::macros::aztec;

/// Private ZKPassport credentials. The deployer creates policies, each a requirement a proof must
/// meet and, optionally, custom data it must be bound to; a user who meets one gets a private
/// credential note for that policy, which other contracts check with `assert_has_credential`.
#[aztec]
pub contract ZKPassportCredentials {
    use crate::bound::{
        pack_custom_data, unpack_custom_data, verify_bound, verify_bound_camera_read,
    };
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
    use zkpassport_aztec_verifier::verify::{emit_uniqueness_nullifier, ServiceConfig};

    /// The length of a policy's custom data: a SHA-256 digest in lowercase hex, such as the digest
    /// of the terms a user accepts
    pub global CUSTOM_DATA_LENGTH: u32 = 64;

    /// What a ZKPassport proof must show to earn a policy's credential, one field per check of the
    /// query that verifies it: an age of at least `min_age` (0 for none), not being on the
    /// sanctions lists, and the disclosed `nationality` as the MRZ writes it ("FRA", zeros for
    /// none). Each claim function verifies one combination of checks.
    #[derive(Deserialize, Eq, Packable, Serialize)]
    pub struct Requirement {
        pub min_age: u8,
        pub sanctions: bool,
        pub nationality: [u8; 3],
    }

    impl Requirement {
        pub fn age_min(min_age: u8) -> Self {
            Requirement { min_age, sanctions: false, nationality: [0; 3] }
        }

        pub fn sanctions() -> Self {
            Requirement { min_age: 0, sanctions: true, nationality: [0; 3] }
        }

        pub fn age_min_and_sanctions(min_age: u8) -> Self {
            Requirement { min_age, sanctions: true, nationality: [0; 3] }
        }

        pub fn nationality(nationality: str<3>) -> Self {
            Requirement { min_age: 0, sanctions: false, nationality: nationality.as_bytes() }
        }

        /// Whether this requirement asks for exactly these checks
        fn asks_for(self, age: bool, sanctions: bool, nationality: bool) -> bool {
            ((self.min_age != 0) == age)
                & (self.sanctions == sanctions)
                & ((self.nationality != [0; 3]) == nationality)
        }

        // Whether a claim function verifies this requirement
        fn is_claimable(self) -> bool {
            self.asks_for(true, false, false)
                | self.asks_for(false, true, false)
                | self.asks_for(true, true, false)
                | self.asks_for(false, false, true)
        }
    }

    /// A policy: the requirement its credential stands for, whether each passport earns the
    /// credential once or can claim it again, as in testing, whether an ID read by the camera of
    /// ZKPassport's app earns it as well as one read from its chip, and the custom data a proof must
    /// be bound to, all zeros for none.
    ///
    /// A camera read and a chip read of the same ID have different unique identifiers, so with
    /// `one_claim_per_passport` an ID can earn the credential once by each read. An Aadhaar, which
    /// every policy accepts as an ID its issuer signed, has its own too.
    #[derive(Eq, Packable)]
    pub struct Policy {
        requirement: Requirement,
        one_claim_per_passport: bool,
        accepts_camera_read: bool,
        // Packed with `pack_custom_data`
        custom_data: [Field; 3],
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

    /// Creates policy `policy_id`. Only the deployer can, and a policy never changes. A claim's
    /// proof must be bound to `custom_data` as well as to the user, unless it is all zeros; the
    /// ZKPassport request binds it as `custom_data`, byte for byte.
    #[external("public")]
    fn create_policy(
        policy_id: Field,
        requirement: Requirement,
        one_claim_per_passport: bool,
        accepts_camera_read: bool,
        custom_data: [u8; CUSTOM_DATA_LENGTH],
    ) {
        assert(
            self.msg_sender() == self.storage.config.read().admin,
            "only the deployer creates policies",
        );
        assert(requirement.is_claimable(), "no claim function for this requirement");

        self.storage.policies.at(policy_id).initialize(
            Policy {
                requirement,
                one_claim_per_passport,
                accepts_camera_read,
                custom_data: pack_custom_data(custom_data),
            },
        );
    }

    /// Claims the credential of a policy that asks for a minimum age for `user` with a proof of age
    /// (outer_count_5, param commitments = {age(min_age, 0), bind(user, and the policy's custom
    /// data if it has some)}).
    ///
    /// The bind commitment, not the sender, authorizes the claim, so any relayer may send it, and
    /// nothing in the transaction names `user`. The proof's capsule is scoped to the sender.
    #[external("private")]
    fn claim_age(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.asks_for(true, false, false), "policy asks for another proof");

        let query = Query::new().age_min(policy.requirement.min_age);
        let verified = verify_bound(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            unpack_custom_data(policy.custom_data),
            query,
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// Claims the credential of a policy that asks for a nationality for `user` with a proof that
    /// discloses the nationality (outer_count_5, param commitments = {disclose, bind(user)}). The proof must
    /// disclose the document type as well: passports and ID cards keep the nationality at
    /// different MRZ offsets. The disclosed bytes ride in their own capsule.
    #[external("private")]
    fn claim_nationality(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.asks_for(false, false, true), "policy asks for another proof");

        let query = Query::new().disclose_nationality();
        let verified = verify_bound(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            unpack_custom_data(policy.custom_data),
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

    /// Claims the credential of a policy that asks for sanctions screening for `user` with a proof
    /// that its holder is not on the sanctions lists (outer_count_5, param commitments =
    /// {sanctions, bind(user)}). The
    /// sanctions root the proof was screened against rides in its own capsule, and the registry
    /// checks it at the proof's date.
    #[external("private")]
    fn claim_sanctions(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.asks_for(false, true, false), "policy asks for another proof");

        let query = Query::new().sanctions();
        let verified = verify_bound(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            unpack_custom_data(policy.custom_data),
            query,
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// Claims the credential of a policy that asks for a minimum age and sanctions screening for
    /// `user` with one proof of both (outer_count_6, param commitments = {age(min_age, 0),
    /// sanctions, bind(user)}). The sanctions root rides in its own capsule, as for
    /// `claim_sanctions`.
    #[external("private")]
    fn claim_age_and_sanctions(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.asks_for(true, true, false), "policy asks for another proof");

        let query = Query::new().age_min(policy.requirement.min_age).sanctions();
        let verified = verify_bound(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            unpack_custom_data(policy.custom_data),
            query,
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// As `claim_age_and_sanctions`, with a proof that also carries a strict face match (param
    /// commitments = {age(min_age, 0), sanctions, face match, bind(user)}). An Aadhaar proves this
    /// way, as ZKPassport's app adds a strict face match to each of its proofs, and so can a chip
    /// read whose request asked for one. The face match rides in its own capsule.
    #[external("private")]
    fn claim_age_and_sanctions_with_face_match(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.asks_for(true, true, false), "policy asks for another proof");

        let query =
            Query::new().age_min(policy.requirement.min_age).sanctions().strict_face_match();
        let verified = verify_bound(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            unpack_custom_data(policy.custom_data),
            query,
        );

        self.internal.issue(
            user,
            policy_id,
            policy.one_claim_per_passport,
            verified.unique_identifier,
        );
    }

    /// As `claim_age_and_sanctions`, with the proof of an ID read by the camera of ZKPassport's app
    /// and attested by the device (outer_attested_id_count_7, param commitments = {attested ID,
    /// age(min_age, 0), bind(user), sanctions}), for a policy that accepts camera reads. The
    /// device's attestation rides in its own capsule.
    #[external("private")]
    fn claim_age_and_sanctions_from_camera_read(user: AztecAddress, policy_id: Field) {
        let policy = self.storage.policies.at(policy_id).read();
        assert(policy.requirement.asks_for(true, true, false), "policy asks for another proof");
        assert(policy.accepts_camera_read, "policy doesn't accept camera reads");

        let query = Query::new().age_min(policy.requirement.min_age).sanctions();
        let verified = verify_bound_camera_read(
            self.context,
            self.msg_sender(),
            user,
            self.internal.service(),
            unpack_custom_data(policy.custom_data),
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
