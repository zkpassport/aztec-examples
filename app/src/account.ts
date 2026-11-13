const STORAGE_KEY = "fortuna.account"

/** The Aztec address this browser trades as: the one the user set, or a demo address made here. */
export function loadAccount(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved && isAztecAddress(saved)) {
      return saved
    }
  } catch {
    // Storage can be unavailable (private windows); a fresh address works the same
  }
  return saveAccount(demoAddress())
}

export function saveAccount(address: string): string {
  try {
    localStorage.setItem(STORAGE_KEY, address)
  } catch {
    // The address then lasts until the page reloads
  }
  return address
}

export function isAztecAddress(value: string): boolean {
  return /^0x[0-9a-fA-F]{64}$/.test(value)
}

/** A random 31-byte value, which is always a valid field element. */
export function demoAddress(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(31))
  return `0x00${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 8)}…${address.slice(-6)}`
}
