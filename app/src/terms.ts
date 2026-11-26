/** Fortuna's terms. A credential's proof is bound to their digest, so it records which text was accepted. */
export const TERMS = `Fortuna terms (demo)

1. Fortuna is a demonstration on the Aztec testnet. Its markets hold no funds and settle nothing.
2. You may trade only if you are 18 or older and not on a sanctions list, which your passport
   proof shows.
3. Each market counts its orders publicly by side, without naming who placed them.
4. These terms illustrate binding terms to a proof. They are not a legal agreement.`

/** The SHA-256 digest of `terms` in lowercase hex, which the ZKPassport request binds as custom data */
export async function termsDigest(terms: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(terms))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}
