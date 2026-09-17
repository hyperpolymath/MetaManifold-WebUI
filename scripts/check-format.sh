#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# check-format.sh — formatting gate enforcing the estate .editorconfig and
# .gitattributes on tracked text files:
#   * LF line endings              (exceptions per .editorconfig: *.bat/*.cmd/*.ps1)
#   * no trailing whitespace       (exception: prose .md/.adoc, where it is
#                                   semantically significant)
#   * final newline present
#   * no tab indentation in *.ts/*.tsx (2-space estate style)
#
# Excluded: research data, generated/build artefacts, lockfiles, test
# fixtures (byte-fidelity capture), binary-ish extensions, and .gitmessage
# (estate-canonical template; its ruler comments carry trailing spaces by
# design upstream, so the file is exempt from the ws rule).
set -u
cd "$(dirname "$0")/.."
fail=0
checked=0

mapfile -t files < <(git ls-files)
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    LICENSES/*|node_modules/*|dist/*|web/*|data/*|renv.lock|frontend/bun.lock|Manifest.toml|    test/fixtures/*|frontend/tests/fixtures/*|frontend/bench/baseline.json|*.patch|*.png|*.jpg|*.jpeg|    *.ico|*.gz|*.zip|*.rds|*.duckdb|*.woff*|*.eot|*.ttf|*.min.js|*.pdf) continue ;;
  esac
  checked=$((checked+1))
  case "$f" in *.bat|*.cmd|*.ps1|.gitmessage) continue ;; esac
  if LC_ALL=C grep -q $'\r' "$f" 2>/dev/null; then
    printf 'CRLF            %s\n' "$f" >&2; fail=1
  fi
  if [ -s "$f" ] && [ "$(tail -c1 "$f" | wc -l)" -eq 0 ]; then
    printf 'NO-FINAL-EOF    %s\n' "$f" >&2; fail=1
  fi
  case "$f" in *.md|*.adoc) ;; *)
    if grep -nE ' +$' "$f" >/dev/null 2>&1; then
      printf 'TRAILING-WS     %s\n' "$f" >&2; fail=1
    fi ;;
  esac
  case "$f" in *.ts|*.tsx|*.d.ts)
    if grep -nP '^\t' "$f" >/dev/null 2>&1; then
      printf 'TAB-INDENT      %s\n' "$f" >&2; fail=1
    fi ;;
  esac
done

if [ "$fail" -eq 0 ]; then
  printf 'check-format: OK (%d files checked)\n' "$checked"
else
  printf 'check-format: FAILED\n' >&2
fi
exit "$fail"
