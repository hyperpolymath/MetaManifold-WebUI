#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Mutation tests: the contract must reject weakened security boundaries.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/.github/workflows"
cp "$ROOT/scripts/check-governance-contract.sh" "$fixture/scripts/"
reset_fixture() { cp "$ROOT"/.github/workflows/*.yml "$fixture/.github/workflows/"; }
reset_fixture
bash "$fixture/scripts/check-governance-contract.sh" > "$fixture/log" 2>&1
for mutation in sarif k9-pin k9-indeterminate k9-verdict scanner-advisory scanner-secrets scanner-trigger scorecard-trigger; do
  reset_fixture
  case "$mutation" in
    sarif) sed -i "/if: github.event_name != 'pull_request'/d" "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    k9-pin) sed -i '/uses: .*k9-conformance.yml@/s/@.*/@main/' "$fixture/.github/workflows/governance.yml" ;;
    k9-indeterminate) sed -i 's/fail-on-indeterminate: true/fail-on-indeterminate: false/' "$fixture/.github/workflows/governance.yml" ;;
    k9-verdict) sed -i 's/${K9_VERDICT:-orange}/${K9_VERDICT:-green}/' "$fixture/.github/workflows/governance.yml" ;;
    scanner-advisory) echo '    continue-on-error: true' >> "$fixture/.github/workflows/secret-scanner.yml" ;;
    scanner-secrets) echo '    secrets: inherit' >> "$fixture/.github/workflows/secret-scanner.yml" ;;
    scanner-trigger) sed -i 's/^  pull_request:/  pull_request_target:/' "$fixture/.github/workflows/secret-scanner.yml" ;;
    scorecard-trigger) sed -i '/^on:/a\  pull_request:' "$fixture/.github/workflows/scorecard.yml" ;;
  esac
  if bash "$fixture/scripts/check-governance-contract.sh" > "$fixture/log" 2>&1; then
    echo "ERROR: governance contract accepted mutation $mutation" >&2
    cat "$fixture/log" >&2
    exit 1
  fi
  echo "ok - rejected $mutation"
done
