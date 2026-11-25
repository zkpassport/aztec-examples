export function shortAddress(address: string): string {
  return `${address.slice(0, 8)}…${address.slice(-6)}`
}
