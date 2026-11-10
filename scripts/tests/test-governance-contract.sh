#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Mutation tests: the contract must reject weakened security boundaries.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts/ci" "$fixture/config/hypatia" "$fixture/.github/workflows"
cp "$ROOT/scripts/check-governance-contract.sh" "$fixture/scripts/"
reset_fixture() {
  cp "$ROOT"/.github/workflows/*.yml "$fixture/.github/workflows/"
  cp "$ROOT/config/hypatia/upstream-typescript-allowlist.txt" "$fixture/config/hypatia/"
  cp "$ROOT/scripts/ci/fetch-statistics-tools.sh" "$fixture/scripts/ci/"
}
reset_fixture
bash "$fixture/scripts/check-governance-contract.sh" > "$fixture/log" 2>&1
for mutation in allowlist-addition sarif-on-pull-request sarif-input-dropped inherited-paths-dropped inherited-paths-elsewhere hypatia-unpinned hypatia-blocking hypatia-stale-copy previous-grid-untrusted verdict-unpinned canon-ref-split canon-ref-floating verdict-typed-result verdict-skips-failures k9-pin k9-require k9-indeterminate scanner-advisory scanner-secrets scanner-trigger scorecard-trigger stale-standards-owner scorecard-owner deed-unpinned scorecard-remote lane-pins-split scorecard-source-sha scorecard-no-upload scorecard-quiet-reconcile cross-owner-reusable fleet-unpinned fleet-before-contract fleet-ignores-cancel stale-standards-remote lock-header-without-lock; do
  reset_fixture
  case "$mutation" in
    allowlist-addition) echo 'frontend/src/fork-only.ts' >> "$fixture/config/hypatia/upstream-typescript-allowlist.txt" ;;
    # The Hypatia lane is the standards lane, called directly. The two opt-in
    # inputs are what the fork-local copy existed for: without the first, a
    # pull request gets a second, blocking code-scanning check; without the
    # second, every upstream TypeScript file grades as a banned language.
    sarif-on-pull-request) sed -i 's/^      sarif-upload-on-pull-request: false$/      sarif-upload-on-pull-request: true/' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    sarif-input-dropped) sed -i '/^      sarif-upload-on-pull-request: false$/d' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    inherited-paths-dropped) sed -i '/^      inherited-language-paths: /d' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    inherited-paths-elsewhere) sed -i 's|^      inherited-language-paths: .*|      inherited-language-paths: config/hypatia/other-list.txt|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    hypatia-unpinned) sed -i -E 's|(hypatia-scan-reusable\.yml)@[0-9a-f]{40}|\1@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    hypatia-blocking) sed -i 's/^      sarif-upload-on-pull-request: false$/&\n      block-on-high: true/' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    hypatia-stale-copy) echo 'name: stale copy' > "$fixture/.github/workflows/hypatia-scan-reusable.yml" ;;
    previous-grid-untrusted) sed -i 's/(.user.login \/\/ "") == "github-actions\[bot\]"/true/' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    # One comment, from the standards posting engine, rendered at the lane pin.
    verdict-unpinned) sed -i -E 's|(fork-governance-reusable\.yml)@[0-9a-f]{40}|\1@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    canon-ref-split) sed -i -E 's|^      canon-ref: [0-9a-f]{40}$|      canon-ref: 75bd5994470661a099df562d6d5ad2fe744dbd66|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    canon-ref-floating) sed -i -E 's|^      canon-ref: [0-9a-f]{40}$|      canon-ref: main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    verdict-typed-result) sed -i 's|hypatia-result: ${{ needs.hypatia.result }}|hypatia-result: success|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    verdict-skips-failures) sed -i "s|if: \${{ always() \&\& github.event_name == 'pull_request' }}|if: \${{ github.event_name == 'pull_request' }}|" "$fixture/.github/workflows/hypatia-scan.yml" ;;
    k9-pin) sed -i -E 's|(k9-conformance\.yml)@[0-9a-f]{40}|\1@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    k9-require) sed -i 's/require-files: true/require-files: false/g' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    k9-indeterminate) sed -i 's/fail-on-indeterminate: true/fail-on-indeterminate: false/' "$fixture/.github/workflows/hypatia-scan.yml" ;;
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
    # A call the Actions policy does not permit is refused at plan time with
    # zero jobs, so nothing reports it; the contract has to. The two standards
    # lanes are permitted only at a full commit SHA, and only at one commit.
    deed-unpinned) sed -i -E 's|(deed-conformance\.yml)@[0-9a-f]{40}|\1@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    lane-pins-split) sed -i -E 's|(deed-conformance\.yml)@[0-9a-f]{40}|\1@75bd5994470661a099df562d6d5ad2fe744dbd66|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    scorecard-remote) sed -i 's|uses: ./.github/workflows/scorecard-reusable.yml|uses: metadatastician/standards/.github/workflows/scorecard-reusable.yml@c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d|' "$fixture/.github/workflows/scorecard.yml" ;;
    cross-owner-reusable) sed -i -E 's|uses: metadatastician/standards/\.github/workflows/k9-conformance\.yml@[0-9a-f]{40}|uses: someone/else/.github/workflows/k9.yml@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    # The fleet report-backs must come from an immutable gitbot-fleet commit and
    # never kill the lane. The standards lane downloads them before the grid.
    fleet-unpinned) sed -i -E 's|(fleet-report-back-reusable\.yml)@[0-9a-f]{40}|\1@main|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    fleet-before-contract) sed -i 's|needs: \[workflow-contract, fleet, previous-grid\]|needs: [fleet]|' "$fixture/.github/workflows/hypatia-scan.yml" ;;
    fleet-ignores-cancel) sed -i "s|if: \${{ !cancelled() \&\& needs.workflow-contract.result == 'success' }}|if: \${{ always() \&\& needs.workflow-contract.result == 'success' }}|" "$fixture/.github/workflows/hypatia-scan.yml" ;;
    # A script that fetches by URL keeps working across a transfer's redirect
    # while naming an owner that no longer holds the repository: a coordinate
    # that resolves only as a courtesy, and a future pin review that reads the
    # wrong history.
    stale-standards-remote) sed -i 's@github.com/metadatastician/standards@github.com/hyperpolymath/standards@' "$fixture/scripts/ci/fetch-statistics-tools.sh" ;;
    # A lock header without a lock is an unverifiable claim: nothing ever
    # onboarded this repository, so no check reads the refs the header says are
    # read.
    lock-header-without-lock) sed -i '1i # This workflow is managed by gh actions-lock.' "$fixture/.github/workflows/ci.yml" ;;
    # A copy is only a copy while it still comes from the audited commit and
    # keeps the guards whose absence froze code scanning upstream.
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
  # A lane without a full pin must be named, not die on a failed command.
  if [[ "$mutation" == k9-pin ]]; then
    grep -Fq 'ERROR: K9 validation must call metadatastician/standards k9-conformance.yml at one full commit SHA' "$fixture/log"
  fi
  if [[ "$mutation" == deed-unpinned ]]; then
    grep -Fq 'ERROR: DEED validation must call metadatastician/standards deed-conformance.yml at one full commit SHA' "$fixture/log"
  fi
  if [[ "$mutation" == lane-pins-split ]]; then
    grep -Fq 'ERROR: the three lanes and the posting engine must use one standards commit' "$fixture/log"
  fi
  if [[ "$mutation" == sarif-on-pull-request || "$mutation" == sarif-input-dropped ]]; then
    grep -Fq 'ERROR: the Hypatia lane must set sarif-upload-on-pull-request: false' "$fixture/log"
  fi
  if [[ "$mutation" == inherited-paths-* ]]; then
    grep -Fq 'ERROR: the Hypatia lane must set inherited-language-paths: config/hypatia/upstream-typescript-allowlist.txt' "$fixture/log"
  fi
  if [[ "$mutation" == hypatia-unpinned ]]; then
    grep -Fq 'ERROR: the Hypatia lane must call metadatastician/standards hypatia-scan-reusable.yml at one full commit SHA' "$fixture/log"
  fi
  if [[ "$mutation" == canon-ref-* ]]; then
    grep -Fq 'ERROR: canon-ref must be the full commit SHA of the posting engine' "$fixture/log"
  fi
  echo "ok - rejected $mutation"
done
