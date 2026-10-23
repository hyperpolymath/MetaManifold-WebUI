#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test the actual workflow exit-selection code without needing Julia or R.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$ROOT/.github/workflows/ci.yml"
count=$(grep -Fc 'statuses=("${PIPESTATUS[@]}")' "$workflow")
[[ "$count" -eq 2 ]] || { echo 'expected both Julia pipelines to preserve all exits' >&2; exit 1; }
selection=$(awk '
  /statuses=\("\$\{PIPESTATUS\[@\]\}"\)/ { capture = 1 }
  capture { sub(/^          /, ""); print }
  capture && /then status=/ { exit }
' "$workflow")
# Both pipelines must use the same selection logic.
second=$(awk '
  /statuses=\("\$\{PIPESTATUS\[@\]\}"\)/ { n++; capture = (n == 2) }
  capture { sub(/^          /, ""); print }
  capture && /then status=/ { exit }
' "$workflow")
[[ "$selection" = "$second" ]] || { echo 'Julia exit-selection blocks differ' >&2; exit 1; }
for spec in '0 0 0' '42 0 42' '0 23 23' '42 23 42'; do
  read -r producer logger expected <<< "$spec"
  rc=0
  bash -c '
    set +e
    (exit "$1") | (cat >/dev/null; exit "$2")
    '"$selection"'
    exit "$status"
  ' test-ci-logging "$producer" "$logger" || rc=$?
  [[ "$rc" -eq "$expected" ]] || {
    echo "producer=$producer logger=$logger returned $rc, expected $expected" >&2
    exit 1
  }
  echo "ok - producer=$producer logger=$logger returns $expected"
done
