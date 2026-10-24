#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Mutation tests: the contract must reject weakened security boundaries.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/config/hypatia" "$fixture/.github/workflows"
cp "$ROOT/scripts/check-governance-contract.sh" "$fixture/scripts/"
cp "$ROOT/config/format-tools.toml" "$fixture/config/"
reset_fixture() {
  cp "$ROOT"/.github/workflows/*.yml "$fixture/.github/workflows/"
  cp "$ROOT/config/hypatia/upstream-typescript-allowlist.txt" "$fixture/config/hypatia/"
}
reset_fixture
bash "$fixture/scripts/check-governance-contract.sh" > "$fixture/log" 2>&1
for mutation in allowlist-addition baseline-zero-gate baseline-operator-gate baseline-grouping-gate sarif upstream-exception effective-grid jcs-manifest jcs-canonicalizer raw-ijson k9-pin k9-require k9-indeterminate k9-verdict scanner-advisory scanner-secrets scanner-trigger scorecard-trigger; do
  reset_fixture
  case "$mutation" in
    allowlist-addition) echo 'frontend/src/fork-only.ts' >> "$fixture/config/hypatia/upstream-typescript-allowlist.txt" ;;
    baseline-zero-gate) sed -i "/- name: Gate on baseline/,/^[[:space:]]*run:/ s@^        if: .*@        if: '!inputs.block-on-high \\&\\& steps.inherited-language.outputs.findings_count > 0'@" "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    baseline-operator-gate) sed -i '/- name: Gate on baseline/,/^[[:space:]]*run:/ s/ || / \&\& /' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    baseline-grouping-gate) sed -i '/- name: Gate on baseline/,/^[[:space:]]*run:/ { s/&& (steps/\&\& steps/; s/)\x27$/\x27/; }' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    sarif) sed -i "/if: github.event_name != 'pull_request'/d" "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    upstream-exception) sed -i 's@bash scripts/filter-hypatia-inherited-language.sh@bash scripts/no-op-filter.sh@' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    effective-grid) sed -i '/- name: Render the verdict grid/,/- name: Upload the verdict grid/s/hypatia-findings.effective.json/hypatia-findings.relativized.json/g' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    jcs-manifest) sed -i '/- name: Read the pinned ijson-jcs identity/,/- name: Cache the pinned ijson-jcs binary/s@config/format-tools.toml@config/other-tools.toml@' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    jcs-canonicalizer) sed -i '/- name: Apply upstream-inherited TypeScript exception/,/- name: Restore panic-attack build cache/s@"$HOME/.cargo/bin/ijson-jcs"@@' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    raw-ijson) sed -i '/- name: Validate findings and count severities/,/- name: Relativize finding paths/s@"$HOME/.cargo/bin/ijson-jcs" canon < hypatia-findings.json > /dev/null@@' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    k9-pin) sed -i 's/ref: c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d/ref: main/' "$fixture/.github/workflows/k9-conformance-reusable.yml" ;;
    k9-require) sed -i 's/require-files: true/require-files: false/g' "$fixture/.github/workflows/governance.yml" ;;
    k9-indeterminate) sed -i 's/fail-on-indeterminate: true/fail-on-indeterminate: false/' "$fixture/.github/workflows/governance.yml" ;;
    k9-verdict) sed -i 's/${K9_VERDICT:-orange}/${K9_VERDICT:-green}/' "$fixture/.github/workflows/governance.yml" ;;
    scanner-advisory) echo '    continue-on-error: true' >> "$fixture/.github/workflows/secret-scanner.yml" ;;
    scanner-secrets) echo '    secrets: inherit' >> "$fixture/.github/workflows/secret-scanner.yml" ;;
    scanner-trigger) sed -i 's/^  pull_request:/  pull_request_target:/' "$fixture/.github/workflows/secret-scanner.yml" ;;
    scorecard-trigger) sed -i '/^on:/a\  pull_request:' "$fixture/.github/workflows/scorecard.yml" ;;
    *) echo "ERROR: unknown mutation $mutation" >&2; exit 1 ;;
  esac
  if bash "$fixture/scripts/check-governance-contract.sh" > "$fixture/log" 2>&1; then
    echo "ERROR: governance contract accepted mutation $mutation" >&2
    cat "$fixture/log" >&2
    exit 1
  fi
  if [[ "$mutation" == allowlist-addition ]]; then
    grep -Fq 'ERROR: the complete allowlist must match the pinned upstream TypeScript snapshot' "$fixture/log"
  fi
  if [[ "$mutation" == baseline-*-gate ]]; then
    grep -Fq 'ERROR: the advisory baseline gate requires nonblocking mode and either findings or a committed baseline' "$fixture/log"
  fi
  echo "ok - rejected $mutation"
done
