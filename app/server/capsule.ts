import { Fr } from "@aztec-labs/aztec.js/fields"
import type { ProofResult } from "@zkpassport/sdk"
import { getNumberOfPublicInputs, getProofData, ultraVkToFields } from "@zkpassport/utils"

const VK_FIELDS = 115
const PROOF_FIELDS = 458

/** The proof capsule a gate's `verify_zkpassport_proof` reads: vk ‖ proof ‖ public inputs. */
export async function proofCapsuleFields(result: ProofResult, subproofs: number): Promise<Fr[]> {
  const circuit = `outer_count_${subproofs}`
  if (result.name !== circuit || !result.proof || !result.vkeyHash) {
    throw new Error(`expected an ${circuit} proof, got ${result.name ?? "no proof"}`)
  }

  const vk = await fetchOuterVk(result.vkeyHash)
  const { proof, publicInputs } = getProofData(result.proof, getNumberOfPublicInputs(circuit))
  if (vk.length !== VK_FIELDS || proof.length !== PROOF_FIELDS) {
    throw new Error(`unexpected ${circuit} shape: vk ${vk.length}, proof ${proof.length}`)
  }

  // utils writes fields as bare hex, which Fr.fromString would read as decimal when all digits
  return [...vk, ...proof, ...publicInputs].map((field) =>
    Fr.fromHexString(field.startsWith("0x") ? field : `0x${field}`),
  )
}

async function fetchOuterVk(vkeyHash: string): Promise<string[]> {
  const hash = vkeyHash.startsWith("0x") ? vkeyHash : `0x${vkeyHash}`
  for (const network of ["testnet", "mainnet"]) {
    const response = await fetch(`https://circuits2.zkpassport.id/${network}/by-hash/${hash}.json`)
    if (response.ok) {
      const { vkey } = (await response.json()) as { vkey: string }
      return ultraVkToFields(Buffer.from(vkey, "base64"))
    }
  }
  throw new Error(`no circuit with vkey hash ${hash} on circuits2.zkpassport.id`)
}
