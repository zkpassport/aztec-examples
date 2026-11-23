#!/usr/bin/env bash
# Fetch what the tests and the e2e need from zkpassport-packages, at the ref the contracts depend on:
# the compiled ZKPassportRegistry artifact the tests deploy (zkpassport/target/), the age proof
# fixture the e2e proves with (zkpassport/fixtures/), and the ZKPassport npm packages the e2e
# installs (zkpassport/npm/), which that ref may not have published yet.
#
# Usage: scripts/fetch-zkpassport.sh
# Env: AZTEC, an Aztec toolchain version directory (default ~/.aztec/versions/<.aztecrc>)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=$root/contracts/age_gate_contract/Nargo.toml
ref=$(sed -nE 's|^zkpassport_registry_contract = \{ git = "[^"]+", tag = "([^"]+)".*|\1|p' "$manifest")
if [ -z "$ref" ]; then
  echo "No zkpassport_registry_contract git tag in $manifest" >&2
  exit 1
fi

version=$(tr -d '[:space:]' < "$root/.aztecrc")
AZTEC=${AZTEC:-${AZTEC_HOME:-$HOME/.aztec}/versions/$version}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone --quiet --depth 1 --branch "$ref" https://github.com/zkpassport/zkpassport-packages "$work/packages"
library=$work/packages/packages/aztec

# The registry must be compiled by the toolchain the contracts and tests use.
library_version=$(tr -d '[:space:]' < "$library/.aztecrc")
if [ "$library_version" != "$version" ]; then
  echo "zkpassport-packages $ref pins Aztec $library_version, this repo $version" >&2
  exit 1
fi

(cd "$library/noir" && "$AZTEC/bin/aztec" compile)

mkdir -p "$root/zkpassport/target" "$root/zkpassport/fixtures"
cp "$library/noir/target/zkpassport_registry_contract-ZKPassportRegistry.json" "$root/zkpassport/target/"
cp "$library/test-harness/fixtures/outer_count_5_age.json" "$root/zkpassport/fixtures/"

# Packing turns their workspace dependencies into versions. Each package lands unpacked in
# zkpassport/npm/<name>/, which package.json files depend on as a directory: unlike a tarball's, a
# directory's contents aren't pinned by the package-locks, so they can change with the ref.
bun() { npx --yes bun@1.3.8 "$@"; }
(cd "$work/packages" && bun install --frozen-lockfile >/dev/null)
rm -rf "$root/zkpassport/npm"
mkdir -p "$root/zkpassport/npm" "$work/npm"
for package in zkpassport-utils registry-sdk zkpassport-sdk aztec/ts; do
  (cd "$work/packages/packages/$package" && bun run build >/dev/null && bun pm pack --quiet --destination "$work/npm" >/dev/null)
done
for name in utils registry sdk aztec; do
  mkdir "$root/zkpassport/npm/$name"
  tar -xzf "$work/npm/zkpassport-$name-"*.tgz -C "$root/zkpassport/npm/$name" --strip-components 1
done
echo "zkpassport/ now holds the registry artifact, the age fixture and the npm packages from zkpassport-packages $ref"
