#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The change classifier must fail closed: a diff that cannot be computed is an
# error, never "nothing relevant". Also a positive and a negative control.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/ci/classify-change.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q
git config user.name 'Classifier Test'
git config user.email 'classifier@example.invalid'
mkdir src
echo base > README.md
git add . && git commit -qm base
base="$(git rev-parse HEAD)"

run() { BASE_SHA="$1" GITHUB_OUTPUT="$scratch/out" bash "$script" 'src/*' 'Project.toml'; }
: > out

# A diff that cannot be computed must exit non-zero and write no verdict.
if BASE_SHA=not-a-commit GITHUB_OUTPUT="$scratch/out" bash "$script" 'src/*' > /dev/null 2>&1; then
  echo 'ERROR: a failed diff exited zero' >&2; exit 1
fi
if BASE_SHA=0000000000000000000000000000000000000000 GITHUB_OUTPUT="$scratch/out" bash "$script" 'src/*' > /dev/null 2>&1; then
  echo 'ERROR: a missing base commit exited zero' >&2; exit 1
fi
[[ ! -s out ]] || { echo 'ERROR: a failed diff still wrote a verdict' >&2; cat out >&2; exit 1; }

# No patterns, or no base, is a usage error, not a verdict.
if BASE_SHA="$base" bash "$script" > /dev/null 2>&1; then echo 'ERROR: no patterns exited zero' >&2; exit 1; fi
if env -u BASE_SHA bash "$script" 'src/*' > /dev/null 2>&1; then echo 'ERROR: no base exited zero' >&2; exit 1; fi

# Controls: an unrelated change is not relevant, a listed one is, a rename out
# of a listed path counts, and --patterns-file gives the same answer.
echo docs > NOTES.md && git add . && git commit -qm docs
: > out; run "$base"; [[ "$(cat out)" == relevant=false ]] || { echo 'ERROR: unrelated change was relevant' >&2; exit 1; }
echo x > src/a.jl && git add . && git commit -qm src
: > out; run "$base"; [[ "$(cat out)" == relevant=true ]] || { echo 'ERROR: listed change was not relevant' >&2; exit 1; }
printf '# comment\n\nsrc/*\n' > patterns.txt
: > out; BASE_SHA="$base" GITHUB_OUTPUT="$scratch/out" bash "$script" --patterns-file patterns.txt
[[ "$(cat out)" == relevant=true ]] || { echo 'ERROR: patterns file disagreed' >&2; exit 1; }
git reset -q --hard "$base"
mkdir -p src && echo y > src/b.jl && git add . && git commit -qm add
sub="$(git rev-parse HEAD)"
git mv src/b.jl elsewhere.jl && git commit -qm rename
: > out; BASE_SHA="$base" GITHUB_OUTPUT="$scratch/out" bash "$script" 'src/*'
[[ "$(cat out)" == relevant=false ]] || { echo 'ERROR: add then move back out was relevant' >&2; exit 1; }
: > out; BASE_SHA="$sub" GITHUB_OUTPUT="$scratch/out" bash "$script" 'src/*'
[[ "$(cat out)" == relevant=true ]] || { echo 'ERROR: rename out of a listed path was not relevant' >&2; exit 1; }
echo 'classify-change: fail-closed and classification controls PASS'
