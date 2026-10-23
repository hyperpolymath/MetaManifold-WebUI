#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise the actual optional-log branch from the fork-local K9 workflow.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
copy_log=$(awk '
  /^          if \[ -f "\$RUNNER_TEMP\/corpus.log" \]; then/ { capture = 1 }
  capture { sub(/^          /, ""); print }
  capture && /^fi$/ { exit }
' "$ROOT/.github/workflows/k9-conformance-reusable.yml")
[ -n "$copy_log" ] || { echo 'optional K9 copy branch is missing' >&2; exit 1; }
mkdir -p "$fixture/k9-grid"
RUNNER_TEMP="$fixture" bash -euo pipefail -c "$copy_log"
echo 'ok - empty K9 corpus needs no log'
printf '%s\n' 'fixture validator log' > "$fixture/corpus.log"
RUNNER_TEMP="$fixture" bash -euo pipefail -c "$copy_log"
cmp "$fixture/corpus.log" "$fixture/k9-grid/corpus.log"
echo 'ok - present K9 corpus log is retained'
rm -rf "$fixture/k9-grid"
if RUNNER_TEMP="$fixture" bash -euo pipefail -c "$copy_log" 2>/dev/null; then
  echo 'ERROR: failed K9 log copy was hidden' >&2
  exit 1
fi
echo 'ok - genuine K9 copy errors still fail'
