#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Guard the fork-local Hypatia advisory-scan contract. In particular, a PR scan
# must remain visible in artifacts/the verdict grid without uploading SARIF to
# GitHub's independent, blocking code-scanning-results check.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CALLER=.github/workflows/governance.yml
REUSABLE=.github/workflows/hypatia-scan-reusable.yml
STANDARDS_SHA=01c9b0c9f2646ebea0b30a9588462642ac94aee9
failures=0
checks=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  checks=$((checks + 1))
  printf 'ok %d - %s\n' "$checks" "$1"
}

contains() { # haystack needle description
  if grep -Fq -- "$2" <<<"$1"; then
    pass "$3"
  else
    fail "$3 (missing: $2)"
  fi
}

not_contains() { # haystack needle description
  if grep -Fq -- "$2" <<<"$1"; then
    fail "$3 (unexpected: $2)"
  else
    pass "$3"
  fi
}

step_block() { # file step-name
  awk -v step="$2" '
    $0 == "      - name: " step { found = 1; print; next }
    found && /^      - name: / { exit }
    found { print }
    END { if (!found) exit 1 }
  ' "$1"
}

for file in "$CALLER" "$REUSABLE"; do
  if [ -s "$file" ]; then
    pass "$file exists"
  else
    fail "$file is missing or empty"
  fi
done

# Do not continue with misleading secondary errors if either input is absent.
if [ "$failures" -gt 0 ]; then
  exit 1
fi

caller="$(cat "$CALLER")"
reusable="$(cat "$REUSABLE")"

contains "$caller" 'uses: ./.github/workflows/hypatia-scan-reusable.yml' \
  'the governance lane calls the fork-local reusable'
not_contains "$caller" 'uses: hyperpolymath/standards/.github/workflows/hypatia-scan-reusable.yml@' \
  'the governance lane cannot bypass the fork guard by calling standards directly'
contains "$caller" 'needs: [workflow-contract]' \
  'this contract runs before the Hypatia scan'
if grep -Eq '^  pull_request:$' <<<"$caller"; then
  pass 'governance still runs for pull requests'
else
  fail 'governance still runs for pull requests'
fi
if grep -Eq '^  push:$' <<<"$caller"; then
  pass 'governance still runs for pushes to the default branch'
else
  fail 'governance still runs for pushes to the default branch'
fi

contains "$reusable" "hypatia-scan-reusable.yml at $STANDARDS_SHA." \
  'the fork records its immutable standards source'
not_contains "$reusable" 'ref: ${{ job.workflow_sha }}' \
  'a standards checkout cannot use the MetaManifold workflow SHA'

if upload="$(step_block "$REUSABLE" 'Upload SARIF to code scanning')"; then
  contains "$upload" "if: github.event_name != 'pull_request'" \
    'advisory pull-request scans skip SARIF upload'
  contains "$upload" 'uses: github/codeql-action/upload-sarif@' \
    'push and manual scans retain code-scanning reconciliation'
else
  fail 'the SARIF upload step exists'
fi

if scan="$(step_block "$REUSABLE" 'Run Hypatia scan')"; then
  not_contains "$scan" 'if: github.event_name' \
    'the Hypatia scanner itself remains enabled for every event'
  contains "$scan" 'hypatia-findings.json' \
    'the scanner still emits raw JSON findings'
else
  fail 'the Hypatia scan step exists'
fi

if artifacts="$(step_block "$REUSABLE" 'Upload findings artifacts')"; then
  contains "$artifacts" 'hypatia-findings.json' \
    'raw findings remain available on advisory pull-request runs'
  not_contains "$artifacts" 'if: github.event_name' \
    'artifact upload is not accidentally restricted by event'
else
  fail 'the findings-artifact step exists'
fi

if grid="$(step_block "$REUSABLE" 'Render the verdict grid')"; then
  contains "$grid" 'if: ${{ always() }}' \
    'the verdict grid still renders after scanner failures'
  contains "$grid" '--hypatia' \
    'the verdict grid still consumes Hypatia findings'
else
  fail 'the verdict-grid render step exists'
fi

if renderer="$(step_block "$REUSABLE" 'Check out the verdict grid renderer at this workflow'"'"'s commit')"; then
  contains "$renderer" 'repository: hyperpolymath/standards' \
    'the renderer comes from the standards repository'
  contains "$renderer" "ref: $STANDARDS_SHA" \
    'the standards renderer uses the immutable source pin'
else
  fail 'the standards renderer checkout exists'
fi

upload_count="$(grep -c 'uses: github/codeql-action/upload-sarif@' "$REUSABLE" || true)"
if [ "$upload_count" -eq 1 ]; then
  pass 'there is exactly one SARIF upload site to guard'
else
  fail "expected one SARIF upload site, found $upload_count"
fi

# These are independent conformance families. An empty K9 corpus must be
# shown explicitly; missing semantic evidence must not become a green DEED row.
contains "$caller" 'uses: ./.github/workflows/k9-conformance-reusable.yml' \
  'K9 validation uses the guarded fork-local reusable'
k9_workflow="$(cat .github/workflows/k9-conformance-reusable.yml)"
contains "$k9_workflow" 'ref: c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d' \
  'the K9 validator and renderer use the immutable standards source'
not_contains "$k9_workflow" 'ref: ${{ job.workflow_sha }}' \
  'the K9 standards checkout cannot use the caller SHA'
contains "$k9_workflow" 'if [ -f "$RUNNER_TEMP/corpus.log" ]; then' \
  'optional corpus-log copying cannot fail an empty K9 corpus'
contains "$caller" 'require-files: true' \
  'the committed K9 corpus cannot silently become empty'
contains "$caller" 'fail-on-indeterminate: true' \
  'missing K9 semantic evidence fails closed'
contains "$caller" 'needs: [deed, k9, hypatia]' \
  'the PR verdict waits for all three independent lanes'
contains "$caller" 'name: k9-grid' 'the K9 artifact remains visible in the PR verdict'
contains "$caller" 'out/k9-grid.json' 'the governance-badges branch publishes the K9 badge'
contains "$caller" '${K9_VERDICT:-orange}' 'an absent K9 verdict is indeterminate'

secret_workflow="$(cat .github/workflows/secret-scanner.yml)"
contains "$secret_workflow" 'uses: ./.github/workflows/secret-scanner-reusable.yml' \
  'full-history secret scanning uses the guarded fork-local reusable'
secret_reusable="$(cat .github/workflows/secret-scanner-reusable.yml)"
contains "$secret_reusable" 'GITLEAKS_VERSION=8.30.1' 'Gitleaks uses the tested current detector'
contains "$secret_reusable" 'SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' \
  'the scanner binary matches the upstream release-asset digest'
contains "$secret_reusable" 'ref: c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d' \
  'the estate baseline remains pinned to the audited standards source'
contains "$secret_reusable" 'fetch-depth: 0' 'secret scanning retains full Git history'
not_contains "$secret_reusable" 'ref: ${{ job.workflow_sha }}' \
  'secret baseline checkout cannot use the caller SHA'
not_contains "$secret_workflow" 'secrets:' 'the secret scanner receives no caller secrets'
not_contains "$secret_workflow" 'continue-on-error:' 'secret scanner failures cannot be advisory'
not_contains "$secret_workflow" 'pull_request_target:' 'secret scanning does not use a privileged PR trigger'
scorecard_workflow="$(cat .github/workflows/scorecard.yml)"
contains "$scorecard_workflow" 'uses: hyperpolymath/standards/.github/workflows/scorecard-reusable.yml@c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d' \
  'Scorecard uses the audited immutable reusable'
if grep -Eq '^  pull_request(_target)?:' <<<"$scorecard_workflow"; then
  fail 'Scorecard publication must not run against PR code'
else
  pass 'Scorecard OIDC publication is not enabled for PRs'
fi

if [ "$failures" -gt 0 ]; then
  printf 'governance contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'governance contract: all %d checks passed\n' "$checks"
