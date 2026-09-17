#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-spdx.sh — licence-header gate.
#
# Verifies that every covered source file carries an
# SPDX-License-Identifier comment in its first five lines, and that the
# identifier is one of the policy-allowed set for this repository:
#
#   AGPL-3.0-only   upstream-authored files (inherit LICENSE; see NOTICE)
#   MPL-2.0         fork-authored code / config / scripts (Rule 3a)
#   CC-BY-SA-4.0    fork-authored prose documentation
#
# Excluded by design (machine metadata, no comment syntax, or data files):
#   *.json *.toml *.lock renv.lock Manifest.toml CITATION.cff *.a2ml
#   .gitignore .bun-version .gitmessage LICENSE* files themselves, plus
#   CSS/HTML entry files (style/entry metadata) and web/* build artefacts.
set -u
cd "$(dirname "$0")/.."
fail=0

mapfile -t files < <(git ls-files \
  -- '*.ts' '*.tsx' '*.jl' '*.R' '*.sh' '*.yml' '*.yaml' '*.md' \
  ':!LICENSES/**' ':!node_modules/**' ':!frontend/dist/**' ':!web/**'
)

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  head5=$(head -5 "$f")
  if ! printf '%s' "$head5" | grep -q 'SPDX-License-Identifier:'; then
    printf 'MISSING-SPDX  %s\n' "$f" >&2; fail=1; continue
  fi
  id=$(printf '%s' "$head5" | sed -n 's/.*SPDX-License-Identifier:\s\{0,1\}\([A-Za-z0-9.-]\{1,\}\).*/\1/p' | head -1)
  case "$id" in
    AGPL-3.0-only|MPL-2.0|CC-BY-SA-4.0)
      ;;
    *)
      printf 'BAD-IDENTIFIER (%s)  %s\n' "$id" "$f" >&2; fail=1; continue
      ;;
  esac
  # A file must not stack two identifiers (ambiguous relicensing smell).
  if [ "$(printf '%s' "$head5" | grep -c 'SPDX-License-Identifier:')" -gt 1 ]; then
    printf 'DUPLICATE-SPDX  %s\n' "$f" >&2; fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  printf 'check-spdx: OK (%d files covered)\n' "${#files[@]}"
else
  printf 'check-spdx: FAILED\n' >&2
fi
exit "$fail"
