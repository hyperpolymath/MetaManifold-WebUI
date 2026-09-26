#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# make-stacks.sh — split parent PR #7 (feat/stipple-typed-studies-ui) into
# reviewable stacked patches.
#
# Reads stacks/*.paths (one git pathspec per line; disjoint file sets whose
# union is the whole upstream/main..branch diff) and writes one
# patches/<stack>.patch per stack, then verifies:
#   1. the stacks are disjoint and jointly cover all 319 files, and
#   2. applying every stack in order onto upstream/main reproduces the branch
#      tree byte-for-byte (empty final diff).
#
# Usage (from the repository root):
#   docs/triage/pr7-split/make-stacks.sh
#
# Env overrides (the defaults name the refs this kit was built against):
#   UPSTREAM_REF   base of parent PR #7 (default: refs/remotes/upstream/main)
#   BRANCH_REF     head of feat/stipple-typed-studies-ui (default: eab8ea0...)
#
# To point the kit at live refs on your own machine:
#   git fetch https://github.com/JoshuaJewell/MetaManifold-WebUI.git \
#     main:refs/remotes/upstream/main
#   git fetch https://github.com/hyperpolymath/MetaManifold-WebUI.git \
#     feat/stipple-typed-studies-ui
#   UPSTREAM_REF=refs/remotes/upstream/main \
#     BRANCH_REF=FETCH_HEAD docs/triage/pr7-split/make-stacks.sh
set -eu
cd "$(dirname "$0")"
HERE="$(pwd)"

UPSTREAM_REF="${UPSTREAM_REF:-refs/remotes/upstream/main}"
BRANCH_REF="${BRANCH_REF:-eab8ea09834a90547d29ea3ba5730281313a3ba1}"

for ref in "$UPSTREAM_REF" "$BRANCH_REF"; do
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || { echo "make-stacks: ref not found: $ref" >&2; exit 1; }
done

mkdir -p patches
rm -f patches/*.patch

echo "kit dir: $HERE"
echo "base: $UPSTREAM_REF ($(git rev-parse --short "$UPSTREAM_REF"))"
echo "head: $BRANCH_REF ($(git rev-parse --short "$BRANCH_REF"))"
echo

: > /tmp/stacks_union.txt
fail=0
for spec in stacks/*.paths; do
  name="$(basename "$spec" .paths)"
  mapfile -t paths < "$spec"
  # Anchor every pathspec at the repo root (":/") so this script works no
  # matter which directory it runs from; drop blank lines defensively.
  filtered=()
  for p in "${paths[@]}"; do [ -n "$p" ] && filtered+=(":/$p"); done
  git diff --binary "$UPSTREAM_REF" "$BRANCH_REF" -- "${filtered[@]}" \
    > "patches/$name.patch"
  git diff --name-only "$UPSTREAM_REF" "$BRANCH_REF" -- "${filtered[@]}" \
    > /tmp/stacks_names.txt
  cat /tmp/stacks_names.txt >> /tmp/stacks_union.txt
  n=$(wc -l < /tmp/stacks_names.txt)
  stat=$(git diff --numstat "$UPSTREAM_REF" "$BRANCH_REF" -- "${filtered[@]}" \
    | awk '$1 != "-" {a+=$1; d+=$2} END {printf "+%d/-%d", a, d}')
  printf '%-24s %3s files  %s\n' "$name" "$n" "$stat"
done

echo
echo "--- coverage check ---"
total=$(git diff --name-only "$UPSTREAM_REF" "$BRANCH_REF" | sort > /tmp/stacks_full.txt; wc -l < /tmp/stacks_full.txt)
sort /tmp/stacks_union.txt | uniq -d > /tmp/stacks_dupes.txt
sort -u /tmp/stacks_union.txt > /tmp/stacks_union_sorted.txt
if [ -s /tmp/stacks_dupes.txt ]; then
  echo "OVERLAP between stacks:"; cat /tmp/stacks_dupes.txt; fail=1
fi
if ! cmp -s /tmp/stacks_full.txt /tmp/stacks_union_sorted.txt; then
  echo "COVERAGE MISMATCH:"; comm -3 /tmp/stacks_full.txt /tmp/stacks_union_sorted.txt; fail=1
fi
[ "$fail" -eq 0 ] && echo "OK: all stacks, disjoint, cover all $total files."

echo
echo "--- sequential-apply check (temp worktree, deleted afterwards) ---"
tmp="$(mktemp -d)"
git worktree add --detach "$tmp" "$UPSTREAM_REF" >/dev/null 2>&1
# shellcheck disable=SC2064
trap "git worktree remove --force '$tmp'" EXIT
i=0
for spec in stacks/*.paths; do
  name="$(basename "$spec" .paths)"
  i=$((i + 1))
  git -C "$tmp" apply --check "$HERE/patches/$name.patch" \
    || { echo "APPLY-CHECK FAILED: $name" >&2; fail=1; break; }
  git -C "$tmp" apply --index "$HERE/patches/$name.patch"
  git -C "$tmp" -c user.name=triage -c user.email=triage@local \
    -c commit.gpgsign=false commit -qm "stack $name" --no-verify
done
if [ "$fail" -eq 0 ]; then
  if [ "$(git -C "$tmp" rev-parse 'HEAD^{tree}')" = "$(git rev-parse "$BRANCH_REF^{tree}")" ]; then
    echo "OK: stacks applied in order reproduce the branch tree exactly."
  else
    echo "TREE MISMATCH after applying all stacks:" >&2
    git -C "$tmp" diff --stat HEAD "$BRANCH_REF" | tail -n 5 >&2; fail=1
  fi
fi

exit "$fail"
