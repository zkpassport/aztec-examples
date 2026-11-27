use aztec::{context::PrivateContext, protocol::address::AztecAddress};
use zkpassport::constants::VERIFICATION_TIER_DEVICE_ATTESTED;
use zkpassport_aztec_verifier::{
    query::Query,
    verify::{ServiceConfig, VerifiedProof, verify_device_attested_proof, verify_zkpassport_proof},
};

/// Verifies the proof of an ID its issuer signed, such as a chip read or an Aadhaar, that meets
/// `query` and is bound to `user`, and to `custom_data` as well unless it is all zeros
pub fn verify_bound<let K: u32, let D: u32, let F: u32, let N: u32>(
    context: &mut PrivateContext,
    capsule_scope: AztecAddress,
    user: AztecAddress,
    service: ServiceConfig,
    custom_data: [u8; N],
    query: Query<K, D, 0, F>,
) -> VerifiedProof {
    verify_zkpassport_proof(
        context,
        capsule_scope,
        service,
        bind(query, user, custom_data),
    )
}

/// As `verify_bound`, for the proof of an ID read by the camera of ZKPassport's app and attested
/// by the device
pub fn verify_bound_camera_read<let K: u32, let D: u32, let N: u32>(
    context: &mut PrivateContext,
    capsule_scope: AztecAddress,
    user: AztecAddress,
    service: ServiceConfig,
    custom_data: [u8; N],
    query: Query<K, D, 0, 0>,
) -> VerifiedProof {
    verify_device_attested_proof(
        context,
        capsule_scope,
        service.allow_tier(VERIFICATION_TIER_DEVICE_ATTESTED),
        bind(query, user, custom_data),
    )
}

fn bind<let K: u32, let D: u32, let F: u32, let N: u32>(
    query: Query<K, D, 0, F>,
    user: AztecAddress,
    custom_data: [u8; N],
) -> Query<K + 1, D, 1, F> {
    let query = query.bind_user_address(user);
    if custom_data == [0; N] {
        query
    } else {
        query.bind_custom_data(custom_data.as_str_unchecked())
    }
}

/// `bytes` packed big-endian into fields of 31 bytes each, so storing them takes 3 slots, not 64
pub fn pack_custom_data(bytes: [u8; 64]) -> [Field; 3] {
    let mut packed = [0; 3];
    for i in 0..64 {
        let chunk = i / 31;
        packed[chunk] = packed[chunk] * 256 + bytes[i] as Field;
    }
    packed
}

/// The bytes `pack_custom_data` packed
pub fn unpack_custom_data(packed: [Field; 3]) -> [u8; 64] {
    let first: [u8; 31] = packed[0].to_be_bytes();
    let second: [u8; 31] = packed[1].to_be_bytes();
    let last: [u8; 2] = packed[2].to_be_bytes();

    let mut bytes = [0; 64];
    for i in 0..31 {
        bytes[i] = first[i];
        bytes[31 + i] = second[i];
    }
    bytes[62] = last[0];
    bytes[63] = last[1];
    bytes
}
