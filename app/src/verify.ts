import { NullifierType, type ProofResult, ZKPassport } from "@zkpassport/sdk"

export type VerifyEvent =
  | { kind: "url"; url: string }
  | { kind: "received" }
  | { kind: "proving" }
  | { kind: "proof"; proof: ProofResult }
  | { kind: "rejected" }
  | { kind: "error"; message: string }

/**
 * Ask the ZKPassport app for a proof that the user is 18 or older, bound to their Aztec address, in
 * the outer proof form an Aztec contract verifies. Dev mode also accepts mock passports.
 */
export async function requestAgeProof(
  address: string,
  devMode: boolean,
  onEvent: (event: VerifyEvent) => void,
): Promise<void> {
  const zkpassport = new ZKPassport()
  const query = await zkpassport.request({
    name: "Fortuna",
    logo: "https://zkpassport.id/favicon.png",
    purpose: "Prove you are 18 or older to trade on Fortuna",
    mode: "compressed",
    devMode,
    uniqueIdentifierType: NullifierType.NON_SALTED,
  })

  const { url, onRequestReceived, onGeneratingProof, onProofGenerated, onReject, onError } = query
    .gte("age", 18)
    .bind("user_address", address as `0x${string}`)
    .done()

  onRequestReceived(() => onEvent({ kind: "received" }))
  onGeneratingProof(() => onEvent({ kind: "proving" }))
  onProofGenerated((proof) => {
    if (proof.name?.startsWith("outer_count_")) {
      onEvent({ kind: "proof", proof })
    }
  })
  onReject(() => onEvent({ kind: "rejected" }))
  onError((message) => onEvent({ kind: "error", message }))
  onEvent({ kind: "url", url })
}
