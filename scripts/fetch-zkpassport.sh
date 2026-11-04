#!/usr/bin/env bash
# Fetch what the tests and the e2e need from zkpassport-packages, at the ref the contracts depend on:
# the compiled ZKPassportRegistry artifact (zkpassport/target/) and the age proof fixture
# (zkpassport/fixtures/).
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
echo "zkpassport/ now holds the registry artifact and the age fixture from zkpassport-packages $ref"
