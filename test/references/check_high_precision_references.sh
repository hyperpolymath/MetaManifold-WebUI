#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Reproduce the independent high-precision known answers used by the Julia tests.
#
# GNU bc shares no code with Julia (MPFR, GMP), which is the point: the answers
# come from a different arithmetic library. No result produced by the
# implementation is read here. The maths is in high_precision_references.bc.
#
# Usage:
#   check_high_precision_references.sh                       print the references as JSON
#   check_high_precision_references.sh --check TEST.jl       compare the constants in TEST.jl
#   check_high_precision_references.sh TEST.jl               same as --check
# Exit: 0 agree, 1 a constant differs or is missing, 2 usage or tool error.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bc_source="$here/high_precision_references.bc"
PRECISION=460
names=(REF_LN2 REF_LN3 REF_TWO_THIRDS REF_H_1234)

command -v bc >/dev/null || { echo "bc is required (apt-get install bc)" >&2; exit 2; }

# Print the references at N significant digits, one "NAME text" line each.
references() {
  local n="$1" out name m e text
  out="$(printf 'n=%s\n' "$n" | cat - "$bc_source" | BC_LINE_LENGTH=0 bc -l)" || return 2
  for name in "${names[@]}"; do
    m="$(awk -v k="$name" '$1 == k { print $2 }' <<<"$out")"
    e="$(awk -v k="EX_${name#REF_}" '$1 == k { print $2 }' <<<"$out")"
    [[ "$m" =~ ^[0-9]+$ && "$e" =~ ^-?[0-9]+$ && ${#m} -eq $n ]] || { echo "bc gave no $name at $n digits" >&2; return 2; }
    if (( e < 0 )); then
      text="0.$(printf '%*s' $((-e - 1)) '' | tr ' ' 0)$m"
    elif (( e >= n - 1 )); then
      text="$m"
    else
      text="${m:0:e+1}.${m:e+1}"
    fi
    printf '%s %s\n' "$name" "$text"
  done
}

# Significant digits of a decimal string: drop the point and leading zeros.
significant_digits() {
  local d="${1/./}"
  d="${d#"${d%%[!0]*}"}"
  echo "${#d}"
}

check() {
  local file="$1" failures=0 name embedded n expected
  [[ -r "$file" ]] || { echo "cannot read $file" >&2; return 2; }
  for name in "${names[@]}"; do
    embedded="$(sed -n -E "s/^const $name = \"([^\"]+)\"\$/\\1/p" "$file" | head -n 1)"
    if [[ -z "$embedded" ]]; then
      echo "$name: constant not found" >&2; failures=1; continue
    fi
    # Each constant is verified at the precision actually embedded, so extra
    # correct digits are not rejected and a wrong digit is.
    n="$(significant_digits "$embedded")"
    expected="$(references "$n" | awk -v k="$name" '$1 == k { print $2 }')"
    if [[ "$embedded" != "$expected" ]]; then
      echo "$name: embedded reference differs from the bc reference" >&2; failures=1
    fi
  done
  if (( failures )); then return 1; fi
  echo "Independent decimal references agree at their embedded precisions."
}

if (( $# == 0 )); then
  refs="$(references "$PRECISION")"
  printf '{\n  "decimal_precision": %s,\n  "references": {\n' "$PRECISION"
  last="${names[${#names[@]}-1]}"
  for name in "${names[@]}"; do
    sep=","; [[ "$name" == "$last" ]] && sep=""
    printf '    "%s": "%s"%s\n' "$name" "$(awk -v k="$name" '$1 == k { print $2 }' <<<"$refs")" "$sep"
  done
  printf '  }\n}\n'
  exit 0
fi

case "$1" in
  --check) [[ $# -eq 2 ]] || { echo "--check requires the Julia test path" >&2; exit 2; }; check "$2" ;;
  -*) echo "usage: $0 [--check] [TEST.jl]" >&2; exit 2 ;;
  *) check "$1" ;;
esac
