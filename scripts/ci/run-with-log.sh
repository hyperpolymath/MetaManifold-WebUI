#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Run one command, keep its output in a log file and on stdout, and annotate a
# failure with the tail of that log.
#
# The exit status is the command's own, never the logger's: `... | tee` would
# otherwise report the pipeline's last stage and turn a failing analysis into a
# green step. Anything after the command's own status is bookkeeping and must
# not overwrite it.
#
# Usage: [RUN_LOG_TITLE="<title>"] run-with-log.sh <log-path> -- <command> [args...]
#
# The annotation escapes %, CR and LF as the checks API requires, and truncates
# to a size a reader can still use. Only the tail is emitted, because the whole
# point of the annotation is the reason, not the transcript.
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: $0 <log-path> -- <command> [args...]" >&2
  exit 2
fi

log="$1"
shift 2

if [ -z "$log" ]; then
  echo "usage: $0 <log-path> -- <command> [args...]" >&2
  exit 2
fi

mkdir -p -- "$(dirname -- "$log")"
: >"$log"

# `set +e` rather than `|| true`: a trailing `|| true` would itself be the last
# pipeline and overwrite PIPESTATUS with the status of `true`.
set +e
"$@" 2>&1 | tee -a "$log"
status="${PIPESTATUS[0]}"
set -e

if [ "$status" -ne 0 ]; then
  title="${RUN_LOG_TITLE:-$(basename -- "$1")} failed"
  message="$(tail -c 3000 "$log" |
    sed -e 's/%/%25/g' -e 's/\r//g' |
    awk '{ printf "%s%%0A", $0 }')"
  echo "::error title=${title}::${message}"
fi

exit "$status"
