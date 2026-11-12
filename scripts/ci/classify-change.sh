#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Decide whether a pull request touches any path in a list of glob patterns.
#
# Used by both relevance gates in ci.yml, so the diff logic lives here once.
#
# Usage:
#   classify-change.sh [--changed-file FILE] [--patterns-file FILE] [PATTERN...]
#
# The base commit comes from BASE_SHA. The patterns are shell globs matched with
# `case`, so `src/*` also matches `src/a/b.jl`. Each pattern is an argument or a
# line of --patterns-file (blank lines and lines starting with # are ignored).
# Result: "relevant=true" or "relevant=false", appended to GITHUB_OUTPUT when it
# is set and printed otherwise.
#
# The diff goes to a file first because a process substitution hides git diff's
# exit status. An unavailable base commit (a force-push on the base branch, for
# instance) or a repository error would then read as "no changes" and post
# relevant=false, which skips the jobs a required check stands for, and a
# relevant change would pass silently. A failed diff fails this script, and so
# the gate itself: the one failure the required-check design cannot afford to
# skip.
#
# --no-renames, so a file renamed out of a listed path is reported as a deletion
# under its original name and still counts. -z with a NUL-delimited read, so a
# pathname git would quote, or that contains a newline, arrives raw and matches.
set -euo pipefail

changed="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/classify-change-files.$$"
patterns=()
trap 'rm -f "$changed"' EXIT

while (($#)); do
  case "$1" in
    --changed-file)
      changed="${2:?--changed-file needs a path}"; trap - EXIT; shift 2 ;;
    --patterns-file)
      file="${2:?--patterns-file needs a path}"
      [[ -r "$file" ]] || { echo "ERROR: cannot read patterns file $file" >&2; exit 2; }
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        patterns+=("$line")
      done < "$file"
      shift 2 ;;
    --) shift; patterns+=("$@"); break ;;
    -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) patterns+=("$1"); shift ;;
  esac
done

: "${BASE_SHA:?BASE_SHA must name the comparison commit}"
((${#patterns[@]})) || { echo "ERROR: no patterns given" >&2; exit 2; }

if ! git diff --no-renames --name-only -z "$BASE_SHA...HEAD" > "$changed"; then
  echo "ERROR: git diff $BASE_SHA...HEAD failed" >&2
  exit 1
fi

relevant=false
while IFS= read -r -d '' file; do
  for pattern in "${patterns[@]}"; do
    # The pattern is deliberately unquoted: it is a glob and must fire at case
    # time, against the diff. It came in as an argument, so it is never
    # expanded against the checkout the runner happens to be standing in.
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) relevant=true; break 2 ;;
      *) ;;
    esac
  done
done < "$changed"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "relevant=$relevant" >> "$GITHUB_OUTPUT"
else
  echo "relevant=$relevant"
fi
