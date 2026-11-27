use crate::test::fixtures::{
    age_blob, bound_to, DAY, Deployment, FIXTURE_DOMAIN, ios_attestation, of_an_aadhaar, POLICY,
    setup_with, with_commitment_added, with_face_match,
};
use crate::ZKPassportCredentials;
use crate::ZKPassportCredentials::Requirement;
use aztec::protocol::address::AztecAddress;
use zkpassport::commitments::sanctions_commitment;
use zkpassport::constants::FACE_MATCH_MODE_REGULAR;
use zkpassport::face_match::FaceMatch;
use zkpassport::fixtures::proof::AGE_FIXTURE_CURRENT_DATE;

global SANCTIONS_ROOT: Field = 0x5a5a;

// A deployment with the registry holding SANCTIONS_ROOT since a day before the proof, and a policy
// that asks for 18 or older and sanctions screening, as Fortuna's traders' does
unconstrained fn setup() -> Deployment {
    let mut deployment = setup_with(
        FIXTURE_DOMAIN,
        false,
        [(SANCTIONS_ROOT, AGE_FIXTURE_CURRENT_DATE - DAY)],
    );
    deployment.create_policy(POLICY, Requirement::age_min_and_sanctions(18), true);
    deployment
}

// A chip read's proof of {age(18, 0), bind(user), sanctions(SANCTIONS_ROOT)}
fn chip_proof_for(user: AztecAddress) -> [Field; 586] {
    with_commitment_added(
        bound_to(user, age_blob()),
        sanctions_commitment(SANCTIONS_ROOT, true),
    )
}

unconstrained fn claim_with_face_match(
    deployment: &mut Deployment,
    user: AztecAddress,
    blob: [Field; 587],
    face_match: Option<FaceMatch>,
) {
    deployment.deliver(user, blob, Option::none(), Option::some(SANCTIONS_ROOT));
    if face_match.is_some() {
        deployment.deliver_face_match(user, face_match.unwrap());
    }
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions_with_face_match(
            user,
            POLICY,
        ),
    );
}

#[test]
unconstrained fn an_aadhaar_earns_the_credential() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();
    let face_match = ios_attestation();

    claim_with_face_match(
        &mut deployment,
        user,
        of_an_aadhaar(with_face_match(chip_proof_for(user), face_match)),
        Option::some(face_match),
    );

    assert(deployment.has_credential(user, POLICY));
}

#[test]
unconstrained fn a_chip_read_with_a_strict_face_match_earns_it_too() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();
    let face_match = ios_attestation();

    claim_with_face_match(
        &mut deployment,
        user,
        with_face_match(chip_proof_for(user), face_match),
        Option::some(face_match),
    );

    assert(deployment.has_credential(user, POLICY));
}

#[test(should_fail_with = "face match mode not the requested one")]
unconstrained fn an_aadhaar_with_a_regular_face_match_fails() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();
    let mut face_match = ios_attestation();
    face_match.mode = FACE_MATCH_MODE_REGULAR;

    claim_with_face_match(
        &mut deployment,
        user,
        of_an_aadhaar(with_face_match(chip_proof_for(user), face_match)),
        Option::some(face_match),
    );
}

#[test(should_fail_with = "missing face match capsule")]
unconstrained fn an_aadhaar_without_its_face_match_capsule_fails() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();

    claim_with_face_match(
        &mut deployment,
        user,
        of_an_aadhaar(with_face_match(chip_proof_for(user), ios_attestation())),
        Option::none(),
    );
}

// ZKPassport's app always adds a face match to an Aadhaar's proof, so this proof is one only
// another prover makes
#[test(should_fail_with = "an Aadhaar needs a strict face match")]
unconstrained fn an_aadhaar_sent_to_the_claim_without_a_face_match_fails() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();

    deployment.deliver(
        user,
        of_an_aadhaar(chip_proof_for(user)),
        Option::none(),
        Option::some(SANCTIONS_ROOT),
    );
    let _ = deployment.env.call_private(
        user,
        ZKPassportCredentials::at(deployment.credentials).claim_age_and_sanctions(user, POLICY),
    );
}

#[test(should_fail_with = "duplicate nullifiers")]
unconstrained fn an_aadhaar_earns_a_one_claim_credential_once() {
    let mut deployment = setup();
    let user = deployment.env.create_light_account();
    let face_match = ios_attestation();
    let blob = of_an_aadhaar(with_face_match(chip_proof_for(user), face_match));

    claim_with_face_match(&mut deployment, user, blob, Option::some(face_match));
    claim_with_face_match(&mut deployment, user, blob, Option::some(face_match));
}
