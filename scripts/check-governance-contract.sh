#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Guard the fork's governance contract. The DEED, K9 and Hypatia lanes and the
# comment poster call metadatastician/standards at one full commit SHA. A PR
# scan stays visible without an independent blocking SARIF check, and the
# upstream TypeScript exception stays exact-path and narrow-rule.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CALLER=.github/workflows/hypatia-scan.yml
ALLOWLIST=config/hypatia/upstream-typescript-allowlist.txt
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

if [ -s "$CALLER" ]; then
  pass "$CALLER exists"
else
  fail "$CALLER is missing or empty"
fi
if [ -s "$ALLOWLIST" ]; then
  pass "$ALLOWLIST exists"
else
  fail "$ALLOWLIST is missing or empty"
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

# Print the pin of each call to the named standards workflow, one per line. No
# call is no output, never a failed command: the checks below report it.
lane_pin() {
  local lane=$1
  { grep -E "^    uses: metadatastician/standards/\.github/workflows/${lane}@[0-9a-f]{40}\$" <<<"$caller" || true; } \
    | sed 's/.*@//'
}

# The Hypatia lane calls metadatastician/standards directly (owner decision,
# 2026-11-10). The fork-local copy existed for two behaviours. Both are now
# opt-in inputs of the standards lane, and removing either one changes what a
# pull request can be blocked by, so both are required here.
hypatia_pin="$(lane_pin 'hypatia-scan-reusable\.yml')"
if [[ "$(grep -c . <<<"$hypatia_pin" || true)" == 1 ]]; then
  pass 'the Hypatia lane calls the standards lane at one immutable commit'
else
  fail 'the Hypatia lane must call metadatastician/standards hypatia-scan-reusable.yml at one full commit SHA'
fi
if [ ! -e .github/workflows/hypatia-scan-reusable.yml ]; then
  pass 'no stale fork-local copy of the Hypatia lane remains'
else
  fail 'a fork-local hypatia-scan-reusable.yml must not sit beside the direct call'
fi
if grep -Eq '^      sarif-upload-on-pull-request: false$' <<<"$caller"; then
  pass 'pull request scans do not create an independent blocking code-scanning check'
else
  fail 'the Hypatia lane must set sarif-upload-on-pull-request: false'
fi
if grep -Eq "^      inherited-language-paths: ${ALLOWLIST//./\\.}\$" <<<"$caller"; then
  pass 'the Hypatia lane applies the upstream TypeScript exception'
else
  fail "the Hypatia lane must set inherited-language-paths: $ALLOWLIST"
fi
if grep -Eq '^      block-on-(high|critical): true$' <<<"$caller"; then
  fail 'the Hypatia lane is advisory here; a blocking threshold needs an owner decision and a baseline'
else
  pass 'the Hypatia lane stays advisory'
fi
contains "$caller" 'needs: [workflow-contract]' \
  'this contract runs before the fleet job'
contains "$caller" 'needs: [workflow-contract, fleet, previous-grid]' \
  'the Hypatia scan runs after the contract, the fleet report-backs and the previous grid'
contains "$caller" "if: \${{ !cancelled() && needs.workflow-contract.result == 'success' }}" \
  'a dead fleet job still lets the Hypatia lane render; a failed contract or a cancelled run does not'
contains "$caller" "previous-grid-artifact: \${{ github.event_name == 'pull_request' && 'hypatia-grid-previous' || '' }}" \
  'the revision comparison reads the previous grid only on pull requests'
contains "$caller" '(.user.login // "") == "github-actions[bot]"' \
  'only a bot-authored comment is read as the previous grid'
# The fleet report-backs. The producer is pinned to a gitbot-fleet commit (same
# owner, so the Actions policy allows the reusable). The standards lane
# downloads the `fleet-report-backs` artifact before it renders the grid.
if grep -Eq '^    uses: hyperpolymath/gitbot-fleet/\.github/workflows/fleet-report-back-reusable\.yml@[0-9a-f]{40}$' <<<"$caller"; then
  pass 'the fleet report-backs come from gitbot-fleet at an immutable commit'
else
  fail 'the fleet report-backs must come from hyperpolymath/gitbot-fleet pinned to a 40-hex commit'
fi
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

# Only real reference lines count. A comment may (and the fork-local DEED lane
# does) explain the transfer by naming the old owner; a `uses:` or a checkout
# `repository:` naming it is a broken reference.
stale_owner="$(grep -rnE '^[[:space:]]*(uses:[[:space:]]+[^#]*|repository:)[[:space:]]*hyperpolymath/standards' \
  .github/workflows/ 2>/dev/null || true)"
if [ -z "$stale_owner" ]; then
  pass 'no workflow still references the pre-transfer standards owner'
else
  fail "workflows still reference hyperpolymath/standards in a uses:/repository: field - $stale_owner"
fi

# The same rule for scripts that fetch by URL instead of by `uses:`. This one
# cannot fail loudly: a `git fetch` and a release-asset download both follow a
# transfer's redirect, so a script naming the pre-transfer owner keeps working
# while recording a coordinate that no longer exists. Comment lines are exempt,
# so the transfer can still be explained where it is relevant.
# Only a URL with a scheme is a fetch. A `sed` expression or a mutation fixture
# may name the old owner as the text it rewrites; that is not a reference, and
# flagging it would make the check unsatisfiable for the test that proves it.
stale_script_owner="$(grep -rnE 'https?://github\.com/hyperpolymath/standards([^A-Za-z0-9_.-]|$)' scripts/ 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [ -z "$stale_script_owner" ]; then
  pass 'no script still fetches the pre-transfer standards owner'
else
  fail "scripts still reach hyperpolymath/standards by URL - $stale_script_owner"
fi

# A workflow that claims `gh actions-lock` management while the repository has
# no actions.lock is a claim nobody can verify: the header came with an upstream
# copy and the lock was never onboarded. Either onboard with the supported tool
# (never by hand) or drop the header; claiming and having are not the same.
if [ ! -f .github/workflows/actions.lock ] \
    && grep -rqs 'managed by gh actions-lock' .github/workflows/; then
  fail "a workflow claims gh actions-lock management but .github/workflows/actions.lock does not exist - $(grep -rls 'managed by gh actions-lock' .github/workflows/ | tr '\n' ' ')"
else
  pass 'no workflow claims an actions.lock this repository does not have'
fi


# These are independent conformance families. An empty K9 corpus must be
# shown explicitly; missing semantic evidence must not become a green DEED row.
#
# A pin that is not a full commit SHA is a float, and two different pins are
# two standards revisions in one verdict.
k9_pin="$(lane_pin 'k9-conformance\.yml')"
if [[ "$(grep -c . <<<"$k9_pin" || true)" == 1 ]]; then
  pass 'K9 validation calls the standards lane at one immutable commit'
else
  fail 'K9 validation must call metadatastician/standards k9-conformance.yml at one full commit SHA'
fi
contains "$caller" 'require-files: true' \
  'the committed K9 corpus cannot silently become empty'
contains "$caller" 'fail-on-indeterminate: true' \
  'missing K9 semantic evidence fails closed'
contains "$caller" 'needs: [deed, k9, hypatia]' \
  'the PR verdict waits for all three independent lanes'
contains "$caller" 'name: k9-grid' 'the K9 artifact remains visible to the badge job'
contains "$caller" 'out/k9-grid.json' 'the governance-badges branch publishes the K9 badge'

# The comment comes from the standards posting engine, so its markers and its
# order are the ones 3-practice/fork-governance/SPEC.adoc fixes. canon-ref
# names the renderer commit: a second commit there is a second renderer.
verdict_pin="$(lane_pin 'fork-governance-reusable\.yml')"
if [[ "$(grep -c . <<<"$verdict_pin" || true)" == 1 ]]; then
  pass 'the PR comment comes from the standards posting engine at one immutable commit'
else
  fail 'the verdict job must call metadatastician/standards fork-governance-reusable.yml at one full commit SHA'
fi
canon_ref="$({ grep -E '^      canon-ref: [0-9a-f]{40}$' <<<"$caller" || true; } | sed 's/.*: //')"
if [[ -n "$canon_ref" && "$canon_ref" == "$verdict_pin" ]]; then
  pass 'the comment renderer is the posting engine commit'
else
  fail "canon-ref must be the full commit SHA of the posting engine - canon-ref=$canon_ref engine=$verdict_pin"
fi
contains "$caller" "if: \${{ always() && github.event_name == 'pull_request' }}" \
  'the comment is posted even when a lane fails'
for input in 'deed-result: ${{ needs.deed.result }}' 'k9-result: ${{ needs.k9.result }}' \
    'k9-verdict: ${{ needs.k9.outputs.verdict }}' 'hypatia-result: ${{ needs.hypatia.result }}' \
    'hypatia-verdict: ${{ needs.hypatia.outputs.verdict }}' 'hypatia-advisory: ${{ needs.hypatia.outputs.advisory }}'; do
  contains "$caller" "$input" "the posting engine receives ${input%%:*} from the lane, not a typed value"
done
not_contains "$caller" 'gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments"' \
  'this workflow has no second comment poster'

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
contains "$scorecard_workflow" 'uses: ./.github/workflows/scorecard-reusable.yml' \
  'Scorecard calls the guarded fork-local reusable'
if grep -Eq '^  pull_request(_target)?:' <<<"$scorecard_workflow"; then
  fail 'Scorecard publication must not run against PR code'
else
  pass 'Scorecard OIDC publication is not enabled for PRs'
fi

# Reusable workflows owned by another account.
#
# A call the Actions policy does not permit fails AT PLAN TIME - zero jobs, no
# name, no line in any check summary - so it is silent. `standards` moved to
# `metadatastician` on 2026-10-25 and two lanes went dark that way. On
# 2026-11-10 the owner decided to permit metadatastician/standards reusables
# in the policy. The rule below is the durable part: the only cross-owner reusables
# are the four named standards workflows, each at a full commit SHA. Anything else
# stays fork-local or owned by the repository owner.
cross_owner="$(grep -rnE '^[[:space:]]*uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/' \
  .github/workflows/ 2>/dev/null \
  | grep -vE 'uses:[[:space:]]+\./\.github/workflows/' \
  | grep -vE 'uses:[[:space:]]+hyperpolymath/' \
  | grep -vE 'uses:[[:space:]]+metadatastician/standards/\.github/workflows/(deed-conformance|k9-conformance|hypatia-scan-reusable|fork-governance-reusable)\.yml@[0-9a-f]{40}[[:space:]]*$' || true)"
if [ -z "$cross_owner" ]; then
  pass 'every reusable workflow is fork-local, owner-owned or a pinned standards lane'
else
  fail "a reusable workflow outside the permitted set fails at plan time with no jobs - $cross_owner"
fi


deed_pin="$(lane_pin 'deed-conformance\.yml')"
if [[ "$(grep -c . <<<"$deed_pin" || true)" == 1 ]]; then
  pass 'DEED validation calls the standards lane at one immutable commit'
else
  fail 'DEED validation must call metadatastician/standards deed-conformance.yml at one full commit SHA'
fi
if [[ -n "$deed_pin" && "$deed_pin" == "$k9_pin" && "$deed_pin" == "$hypatia_pin" && "$deed_pin" == "$verdict_pin" ]]; then
  pass 'the three lanes and the posting engine use the same standards commit'
else
  fail "the three lanes and the posting engine must use one standards commit - deed=$deed_pin k9=$k9_pin hypatia=$hypatia_pin verdict=$verdict_pin"
fi
contains "$caller" 'require-files: true' \
  'a zero-file DEED corpus cannot silently pass'

scorecard_reusable="$(cat .github/workflows/scorecard-reusable.yml)"
contains "$scorecard_reusable" 'scorecard-reusable.yml at c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d' \
  'the fork-local Scorecard lane records its immutable standards source'
# The two guards whose absence froze code scanning for two months upstream, and
# again silently when a reconciler failure could skip the upload.
contains "$scorecard_reusable" 'name: Select SARIF to upload' \
  'the SARIF upload is fed by an explicit selection step'
contains "$scorecard_reusable" 'uses: github/codeql-action/upload-sarif@' \
  'the fork-local Scorecard lane still uploads SARIF to code scanning'
contains "$scorecard_reusable" 'Fail if reconciliation did not succeed' \
  'a failed reconciliation still fails the run instead of passing quietly'
contains "$scorecard_reusable" 'continue-on-error: true' \
  'the reconciler cannot skip the upload'

if [ "$failures" -gt 0 ]; then
  printf 'governance contract: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'governance contract: all %d checks passed\n' "$checks"
