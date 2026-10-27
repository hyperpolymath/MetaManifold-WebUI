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
for mutation in allowlist-addition baseline-zero-gate baseline-operator-gate baseline-grouping-gate sarif upstream-exception effective-grid jcs-manifest jcs-canonicalizer raw-ijson k9-pin k9-require k9-indeterminate k9-verdict scanner-advisory scanner-secrets scanner-trigger scorecard-trigger stale-standards-owner scorecard-owner deed-remote scorecard-remote deed-source-sha scorecard-source-sha scorecard-no-upload scorecard-quiet-reconcile cross-owner-reusable fleet-unpinned fleet-before-contract fleet-dropped-download fleet-download-after-render fleet-download-fatal fleet-committed-evidence fleet-symlinked-evidence fleet-ignores-cancel; do
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
    k9-require) sed -i 's/require-files: true/require-files: false/g' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    k9-indeterminate) sed -i 's/fail-on-indeterminate: true/fail-on-indeterminate: false/' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    k9-verdict) sed -i 's/${K9_VERDICT:-orange}/${K9_VERDICT:-green}/' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    scanner-advisory) echo '    continue-on-error: true' >> "$fixture/.github/workflows/secret-scanner.yml" ;;
    scanner-secrets) echo '    secrets: inherit' >> "$fixture/.github/workflows/secret-scanner.yml" ;;
    scanner-trigger) sed -i 's/^  pull_request:/  pull_request_target:/' "$fixture/.github/workflows/secret-scanner.yml" ;;
    scorecard-trigger) sed -i '/^on:/a\  pull_request:' "$fixture/.github/workflows/scorecard.yml" ;;
    # The standards repository was transferred on 2026-10-25 and a reusable
    # `uses:` no longer follows the old owner, so either of these mutations
    # leaves a workflow that fails at plan time with no jobs at all.
    # The reconciler checkout is the one cross-owner reference that must stay a
    # checkout of the current owner; naming the pre-transfer owner there is a
    # reference, not a comment.
    stale-standards-owner) sed -i 's@repository: metadatastician/standards@repository: hyperpolymath/standards@' "$fixture/.github/workflows/scorecard-reusable.yml" ;;
    scorecard-owner) sed -i 's@uses: ./.github/workflows/scorecard-reusable.yml@uses: ./.github/workflows/scorecard-other.yml@' "$fixture/.github/workflows/scorecard.yml" ;;
    # The two lanes that went dark on 2026-10-25. A call across owners is
    # refused by the Actions policy at plan time with zero jobs, so nothing
    # reports it; the contract has to.
    deed-remote) sed -i 's|uses: ./.github/workflows/deed-conformance-reusable.yml|uses: metadatastician/standards/.github/workflows/deed-conformance.yml@75bd5994470661a099df562d6d5ad2fe744dbd66|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    scorecard-remote) sed -i 's|uses: ./.github/workflows/scorecard-reusable.yml|uses: metadatastician/standards/.github/workflows/scorecard-reusable.yml@c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d|' "$fixture/.github/workflows/scorecard.yml" ;;
    cross-owner-reusable) sed -i 's|uses: ./.github/workflows/k9-conformance-reusable.yml|uses: someone/else/.github/workflows/k9.yml@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    # Fork delta 4: the fleet report-backs must come from an immutable gitbot-fleet
    # commit, be downloaded before the grid renders, and never kill the lane.
    fleet-unpinned) sed -i -E 's|(fleet-report-back-reusable\.yml)@[0-9a-f]{40}|\1@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    fleet-before-contract) sed -i 's|needs: \[workflow-contract, fleet\]|needs: [fleet]|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    fleet-dropped-download) sed -i '/^      - name: Download the fleet report-backs$/,/^          path: .gitbot-fleet\/report-backs$/d' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    fleet-download-after-render) awk '/^      - name: Download the fleet report-backs$/{hold=1} hold && /^      - name: Render the verdict grid$/{hold=0; print; printf "%s", buf; buf=""; next} hold{buf=buf $0 "\n"; next} {print}' "$fixture/.github/workflows/hypatia-scan-reusable.yml" > "$fixture/reordered.yml" && mv "$fixture/reordered.yml" "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    fleet-download-fatal) sed -i '/^      - name: Download the fleet report-backs$/,/^          path: .gitbot-fleet\/report-backs$/{/continue-on-error: true/d}' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    fleet-committed-evidence) sed -i '/^      - name: Clear any checked-out fleet report-backs$/,/-exec rm -rf -- {} +$/d' "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    fleet-symlinked-evidence) sed -i "s|-mindepth 1 -maxdepth 1 -name '\*.json' -print -exec rm -rf -- {} +|-maxdepth 1 -name '*.json' -type f -print -delete|" "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    fleet-ignores-cancel) sed -i "s|if: \${{ !cancelled() \&\& needs.workflow-contract.result == 'success' }}|if: \${{ always() \&\& needs.workflow-contract.result == 'success' }}|" "$fixture/.github/workflows/hypatia-scan.yml" ;;
    # A copy is only a copy while it still comes from the audited commit and
    # keeps the guards whose absence froze code scanning upstream.
    deed-source-sha) sed -i 's@75bd5994470661a099df562d6d5ad2fe744dbd66@main@' "$fixture/.github/workflows/deed-conformance-reusable.yml" ;;
    scorecard-source-sha) sed -i 's@c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d@main@' "$fixture/.github/workflows/scorecard-reusable.yml" ;;
    scorecard-no-upload) sed -i '/uses: github\/codeql-action\/upload-sarif@/d' "$fixture/.github/workflows/scorecard-reusable.yml" ;;
    scorecard-quiet-reconcile) sed -i '/^      - name: Fail if reconciliation did not succeed/,/^  [a-z]/d' "$fixture/.github/workflows/scorecard-reusable.yml" ;;
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
