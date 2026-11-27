use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::{CUSTOM_DATA_LENGTH, Requirement};
use aztec::{
    oracle::capsules,
    protocol::{address::AztecAddress, traits::{FromField, ToField}},
    test::helpers::test_environment::TestEnvironment,
};
use zkpassport::app_attest::{APPLE_ROOT_KEY_HASH, IOS_APP_ID_HASH};
use zkpassport::commitments::{age_commitment, bind_commitment};
use zkpassport::constants::{
    APP_ATTEST_ENV_PRODUCTION, ATTESTED_ID_CAPSULE_SLOT, FACE_MATCH_MODE_STRICT, PI_PARAMS_START,
    PROOF_FIELDS, VERIFICATION_METHOD_ATTESTED_CAPTURE_IOS, VK_FIELDS,
};
use zkpassport::face_match::FaceMatch;
use zkpassport::fixtures::proof::{
    AGE_FIXTURE_BIND_ADDRESS, AGE_FIXTURE_CERT_ROOT, AGE_FIXTURE_CIRCUIT_ROOT,
    AGE_FIXTURE_CIRCUIT_VERSION, AGE_FIXTURE_CURRENT_DATE, AGE_FIXTURE_VK_HASH,
};
use zkpassport::fixtures::txe::{age_fixture_blob_for_txe, TXE_CHAIN_ID};
use zkpassport_aztec_verifier::constants::{
    DISCLOSE_CAPSULE_SLOT, PROOF_CAPSULE_SLOT, SANCTIONS_CAPSULE_SLOT,
};
use zkpassport_aztec_verifier::verify::scope_hash;
use zkpassport_registry_contract::{
    local_network_registry::{
        deploy_local_network_registry, LOCAL_NETWORK_REGISTRY_ADDRESS,
        LOCAL_NETWORK_REGISTRY_OPERATOR, seed_local_network_registry,
    },
    types::REGISTRY_SANCTIONS,
    ZKPassportRegistry,
};

pub global DAY: u64 = 86400;

// The domain the age fixture proof was made for
pub global FIXTURE_DOMAIN: Field = scope_hash("example.com");

pub global POLICY: Field = 1;
pub global OTHER_POLICY: Field = 2;

pub global NO_CUSTOM_DATA: [u8; CUSTOM_DATA_LENGTH] = [0; CUSTOM_DATA_LENGTH];

pub struct Deployment {
    pub env: TestEnvironment,
    pub credentials: AztecAddress,
    pub deployer: AztecAddress,
}

impl Deployment {
    /// Creates policy `policy_id`, without custom data, as the deployer
    pub unconstrained fn create_policy(
        &mut self,
        policy_id: Field,
        requirement: Requirement,
        one_claim_per_passport: bool,
    ) {
        self.create_policy_with(
            policy_id,
            requirement,
            one_claim_per_passport,
            false,
            NO_CUSTOM_DATA,
        );
    }

    /// Creates policy `policy_id`, whose proofs must be bound to `custom_data`, as the deployer
    pub unconstrained fn create_policy_bound_to(
        &mut self,
        policy_id: Field,
        requirement: Requirement,
        one_claim_per_passport: bool,
        custom_data: [u8; CUSTOM_DATA_LENGTH],
    ) {
        self.create_policy_with(policy_id, requirement, one_claim_per_passport, false, custom_data);
    }

    /// Creates policy `policy_id`, without custom data, that also accepts IDs read by the camera
    pub unconstrained fn create_policy_accepting_camera_reads(
        &mut self,
        policy_id: Field,
        requirement: Requirement,
        one_claim_per_passport: bool,
    ) {
        self.create_policy_with(
            policy_id,
            requirement,
            one_claim_per_passport,
            true,
            NO_CUSTOM_DATA,
        );
    }

    pub unconstrained fn create_policy_with(
        &mut self,
        policy_id: Field,
        requirement: Requirement,
        one_claim_per_passport: bool,
        accepts_camera_read: bool,
        custom_data: [u8; CUSTOM_DATA_LENGTH],
    ) {
        let _ = self.env.call_public(
            self.deployer,
            ZKPassportCredentials::at(self.credentials).create_policy(
                policy_id,
                requirement,
                one_claim_per_passport,
                accepts_camera_read,
                custom_data,
            ),
        );
    }

    /// Stores the claim's capsules for `sender`, the account that sends the claim: the capsules
    /// ride in the sender's PXE, whoever the proof is bound to.
    pub unconstrained fn deliver<let N: u32>(
        &mut self,
        sender: AztecAddress,
        blob: [Field; N],
        disclose_payload: Option<[Field; 180]>,
        sanctions_root: Option<Field>,
    ) {
        let credentials = self.credentials;
        self.env.utility_context_at(credentials, |_| {
            capsules::store(credentials, PROOF_CAPSULE_SLOT, blob, sender);
            if disclose_payload.is_some() {
                capsules::store(
                    credentials,
                    DISCLOSE_CAPSULE_SLOT,
                    disclose_payload.unwrap(),
                    sender,
                );
            }
            if sanctions_root.is_some() {
                capsules::store(
                    credentials,
                    SANCTIONS_CAPSULE_SLOT,
                    sanctions_root.unwrap(),
                    sender,
                );
            }
        });
    }

    /// Stores the attested ID capsule of a camera-read ID's proof for `sender`
    pub unconstrained fn deliver_attestation(
        &mut self,
        sender: AztecAddress,
        attestation: FaceMatch,
    ) {
        let credentials = self.credentials;
        let payload = [
            attestation.root_key_leaf,
            attestation.environment as Field,
            attestation.app_id_hash,
            attestation.integrity_public_key_hash,
            attestation.mode as Field,
            attestation.revocation_root,
        ];
        self.env.utility_context_at(credentials, |_| {
            capsules::store(credentials, ATTESTED_ID_CAPSULE_SLOT, payload, sender);
        });
    }

    pub unconstrained fn has_credential(&mut self, user: AztecAddress, policy_id: Field) -> bool {
        self.env.execute_utility(ZKPassportCredentials::at(self.credentials).has_credential(
            user,
            policy_id,
        ))
    }
}

/// The local network registry seeded with the age fixture's roots and vk, and a
/// ZKPassportCredentials contract for the fixture's domain, without dev mode and without policies
pub unconstrained fn setup() -> Deployment {
    setup_with(FIXTURE_DOMAIN, false, [])
}

/// As `setup`, with `domain`, `dev_mode`, and `sanctions_roots` published to the registry as
/// (root, valid from) in publishing order. Time ends a day and a second after the proof's date:
/// past the registry's 24h delay, which counts from TXE's start, and inside the proof's 7-day
/// validity period.
pub unconstrained fn setup_with<let N: u32>(
    domain: Field,
    dev_mode: bool,
    sanctions_roots: [(Field, u64); N],
) -> Deployment {
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
    let credentials = env.deploy("ZKPassportCredentials").with_public_initializer(
        deployer,
        ZKPassportCredentials::interface().constructor(domain, dev_mode),
    );
    Deployment { env, credentials, deployer }
}

/// The age fixture's address, which has no keys in TXE: a credential minted to it can't be read
pub fn fixture_address() -> AztecAddress {
    AztecAddress::from_field(AGE_FIXTURE_BIND_ADDRESS)
}

/// The age fixture, a real outer_count_5 proof with param commitments {age(18, 0), bind}
pub fn age_blob() -> [Field; 585] {
    age_fixture_blob_for_txe()
}

/// `blob` with its bind commitment moved to `user`, so `user`, a TXE account, can read the
/// credential. TXE doesn't verify the recursion, so only the commitment needs swapping.
pub fn bound_to(user: AztecAddress, blob: [Field; 585]) -> [Field; 585] {
    swap_commitment(
        blob,
        bind_commitment(
            Option::some(AGE_FIXTURE_BIND_ADDRESS),
            TXE_CHAIN_ID,
            Option::none(),
        ),
        bind_commitment(Option::some(user.to_field()), TXE_CHAIN_ID, Option::none()),
    )
}

/// `blob` with its bind commitment moved to `user` and `custom_data`
pub fn bound_to_with<let N: u32>(
    user: AztecAddress,
    custom_data: [u8; N],
    blob: [Field; 585],
) -> [Field; 585] {
    swap_commitment(
        blob,
        bind_commitment(
            Option::some(AGE_FIXTURE_BIND_ADDRESS),
            TXE_CHAIN_ID,
            Option::none(),
        ),
        bind_commitment(
            Option::some(user.to_field()),
            TXE_CHAIN_ID,
            Option::some(BoundedVec::from_array(custom_data)),
        ),
    )
}

/// The age fixture with its age commitment swapped for `commitment`: a proof of
/// {commitment, bind} with the fixture's roots, date, vk and bound address. Its proof bytes no
/// longer match its public inputs, which TXE can't notice.
pub fn blob_with(commitment: Field) -> [Field; 585] {
    swap_commitment(age_blob(), age_commitment(18, 0), commitment)
}

/// `blob`, a proof of 5 subproofs, as a proof of 6 that also commits to `commitment`: the extra
/// public input follows the two param commitments. TXE doesn't verify the recursion, so the
/// public inputs are all that change.
pub fn with_commitment_added(blob: [Field; 585], commitment: Field) -> [Field; 586] {
    let params_end = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START + 2;
    let mut extended = [0; 586];
    for i in 0..params_end {
        extended[i] = blob[i];
    }
    extended[params_end] = commitment;
    for i in params_end..585 {
        extended[i + 1] = blob[i];
    }
    extended
}

fn swap_commitment(mut blob: [Field; 585], from: Field, to: Field) -> [Field; 585] {
    let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
    let mut swapped = 0;
    for i in params_start..params_start + 2 {
        if blob[i] == from {
            blob[i] = to;
            swapped += 1;
        }
    }
    assert(swapped == 1);
    blob
}

/// The attestation of an ID read by the camera of ZKPassport's iOS app, as its proof commits it
pub fn ios_attestation() -> FaceMatch {
    FaceMatch {
        root_key_leaf: APPLE_ROOT_KEY_HASH,
        environment: APP_ATTEST_ENV_PRODUCTION,
        app_id_hash: IOS_APP_ID_HASH,
        integrity_public_key_hash: 0,
        mode: FACE_MATCH_MODE_STRICT,
        revocation_root: 0,
    }
}

/// `blob`, a proof of 6 subproofs, as the same proof of an ID read by the iOS app's camera: the
/// attestation's commitment comes first among the param commitments, and the verification method
/// is the iOS camera's. TXE doesn't verify the recursion, so the public inputs are all that change.
pub fn read_by_camera(blob: [Field; 586], attestation: FaceMatch) -> [Field; 587] {
    let params_start = VK_FIELDS + PROOF_FIELDS + PI_PARAMS_START;
    let mut attested = [0; 587];
    for i in 0..params_start {
        attested[i] = blob[i];
    }
    attested[params_start] = attestation.attested_id_commitment();
    for i in params_start..586 {
        attested[i + 1] = blob[i];
    }
    // The last public input, before the blob's final field
    attested[585] = VERIFICATION_METHOD_ATTESTED_CAPTURE_IOS;
    attested
}
