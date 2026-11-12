#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# The syntax gate must be able to fail: an unparsable tracked file exits 1, a
# clean tree exits 0. A gate that prints a failure and exits 0 is a hole.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/check-julia-syntax.jl"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q
printf 'x = 1\n' > ok.jl
git add . 
julia --startup-file=no "$script" > /dev/null 2>&1 || { echo 'ERROR: a clean tree failed the gate' >&2; exit 1; }
printf 'y = 1 &&\n' > bad.jl
git add bad.jl
if julia --startup-file=no "$script" > /dev/null 2>&1; then
  echo 'ERROR: an unparsable file passed the gate' >&2; exit 1
fi
printf 'function f()\n' > bad.jl
if julia --startup-file=no "$script" > /dev/null 2>&1; then
  echo 'ERROR: an unterminated block passed the gate' >&2; exit 1
fi
echo 'check-julia-syntax: planted-negative and clean controls PASS'
