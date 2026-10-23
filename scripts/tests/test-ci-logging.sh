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

# The standards job no longer spells a pipeline out in ci.yml; it calls this
# script. The script must therefore keep the producer's status itself, or a
# failing simulation would be reported as a passing step.
runner="$ROOT/scripts/ci/run-with-log.sh"
for spec in '0 0' '42 42' '23 23'; do
  read -r producer expected <<<"$spec"
  rc=0
  RUN_LOG_TITLE=test bash "$runner" "$(mktemp)" -- bash -c "printf 'line\n'; printf 'warn\n' >&2; exit $producer" \
    >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq "$expected" ]] || {
    echo "run-with-log producer=$producer returned $rc, expected $expected" >&2
    exit 1
  }
done
echo 'ok - run-with-log.sh preserves the producer exit'

# A failure must be annotated, and the annotation must escape line breaks rather
# than emitting a multi-line command the checks API cannot parse.
log=$(mktemp)
annotation=$(RUN_LOG_TITLE='Seeded simulation study' bash "$runner" "$log" -- \
  bash -c 'printf "first\nsecond\n"; exit 7' 2>/dev/null || true)
grep -Fq '::error title=Seeded simulation study failed::' <<<"$annotation" || {
  echo 'run-with-log.sh did not annotate a failure' >&2
  exit 1
}
grep -Fq 'first%0Asecond%0A' <<<"$annotation" || {
  echo 'run-with-log.sh did not escape the log tail' >&2
  exit 1
}
echo 'ok - run-with-log.sh annotates a failure with an escaped log tail'

# The log is written even when the command fails, and it holds both streams.
grep -Fq 'second' "$log" || { echo 'run-with-log.sh lost the log' >&2; exit 1; }
echo 'ok - run-with-log.sh retains the log'
