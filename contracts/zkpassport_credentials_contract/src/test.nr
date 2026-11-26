// TXE no-ops the recursion opcode, so these tests prove the wiring (capsules → parse → policy →
// registry views → nullifier → credential note), NOT proof validity. Proof validity is covered by
// zkpassport-packages' test-harness.
mod age;
mod fixtures;
mod nationality;
mod policies;
mod sanctions;
