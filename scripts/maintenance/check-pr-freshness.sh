#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Enforce the first two pull-request rules in CONTRIBUTING.md, before a
# reviewer spends time on the diff:
#
#   1. The merge base of the branch and the base branch is the base tip
#      (`behind_by` is 0). A branch cut from an older snapshot is rebased onto
#      the current base, not merged forward.
#   2. The branch carries no merge commit from the base branch and no
#      conflict-resolution merge. Squashing happens on merge.
#
# Both rules exist because a stacked or drifted branch does not get reviewed
# twice; it gets merged by accident or closed after weeks of conflicts. Each
# violating branch also costs a full CI run to discover, so the check is cheap,
# local and identical in CI and at the desk:
#
#   scripts/maintenance/check-pr-freshness.sh                       # HEAD vs origin/main
#   scripts/maintenance/check-pr-freshness.sh --base origin/main --head HEAD
#
# Under GitHub Actions it reads the pull request's base SHA from BASE_SHA and
# writes annotations, so a failure is readable from the checks API rather than
# only from the log.
#
# Exit status: 0 clean, 1 rule violation, 2 the question cannot be answered
# (shallow clone, unknown ref) - never a silent pass.
set -euo pipefail

base_ref=origin/main
head_ref=HEAD

usage() {
  sed -n '5,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) base_ref="${2:?--base needs a value}"; shift 2 ;;
    --head) head_ref="${2:?--head needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'check-pr-freshness: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

in_actions=false
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  in_actions=true
fi

# The base SHA of a pull request is immutable and is what the merge-base test
# has to be measured against; a branch name moves under a running job.
if [ -n "${BASE_SHA:-}" ]; then
  base_ref="$BASE_SHA"
fi
if [ -n "${HEAD_SHA:-}" ]; then
  head_ref="$HEAD_SHA"
fi

annotate() { # level message
  if [ "$in_actions" = true ]; then
    printf '::%s title=Branch freshness::%s\n' "$1" "$2"
  fi
}

die_cannot_check() {
  printf 'check-pr-freshness: %s\n' "$1" >&2
  annotate error "cannot evaluate branch freshness: $1"
  exit 2
}

git rev-parse --git-dir >/dev/null 2>&1 || die_cannot_check "not inside a git repository"

# A shallow clone has no merge base to speak of: it would report the graft
# point as the base and pass every branch. Refuse instead of passing.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  die_cannot_check "shallow clone; check out with fetch-depth: 0 (or run git fetch --unshallow)"
fi

git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null \
  || die_cannot_check "base ref $base_ref does not exist"
git rev-parse --verify --quiet "$head_ref^{commit}" >/dev/null \
  || die_cannot_check "head ref $head_ref does not exist"

base_tip="$(git rev-parse "$base_ref^{commit}")"
head_tip="$(git rev-parse "$head_ref^{commit}")"
short_base="${base_tip:0:8}"
short_head="${head_tip:0:8}"

merge_base="$(git merge-base "$base_tip" "$head_tip" || true)"
if [ -z "$merge_base" ]; then
  printf 'check-pr-freshness: %s shares no history with %s\n' "$short_head" "$short_base" >&2
  annotate error "the branch shares no history with the base; it cannot be merged without replaying its commits"
  exit 1
fi

failures=0
behind="$(git rev-list --count "$head_tip..$base_tip")"

if [ "$merge_base" != "$base_tip" ]; then
  failures=$((failures + 1))
  printf 'check-pr-freshness: branch is %s commit(s) behind %s (merge base %s)\n' \
    "$behind" "$short_base" "${merge_base:0:8}" >&2
  annotate error "branch is $behind commit(s) behind the base ($short_base); rebase onto the base instead of merging it forward (CONTRIBUTING.md rule 1)"
else
  printf 'ok - branch starts at the base tip %s\n' "$short_base"
fi

merge_commits="$(git rev-list --merges --count "$merge_base..$head_tip" || true)"
if [ "${merge_commits:-0}" -gt 0 ]; then
  failures=$((failures + 1))
  printf 'check-pr-freshness: %s merge commit(s) in the branch:\n' "$merge_commits" >&2
  git rev-list --merges --format='  %h %s' "$merge_base..$head_tip" | grep -v '^commit ' >&2 || true
  annotate error "$merge_commits merge commit(s) in the branch; rebase so the branch replays linearly (CONTRIBUTING.md rule 2)"
else
  printf 'ok - no merge commits in the branch\n'
fi

if [ "$failures" -gt 0 ]; then
  printf 'check-pr-freshness: %d rule violation(s)\n' "$failures" >&2
  exit 1
fi

printf 'check-pr-freshness: OK\n'
exit 0
