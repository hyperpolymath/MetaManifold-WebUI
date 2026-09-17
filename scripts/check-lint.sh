#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-lint.sh — lint gate for this repository.
#
# Lint means language-native semantic checking (the estate mandates no
# opinionated TS linter; TypeScript is fork-exempt under LANGUAGE-POLICY,
# and this fork's semantic linter IS the strict compiler):
#
#   1. bun x tsc --noEmit   (semantic analysis over frontend/src; strict +
#      exactOptionalPropertyTypes + noUncheckedIndexedAccess)
#   2. bash -n              (syntax validation for every tracked *.sh)
#   3. shellcheck           (advisory-only when available on the host;
#                            WARN output, never gates)
#
# Julia syntax is exercised by the Julia runtime/tests in the application
# lanes (this stage does not require a Julia install).
set -u
cd "$(dirname "$0")/.."
fail=0

# bun discovery: PATH first, then the default install location.
command -v bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"
command -v bun >/dev/null 2>&1 || { printf '%s\n' 'check-lint: bun not found' >&2; exit 1; }

printf '%s\n' '[1/3] tsc --noEmit (frontend)'
( cd frontend && bun x tsc --noEmit ) || fail=1

printf '%s\n' '[2/3] bash -n on tracked shell scripts'
mapfile -t scripts < <(git ls-files -- '*.sh')
for f in "${scripts[@]}"; do
  bash -n "$f" || { printf 'BASH-SYNTAX  %s\n' "$f" >&2; fail=1; }
done
bash -n .githooks/commit-msg 2>/dev/null || true

if command -v shellcheck >/dev/null 2>&1; then
  printf '%s\n' '[3/3] shellcheck (advisory)'
  shellcheck -S warning "${scripts[@]}" || printf '%s\n' 'shellcheck: advisory findings (non-gating)' >&2
else
  printf '%s\n' '[3/3] shellcheck not installed — skipping (install for advisory mode)'
fi

[ "$fail" -eq 0 ] && printf 'check-lint: OK\n' || printf 'check-lint: FAILED\n' >&2
exit "$fail"
