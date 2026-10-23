#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The repository's required "SonarCloud Code Analysis" check is the SonarQube
# Cloud GitHub App running AUTOMATIC ANALYSIS: no scanner workflow here, no
# sonar-project.properties, and therefore no file in this repository that
# configures it. Its quality gate ("Sonar way", with the coverage condition
# dropped) requires, on NEW code:
#
#     reliability rating <= A        (worst BUG on new code)
#     security rating    <= A        (worst VULNERABILITY on new code)
#     maintainability    <= A        (technical-debt ratio, < 5% is A)
#     duplication        <= 3%
#     hotspots reviewed  == 100%
#
# Reliability and security are rated on the WORST bug/vulnerability in the
# changed lines (MINOR -> B, MAJOR -> C, CRITICAL -> D, BLOCKER -> E), so a
# single bug fails it whatever its severity. Maintainability is a debt ratio,
# and a couple of code smells is usually still A: measured on PR #233, two
# MAJOR smells and 10 minutes of debt left the rating at A and the gate green.
# So the gate is failed by one bug, not by untidiness -- that is why a pull
# request touching ordinary TypeScript can go red for something a reviewer
# would call a style remark, and why the only warning used to arrive ~90
# seconds after a push, from a service the contributor cannot run.
#
# This script is the local, sub-second reproduction of the rule that failed
# this check and the one reported alongside it, so the finding arrives before
# the push. It is a guard, not a linter: it covers the rules that have bitten,
# and says so rather than implying it covers the gate.
#
#   S2871  "Array.prototype.sort() and toSorted() should use a compare function"
#          CRITICAL, reliability HIGH. Fired on PR #224 line 53 of
#          frontend/src/api/ijsonJcs.ts, and still open twice on main in
#          frontend/src/views/CompositionsView.tsx.
#
#   S7758  "Prefer String#codePointAt() over String#charCodeAt()"
#          MINOR, but a CODE SMELL, so it does not move the reliability rating
#          and would not fail the gate alone. Fired twice on PR #224; kept here
#          so the repository's count stays at zero rather than accumulating
#          debt, and because the exception below is a decision worth making
#          explicitly.
#
# Fixing S2871 with the rule's own suggestion -- localeCompare -- is WRONG for
# this codebase, and silently so: localeCompare applies locale collation, so it
# reorders 'z' and 'ä'. Sorted identifier lists and RFC 8785 canonical JSON both
# need UTF-16 CODE UNIT order, which is what a bare sort() already gave. Pass
# frontend/src/utils/text.ts's byCodeUnit() instead: same ordering, explicit.
# Fixing S7758 is usually right (codePointAt handles surrogate pairs correctly),
# but not everywhere -- see CHARCODE_ALLOWED below.
#
# There is deliberately no waiver for S2871: a comparison-less sort is never
# what is wanted (strings want byCodeUnit, numbers want a subtraction, anything
# else wants a real comparator), and a waiver would have to suppress the finding
# in SonarCloud too, which // NOSONAR does at the price of typescript:S1291.
# S7758 has CHARCODE_ALLOWED, because there the rule is sometimes simply wrong.
#
# Run from anywhere:  bash scripts/lint-sonar-reliability.sh
# Exits 0 clean, 1 on findings, 2 when run outside the repository.
set -u -o pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null || { echo "lint-sonar-reliability: cannot enter the repository root" >&2; exit 2; }
if [[ ! -d frontend/src ]]; then
  echo "lint-sonar-reliability: run from the repository root" >&2
  exit 2
fi
export LC_ALL=C

failures=0

# GitHub renders an `::error` line as a check annotation, and an annotation can
# be read back through the API when the job log cannot be downloaded.
annotate() {  # file line title message
  [[ -n "${GITHUB_ACTIONS:-}" ]] || return 0
  printf '::error file=%s,line=%s,title=%s::%s\n' "$1" "$2" "$3" "${4//$'\n'/ }"
}

# Files where charCodeAt is the correct API and codePointAt would be a bug.
# Keep this list short and give each entry its reason: an entry is a reviewable
# decision, which is the point of not using // NOSONAR (suppressing a finding
# still leaves it counted, and typescript:S1291 "Track uses of NOSONAR" is
# itself a maintainability finding).
CHARCODE_ALLOWED=(
  "frontend/src/tree/model.ts"   # hashName: FNV-1a is defined over UTF-16 code units; codePointAt merges surrogate pairs and would change every tip key
)

char_code_allowed() {  # file
  local file="$1" f
  for f in "${CHARCODE_ALLOWED[@]}"; do
    [[ "$file" == "$f" ]] && return 0
  done
  return 1
}

# git ls-files, not find: only what the repository tracks is analysed by Sonar,
# and it keeps node_modules and build output out for free. Read with -d '' into
# an array by hand rather than through mapfile, which macOS's bash 3.2 lacks --
# there the script would otherwise report OK having looked at nothing.
sources=()
while IFS= read -r -d '' tracked; do sources+=("$tracked"); done \
  < <(git ls-files -z -- 'frontend/src/*.ts' 'frontend/src/*.tsx')

# --- S2871: a sort with no comparator -------------------------------------
# [[:space:]] spans newlines, so `arr.sort( )` counts; a call whose first
# argument starts on the next line does not, which is what we want.
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}
  echo "ERROR: S2871 comparison-less sort: $file:$line" >&2
  echo "       $(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')" >&2
  echo "       Pass frontend/src/utils/text.ts's byCodeUnit (code-unit order, unchanged" >&2
  echo "       behaviour) or an explicit comparator. Do not reach for localeCompare." >&2
  annotate "$file" "$line" "SonarCloud typescript:S2871" "Sort without a compare function fails the reliability gate on new code; pass byCodeUnit() from frontend/src/utils/text.ts"
  failures=$((failures + 1))
done < <( (( ${#sources[@]} )) && grep -HnE '\.(sort|toSorted)\([[:space:]]*\)' "${sources[@]}" || true )

# --- S7758: charCodeAt where codePointAt is wanted ------------------------
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}
  char_code_allowed "$file" && continue
  echo "ERROR: S7758 charCodeAt: $file:$line" >&2
  echo "       $(sed -n "${line}p" "$file" | sed 's/^[[:space:]]*//')" >&2
  echo "       Walk the string with codePointAt, which reads a surrogate pair as one" >&2
  echo "       code point. If the code really is defined over UTF-16 code units (a hash," >&2
  echo "       an encoder), add the file to CHARCODE_ALLOWED with its reason." >&2
  annotate "$file" "$line" "SonarCloud typescript:S7758" "charCodeAt on a changed line fails the reliability gate on new code; prefer codePointAt, or allowlist the file with a reason"
  failures=$((failures + 1))
done < <( (( ${#sources[@]} )) && grep -HnE '\.charCodeAt\(' "${sources[@]}" || true )

if (( failures > 0 )); then
  echo "lint-sonar-reliability: $failures finding(s). The quality gate needs reliability rating A on" >&2
  echo "new code, and rating A admits no findings -- see docs/sonar-quality-gate.md." >&2
  exit 1
fi

echo "lint-sonar-reliability: OK — no S2871 or S7758 findings in frontend/src"
