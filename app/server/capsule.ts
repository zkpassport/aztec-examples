import type { Fr } from "@aztec-labs/aztec.js/fields"
import type { ProofResult } from "@zkpassport/sdk"
import { assembleProofCapsule, fetchOuterVk } from "@zkpassport/aztec"
import { getNumberOfPublicInputs, getProofData } from "@zkpassport/utils"

/** The proof capsule a gate's `verify_zkpassport_proof` reads: vk ‖ proof ‖ public inputs. */
export async function proofCapsuleFields(result: ProofResult, subproofs: number): Promise<Fr[]> {
  const circuit = `outer_count_${subproofs}`
  if (result.name !== circuit || !result.proof || !result.vkeyHash) {
    throw new Error(`expected an ${circuit} proof, got ${result.name ?? "no proof"}`)
  }

  const vk = await fetchOuterVk(result.vkeyHash)
  const { proof, publicInputs } = getProofData(result.proof, getNumberOfPublicInputs(circuit))
  return assembleProofCapsule({ vk, proof, publicInputs }, subproofs)
}
