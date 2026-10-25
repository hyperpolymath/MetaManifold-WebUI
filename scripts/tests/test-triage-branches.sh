#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Tests for scripts/maintenance/triage-branches.sh, including the cases a
# real repository produces: a merged branch, a drifted branch that adds
# nothing, a drifted branch that carries a file the base dropped, an orphan
# data branch, and the shallow clone where no answer is possible.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/maintenance/triage-branches.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok %d - %s\n' "$pass" "$1"; }
no() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
check_contains() { # haystack needle description
  if printf '%s' "$1" | grep -Fq -- "$2"; then ok "$3"; else no "$3 (missing: $2)"; fi
}

git init -q --bare "$work/origin.git"
git init -q "$work/repo"
cd "$work/repo"
git symbolic-ref HEAD refs/heads/main
printf 'a\n' > base.txt
git add base.txt
git commit -qm 'base: add base.txt'
printf 'b\n' > dropped.txt
git add dropped.txt
git commit -qm 'base: add dropped.txt'
git branch -m main

# salvage: branched before the base moved, adds a file the base never has
git checkout -q main~1
git checkout -qb salvage
printf 's\n' > salvage.txt
git add salvage.txt
git commit -qm 'salvage: add salvage.txt'

# stale: branched before the base moved, only touches a file the base has
git checkout -q main~1
git checkout -qb stale
printf 'a changed on the branch\n' > base.txt
git commit -qam 'stale: edit base.txt'

# contained: fully merged into main, then main moves on without it
git checkout -q main
git checkout -qb merged-branch
printf 'm\n' > merged.txt
git add merged.txt
git commit -qm 'merged: add merged.txt'
git checkout -q main
git merge -q --ff-only merged-branch
git branch -m merged-branch contained
printf 'd\n' > later.txt
git add later.txt
git commit -qm 'base: add later.txt'

# fresh: branched at the base tip, one commit ahead
git checkout -qb fresh
printf 'c\n' > fresh.txt
git add fresh.txt
git commit -qm 'fresh: add fresh.txt'

# unrelated: an orphan data branch, as the badge publisher creates
git checkout -q --orphan governance-badges
git rm -rqf .
printf '{ "schemaVersion": 1 }\n' > deed.json
git add deed.json
git commit -qm 'badges: endpoint json'

git checkout -q main
git remote add origin "$work/origin.git"
git push -q origin main fresh salvage stale contained governance-badges
# The bare repository's HEAD is still on an unborn `master`, so `git clone`
# would call it empty; point it at main, as a real default branch would be.
git -C "$work/origin.git" symbolic-ref HEAD refs/heads/main
git fetch -q origin

out="$(bash "$SCRIPT" --base main --remote origin)"
rows="$(printf '%s\n' "$out" | grep -E 'origin/|^[a-z]' || true)"
check_contains "$out" 'fresh' 'a branch at the base tip appears'
if printf '%s\n' "$out" | grep -Eq '^fresh +fresh '; then ok 'a branch at the base tip is classed fresh'; else no "fresh branch class: $out"; fi
if printf '%s\n' "$out" | grep -Eq '^salvage +salvage '; then ok 'a drifted branch with an unknown file is classed salvage'; else no "salvage class: $out"; fi
if printf '%s\n' "$out" | grep -Eq '^stale +stale '; then ok 'a drifted branch that adds nothing is classed stale'; else no "stale class: $out"; fi
if printf '%s\n' "$out" | grep -Eq '^contained +contained '; then ok 'a fully merged branch is classed contained'; else no "contained class: $out"; fi
if printf '%s\n' "$out" | grep -Eq '^governance-badges +unrelated '; then ok 'an orphan branch is classed unrelated'; else no "unrelated class: $out"; fi

markdown="$(bash "$SCRIPT" --base main --remote origin --format markdown)"
check_contains "$markdown" '| `salvage` | salvage |' 'the markdown table carries the class'
check_contains "$markdown" 'salvage (holds files the base lacks)' 'the markdown summary explains salvage'

set +e
bash "$SCRIPT" --base main --remote origin --fail-on stale >/dev/null 2>&1
status=$?
set -e
if [ "$status" -eq 3 ]; then ok '--fail-on stale exits 3 when a stale branch exists'; else no "--fail-on stale exited $status"; fi

set +e
bash "$SCRIPT" --base main --remote origin --fail-on salvage >/dev/null 2>&1
status=$?
set -e
if [ "$status" -eq 3 ]; then ok '--fail-on salvage exits 3 when a salvage branch exists'; else no "--fail-on salvage exited $status"; fi

json="$(bash "$SCRIPT" --base main --remote origin --format json)"
if printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["base"]=="main"; assert {b["class"] for b in d["branches"]} >= {"stale","salvage","contained","unrelated","fresh"}' 2>/dev/null; then
  ok '--format json emits the documented classes as valid JSON'
else
  no "--format json output: $json"
fi

# A shallow clone cannot answer the question, so it must not answer at all.
git clone -q --depth 1 --branch main "file://$work/origin.git" "$work/shallow"
set +e
shallow_out="$(cd "$work/shallow" && bash "$SCRIPT" --base main --remote origin 2>&1)"
status=$?
set -e
if [ "$status" -eq 2 ]; then ok 'a shallow clone is refused with exit 2'; else no "shallow clone exited $status: $shallow_out"; fi
check_contains "$shallow_out" 'shallow clone' 'the refusal names the cause'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
