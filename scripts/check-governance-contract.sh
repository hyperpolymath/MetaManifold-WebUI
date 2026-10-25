#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Guard the fork-local Hypatia scan contract. A PR scan remains visible without
# creating an independent blocking SARIF check, and the upstream TypeScript
# exception stays exact-path, narrow-rule, and audit-preserving.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CALLER=.github/workflows/hypatia-scan.yml
REUSABLE=.github/workflows/hypatia-scan-reusable.yml
ALLOWLIST=config/hypatia/upstream-typescript-allowlist.txt
FORMAT_TOOLS=config/format-tools.toml
STANDARDS_SHA=01c9b0c9f2646ebea0b30a9588462642ac94aee9
UPSTREAM_SHA=a325589d3d318847c15b21cd34fb7d6e7a6d2f7b
# SHA-256 of the sorted unique paths audited at UPSTREAM_SHA, with a final LF.
ALLOWLIST_SHA256=531f92fdf33487a03b03381c40a6cc9a53a771b870b92fc18feed18c9c1798a7
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
if [ -s "$ALLOWLIST" ]; then
  pass "$ALLOWLIST exists"
else
  fail "$ALLOWLIST is missing or empty"
fi
if [ -s "$FORMAT_TOOLS" ]; then
  pass "$FORMAT_TOOLS exists"
else
  fail "$FORMAT_TOOLS is missing or empty"
fi

# Do not continue with misleading secondary errors if an input is absent.
if [ "$failures" -gt 0 ]; then
  exit 1
fi

if grep -Fq "# Source: JoshuaJewell/MetaManifold-WebUI @ $UPSTREAM_SHA " "$ALLOWLIST"; then
  pass 'the TypeScript exception records its immutable upstream source snapshot'
else
  fail "the TypeScript exception must record upstream commit $UPSTREAM_SHA"
fi
if grep -Fqx 'frontend/src/App.tsx' "$ALLOWLIST"; then
  pass 'an upstream TypeScript path is included in the exact-path allowlist'
else
  fail 'the exact-path allowlist includes the known upstream App.tsx path'
fi
if grep -Fqx 'frontend/src/utils/text.test.ts' "$ALLOWLIST"; then
  fail 'the fork-only TypeScript path must remain outside the upstream allowlist'
else
  pass 'the fork-only TypeScript path remains outside the upstream allowlist'
fi
allowlist_entries="$(grep -Ev '^(#|$)' "$ALLOWLIST" || true)"
allowlist_digest="$(printf '%s\n' "$allowlist_entries" | LC_ALL=C sort -u | sha256sum)"
if [ "${allowlist_digest%% *}" = "$ALLOWLIST_SHA256" ]; then
  pass 'the complete allowlist matches the pinned upstream TypeScript snapshot'
else
  fail 'the complete allowlist must match the pinned upstream TypeScript snapshot'
fi
if [ -n "$allowlist_entries" ] && ! grep -Eq '[*?]' <<<"$allowlist_entries" \
    && ! grep -Eqv '\.(ts|tsx)$' <<<"$allowlist_entries"; then
  pass 'the allowlist contains exact TypeScript paths, not globs or other languages'
else
  fail 'the allowlist must contain only exact .ts/.tsx paths, without glob syntax'
fi

# Stop after a broken exception manifest rather than emitting secondary noise.
if [ "$failures" -gt 0 ]; then
  exit 1
fi

caller="$(cat "$CALLER")"
reusable="$(cat "$REUSABLE")"

contains "$caller" 'uses: ./.github/workflows/hypatia-scan-reusable.yml' \
  'the governance lane calls the fork-local reusable'
# The standards repository is metadatastician/standards; it was
# hyperpolymath/standards until the transfer on 2026-10-25. Both names are
# checked, because a bypass through either one skips the fork guard.
not_contains "$caller" 'uses: metadatastician/standards/.github/workflows/hypatia-scan-reusable.yml@' \
  'the governance lane cannot bypass the fork guard by calling standards directly'
not_contains "$caller" 'uses: hyperpolymath/standards/.github/workflows/hypatia-scan-reusable.yml@' \
  'the governance lane cannot bypass the fork guard through the pre-transfer name'
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

if jcs_pin="$(step_block "$REUSABLE" 'Read the pinned ijson-jcs identity')"; then
  contains "$jcs_pin" 'config/format-tools.toml' \
    'the JCS tool pin comes from the repository format-tools manifest'
  contains "$jcs_pin" "['ijson_jcs']" \
    'the JCS installer reads the ijson-jcs identity from the manifest'
  contains "$jcs_pin" "pin['rust_toolchain']" \
    'the JCS Rust toolchain is resolved from the same manifest'
else
  fail 'the pinned ijson-jcs identity step exists'
fi
if jcs_install="$(step_block "$REUSABLE" 'Install pinned ijson-jcs')"; then
  contains "$jcs_install" 'cargo "+$IJSON_JCS_RUST_TOOLCHAIN" install --quiet' \
    'ijson-jcs is built with the pinned Rust toolchain'
  contains "$jcs_install" '--git "$IJSON_JCS_REPOSITORY" --rev "$IJSON_JCS_REVISION"' \
    'ijson-jcs is built from the immutable repository revision'
  contains "$jcs_install" '--locked' \
    'ijson-jcs dependencies are installed from Cargo.lock'
else
  fail 'the pinned ijson-jcs install step exists'
fi
if jcs_verify="$(step_block "$REUSABLE" 'Verify ijson-jcs and test the exception output')"; then
  contains "$jcs_verify" 'IJSON_JCS="$IJSON_JCS" bash scripts/tests/test-hypatia-inherited-language-exception.sh' \
    'the exception transform is tested with the real pinned canonicalizer'
else
  fail 'the pinned ijson-jcs smoke and exception test step exists'
fi

if upload="$(step_block "$REUSABLE" 'Upload SARIF to code scanning')"; then
  contains "$upload" "if: github.event_name != 'pull_request'" \
    'advisory pull-request scans skip SARIF upload'
  contains "$upload" 'uses: github/codeql-action/upload-sarif@' \
    'push and manual scans retain code-scanning reconciliation'
  contains "$upload" 'sarif_file: hypatia-effective.sarif' \
    'code scanning receives the exception-aware SARIF projection'
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

if exception="$(step_block "$REUSABLE" 'Apply upstream-inherited TypeScript exception')"; then
  contains "$exception" 'if: ${{ always() }}' \
    'the exception step records a result even after scan failures'
  contains "$exception" 'scripts/filter-hypatia-inherited-language.sh' \
    'the fork-local allowlist transform is applied after path normalization'
  contains "$exception" 'hypatia-findings.effective.json' \
    'the exception creates a distinct effective findings projection'
  contains "$exception" 'hypatia-effective.sarif' \
    'the exception creates a distinct effective SARIF projection'
  contains "$exception" '"$HOME/.cargo/bin/ijson-jcs"' \
    'the effective findings are canonicalized with the pinned CLI'
else
  fail 'the upstream-inherited TypeScript exception step exists'
fi
if raw_validation="$(step_block "$REUSABLE" 'Validate findings and count severities')"; then
  contains "$raw_validation" 'ijson-jcs" canon < hypatia-findings.json' \
    'raw findings are strict I-JSON validated before jq parses them'
else
  fail 'raw I-JSON validation is part of the findings check'
fi

if artifacts="$(step_block "$REUSABLE" 'Upload findings artifacts')"; then
  contains "$artifacts" 'hypatia-findings.json' \
    'raw findings remain available on advisory pull-request runs'
  contains "$artifacts" 'hypatia-findings.effective.json' \
    'the exception-aware findings remain available alongside raw evidence'
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
  contains "$grid" 'hypatia-findings.effective.json' \
    'the verdict grid prefers the exception-aware projection'
else
  fail 'the verdict-grid render step exists'
fi

if baseline="$(step_block "$REUSABLE" 'Filter SARIF through the baseline before upload')"; then
  contains "$baseline" 'hypatia-effective.sarif hypatia-findings.effective.json' \
    'baseline filtering uses the same exception-aware findings as the grid'
else
  fail 'the SARIF baseline-filter step exists'
fi
if gate="$(step_block "$REUSABLE" 'Gate on baseline (blocking when a baseline is committed)')"; then
  contains "$gate" 'hypatia-findings.effective.json' \
    'the baseline gate consumes exception-aware findings'
  if grep -Fxq "        if: '!inputs.block-on-high && (steps.inherited-language.outputs.findings_count > 0 || hashFiles(''.hypatia-baseline.json'') != '''')'" <<<"$gate"; then
    pass 'the advisory baseline gate requires nonblocking mode and either findings or a committed baseline'
  else
    fail 'the advisory baseline gate requires nonblocking mode and either findings or a committed baseline'
  fi
else
  fail 'the baseline gate step exists'
fi
if blocking="$(step_block "$REUSABLE" 'Block high and critical findings when requested')"; then
  contains "$blocking" 'hypatia-effective.sarif' \
    'the blocking gate evaluates exception-aware SARIF'
else
  fail 'the requested high/critical gate step exists'
fi
if advisory="$(step_block "$REUSABLE" 'Check for critical issues (ADVISORY — does not gate)')"; then
  contains "$advisory" 'steps.inherited-language.outputs.critical' \
    'the critical advisory count excludes only the inherited TypeScript exception'
else
  fail 'the critical advisory step exists'
fi
not_contains "$reusable" 'steps.scan.outputs.critical > 0' \
  'the raw critical count cannot drive an exception-inconsistent advisory'

if renderer="$(step_block "$REUSABLE" 'Check out the verdict grid renderer at this workflow'"'"'s commit')"; then
  contains "$renderer" 'repository: metadatastician/standards' \
    'the renderer comes from the standards repository'
  contains "$renderer" "ref: $STANDARDS_SHA" \
    'the standards renderer uses the immutable source pin'
else
  fail 'the standards renderer checkout exists'
fi

stale_owner="$(grep -rn 'hyperpolymath/standards' .github/workflows/ 2>/dev/null || true)"
if [ -z "$stale_owner" ]; then
  pass 'no workflow still names the pre-transfer standards owner'
else
  fail "workflows still reference hyperpolymath/standards, which no longer resolves for a reusable uses: - $stale_owner"
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
contains "$scorecard_workflow" 'uses: metadatastician/standards/.github/workflows/scorecard-reusable.yml@c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d' \
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
