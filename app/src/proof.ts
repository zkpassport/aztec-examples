import type { ProofResult } from "@zkpassport/sdk"

/**
 * How the ID behind a proof was read: a passport or ID card from its chip, one by the camera of
 * ZKPassport's app, or an Aadhaar from its QR code
 */
export type IdRead = "chip" | "camera" | "aadhaar"

const OUTER_PROOF_PREFIXES: Record<IdRead, string> = {
  chip: "outer_count_",
  camera: "outer_attested_id_count_",
  aadhaar: "outer_aadhaar_count_",
}

/** The outer proof among a verification's proofs, which an Aztec contract verifies, and how its ID was read */
export function outerProof(
  proofs: ProofResult[],
): { proof: ProofResult; read: IdRead } | undefined {
  for (const proof of proofs) {
    const read = idReadOf(proof)
    if (read) {
      return { proof, read }
    }
  }
  return undefined
}

/** How the ID behind an outer proof was read, or undefined for any other proof */
export function idReadOf(proof: ProofResult): IdRead | undefined {
  return (Object.keys(OUTER_PROOF_PREFIXES) as IdRead[]).find((read) =>
    proof.name?.startsWith(OUTER_PROOF_PREFIXES[read]),
  )
}
