#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Requires actual artifacts from the Julia suite; no generated substitute.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${DOI_CONTRACT_ARTIFACTS:?Run the Julia lifecycle suite with an artifact directory first}"
nickel=${NICKEL:-nickel}
command -v "$nickel" >/dev/null || { echo 'Nickel is required for this contract gate' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
contract=$(jq -nc --arg path "$PWD/config/schemas/doi_publication.ncl" '$path')
for env in sandbox production; do
    file="$DOI_CONTRACT_ARTIFACTS/attestation-$env"
    input=$(jq -nc --arg path "$file.ncl" '$path')
    "$nickel" export --format json --expr "let C = import $contract in (import $input) | C" > "$tmp/export.json"
    diff -u <(jq -S . "$file.json") <(jq -S . "$tmp/export.json")
    for change in '.state="published"' '.config_hash="wrong"' '.doi="10.5281/zenodo.999"' '.kind="analysis_result" | .result_id=null'; do
        jq "$change" "$file.json" > "$tmp/invalid.json"
        invalid=$(jq -nc --arg path "$tmp/invalid.json" '$path')
        if "$nickel" export --format json --expr "let C = import $contract in (import $invalid) | C" > /dev/null 2>&1; then
            echo "Nickel accepted an invalid $env attestation ($change)" >&2; exit 1
        fi
    done
done
printf 'Nickel attestation contracts and negative cases passed\n'
