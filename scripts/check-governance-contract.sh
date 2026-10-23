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

if [ "$failures" -gt 0 ]; then
  printf 'governance contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'governance contract: all %d checks passed\n' "$checks"
