#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Tests for scripts/maintenance/check-pr-freshness.sh: the two CONTRIBUTING
# rules it enforces, plus the cases where it must refuse to answer rather than
# pass a branch it cannot judge.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/maintenance/check-pr-freshness.sh"
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
run() { # expected-status description -- args...
  local want="$1" desc="$2"
  shift 2
  set +e
  out="$(cd "$work/repo" && bash "$SCRIPT" "$@" 2>&1)"
  local status=$?
  set -e
  if [ "$status" -eq "$want" ]; then ok "$desc"; else no "$desc (exit $status, wanted $want): $out"; fi
}

git init -q --bare "$work/origin.git"
git init -q "$work/repo"
cd "$work/repo"
git symbolic-ref HEAD refs/heads/main
printf 'a\n' > a.txt
git add a.txt
git commit -qm 'add a.txt'
git remote add origin "$work/origin.git"
git push -q origin main
git -C "$work/origin.git" symbolic-ref HEAD refs/heads/main
git fetch -q origin

# clean: new branch at the base tip
git checkout -qb clean
printf 'b\n' > b.txt
git add b.txt
git commit -qm 'add b.txt'
run 0 'a branch at the base tip passes' --base origin/main

# drifted: one commit behind the base, no merge commit
git checkout -q main
printf 'c\n' > c.txt
git add c.txt
git commit -qm 'advance main'
git push -q origin main
git fetch -q origin
run 1 'a branch behind the base fails' --base origin/main --head clean
check_contains "$out" 'commit(s) behind' 'the failure names how far behind the branch is'

# merge commit: the branch is at the base tip but carries a merge from it,
# which is the shape CONTRIBUTING rule 2 forbids even though rule 1 is satisfied
git checkout -q -b merges main
printf 'd\n' > d.txt
git add d.txt
git commit -qm 'add d.txt'
git checkout -q main
printf 'e\n' > e.txt
git add e.txt
git commit -qm 'advance main again'
git checkout -q merges
git merge -q --no-ff -m "Merge branch 'main' into merges" main
run 1 'a merge commit in the branch fails even at the base tip' --base origin/main --head merges
check_contains "$out" 'merge commit' 'the failure names the merge commit rule'
check_contains "$out" 'check out the pull request head commit' 'a merge-commit head also explains the refs/pull/<n>/merge case'

# unrelated history: an orphan branch cannot be merged, so it cannot pass
git checkout -q --orphan orphan
git rm -rqf .
printf 'x\n' > x.txt
git add x.txt
git commit -qm 'orphan root'
run 1 'an unrelated history fails' --base origin/main --head orphan

# a missing ref is a question that cannot be answered, not a pass
run 2 'an unknown head ref exits 2' --base origin/main --head nosuchbranch

# Actions annotations are emitted when GitHub asks for them
set +e
out="$(cd "$work/repo" && GITHUB_ACTIONS=true bash "$SCRIPT" --base origin/main --head clean 2>&1)"
status=$?
set -e
if [ "$status" -eq 1 ]; then ok 'the check still fails under Actions'; else no "Actions run exited $status"; fi
check_contains "$out" '::error title=Branch freshness::' 'a failure is written as a check annotation'

# A shallow clone would report its graft point as the merge base.
git clone -q --depth 1 --branch main "file://$work/origin.git" "$work/shallow"
set +e
shallow_out="$(cd "$work/shallow" && bash "$SCRIPT" --base origin/main --head origin/main 2>&1)"
shallow_status=$?
set -e
if [ "$shallow_status" -eq 2 ]; then ok 'a shallow clone is refused with exit 2'; else no "shallow clone exited $shallow_status: $shallow_out"; fi
check_contains "$shallow_out" 'shallow clone' 'the refusal names the cause'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
