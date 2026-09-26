#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# check-proofs.sh — the Agda proof gate (docs/formal/verification-plan.md).
#
#   1. guard   : no postulate / termination or positivity escape hatches /
#                holes / unsafe flags in proofs/agda (comments ignored), and
#                every module outside reject/ opens with
#                {-# OPTIONS --safe --without-K #-}
#   2. check   : proofs/agda/MetaManifold/All.agda type-checks
#   3. reject  : every proofs/agda/reject/*.agda FAILS to type-check, with an
#                error matching its "-- EXPECT: <regex>" line. A negative
#                control that fails for some other reason (a parse error, a
#                missing import) proves nothing, so the reason is checked.
#
# Toolchain pin (the estate's, see epistemic-types): Agda 2.6.4.3 with
# agda-stdlib 2.1. Overrides:
#   AGDA=/path/to/agda
#   AGDA_STDLIB_LIB=/path/to/standard-library.agda-lib
set -u
cd "$(dirname "$0")/.."
root=$(pwd)
proofs="$root/proofs/agda"
AGDA=${AGDA:-agda}
fail=0

if [ -z "${AGDA_STDLIB_LIB:-}" ]; then
  for cand in /usr/share/agda-stdlib/standard-library.agda-lib \
              /usr/share/agda/lib/stdlib/standard-library.agda-lib; do
    [ -f "$cand" ] && AGDA_STDLIB_LIB=$cand && break
  done
fi
if [ -z "${AGDA_STDLIB_LIB:-}" ] || [ ! -f "$AGDA_STDLIB_LIB" ]; then
  printf 'check-proofs: standard library not found; set AGDA_STDLIB_LIB\n' >&2
  exit 2
fi
command -v "$AGDA" >/dev/null 2>&1 || { printf 'check-proofs: %s not found\n' "$AGDA" >&2; exit 2; }

version=$("$AGDA" --numeric-version 2>/dev/null || true)
printf 'check-proofs: Agda %s, stdlib %s\n' "$version" "$AGDA_STDLIB_LIB"
case "$version" in
  2.6.4.3*) ;;
  *) printf 'check-proofs: WARNING: expected Agda 2.6.4.3 (estate pin), got %s\n' "$version" >&2 ;;
esac

# A private library registry: only the stdlib and this suite are visible.
agda_dir=$(mktemp -d)
trap 'rm -rf "$agda_dir"' EXIT
printf '%s\n%s\n' "$AGDA_STDLIB_LIB" "$proofs/metamanifold-proofs.agda-lib" > "$agda_dir/libraries"
export AGDA_DIR="$agda_dir"

# ---------------------------------------------------------------- 1. guard
printf '%s\n' '[1/3] guard'
mapfile -t modules < <(cd "$proofs" && find MetaManifold -name '*.agda' | sort)
if [ "${#modules[@]}" -eq 0 ]; then
  printf 'check-proofs: no modules found under %s\n' "$proofs" >&2; exit 1
fi
forbidden='postulate|TERMINATING|NON_TERMINATING|NO_POSITIVITY_CHECK|NO_UNIVERSE_CHECK|NON_COVERING|INJECTIVE|trustMe|--type-in-type|--allow-unsolved-metas|--allow-incomplete-matches|--no-positivity-check|--no-termination-check|--cumulativity|--sized-types|--guardedness|--rewriting|\{!|(^|[[:space:](])\?([[:space:])]|$)'
for m in "${modules[@]}"; do
  # Strip line comments (-- to end of line) and block comments on one line.
  code=$(sed -e 's/{-[^#].*-}//g' -e 's/--.*$//' "$proofs/$m")
  if hits=$(printf '%s\n' "$code" | grep -nE "$forbidden"); then
    printf 'FORBIDDEN  %s\n%s\n' "$m" "$hits" >&2; fail=1
  fi
  if ! grep -qE '^\{-# OPTIONS --safe --without-K #-\}' "$proofs/$m"; then
    printf 'MISSING-SAFE-PRAGMA  %s\n' "$m" >&2; fail=1
  fi
done
printf '  %d modules scanned\n' "${#modules[@]}"

# ---------------------------------------------------------------- 2. check
printf '%s\n' '[2/3] type-check MetaManifold/All.agda'
# Fresh interfaces for this suite (the stdlib's may be reused).
rm -rf "$proofs/_build"
if ! (cd "$proofs" && "$AGDA" MetaManifold/All.agda > "$agda_dir/check.log" 2>&1); then
  grep -v '^ *Checking ' "$agda_dir/check.log" >&2
  printf 'check-proofs: type-check FAILED\n' >&2
  fail=1
else
  # Every module under MetaManifold/ must be reachable from All.agda, or it
  # is not being checked at all.
  unreachable=0
  for m in "${modules[@]}"; do
    mod=${m%.agda}; mod=${mod//\//.}
    [ "$mod" = MetaManifold.All ] && continue
    if ! grep -q "^import $mod\$" "$proofs/MetaManifold/All.agda"; then
      printf 'NOT-IN-ALL  %s\n' "$mod" >&2; unreachable=1; fail=1
    fi
  done
  [ "$unreachable" -eq 0 ] && printf '  OK\n'
fi

# ---------------------------------------------------------------- 3. reject
printf '%s\n' '[3/3] negative controls (must fail, for the stated reason)'
mapfile -t rejects < <(cd "$proofs" && find reject -name '*.agda' | sort)
if [ "${#rejects[@]}" -eq 0 ]; then
  printf 'check-proofs: no negative controls found\n' >&2; fail=1
fi
for r in "${rejects[@]}"; do
  expect=$(sed -n 's/^-- EXPECT: //p' "$proofs/$r" | head -1)
  if [ -z "$expect" ]; then
    printf 'NO-EXPECT  %s\n' "$r" >&2; fail=1; continue
  fi
  if (cd "$proofs" && "$AGDA" "$r" > "$agda_dir/reject.log" 2>&1); then
    printf 'ACCEPTED (must be rejected)  %s\n' "$r" >&2; fail=1
  elif grep -v '^ *Checking ' "$agda_dir/reject.log" | grep -qE -- "$expect"; then
    printf '  rejected as expected  %s\n' "$r"
  else
    printf 'REJECTED FOR THE WRONG REASON  %s (expected /%s/)\n' "$r" "$expect" >&2
    grep -v '^ *Checking ' "$agda_dir/reject.log" | head -8 >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  printf 'check-proofs: OK\n'
else
  printf 'check-proofs: FAILED\n' >&2
fi
exit "$fail"
