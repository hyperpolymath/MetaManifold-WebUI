#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Both pass and planted-fail controls for the diff-based ban.
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/check-no-new-python.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q
git config user.name 'Language Gate Test'
git config user.email 'language-gate@example.invalid'
mkdir -p bench scripts
printf 'print("legacy")\n' > scripts/legacy.py
git add . && git commit -qm 'Pre-existing Python debt'
base=$(git rev-parse HEAD)
expect_failure() {
  if bash "$script" "$base" > "$scratch/output.log" 2>&1; then
    echo 'ERROR: planted Python violation passed' >&2; exit 1
  fi
  grep -q 'BANNED Python contribution:' "$scratch/output.log" || { cat "$scratch/output.log" >&2; exit 1; }
}
expect_pass() { bash "$script" "$base" > /dev/null; }
printf 'cat("R allowed")\n' > bench/check.R
git add . && git commit -qm 'Add R'
expect_pass
printf 'print("new")\n' > bench/new.py
git add . && git commit -qm 'Add Python'
expect_failure
git rm -q bench/new.py && git commit -qm 'Remove Python'
expect_pass
printf 'print("changed")\n' >> scripts/legacy.py
git add . && git commit -qm 'Edit legacy Python'
expect_failure
git restore --source="$base" scripts/legacy.py
git add . && git commit -qm 'Restore legacy'
expect_pass
printf '[project]\nname = "wrong"\n' > pyproject.toml
git add . && git commit -qm 'Add Python manifest'
expect_failure
git rm -q pyproject.toml && git commit -qm 'Remove manifest'
expect_pass
git rm -q scripts/legacy.py && git commit -qm 'Retire Python'
expect_pass
if bash "$script" not-a-sha >/dev/null 2>&1; then echo 'Malformed base passed' >&2; exit 1; fi
if bash "$script" 0000000000000000000000000000000000000000 >/dev/null 2>&1; then echo 'Missing base passed' >&2; exit 1; fi
echo 'no-new-python gate: planted-positive and planted-negative fixtures PASS'
