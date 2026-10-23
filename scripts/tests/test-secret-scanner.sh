#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Check detector sensitivity after upgrading the scanner, not by suppressing
# old findings. The constructed token is synthetic and never a credential.
set -euo pipefail
scanner=${1:?usage: test-secret-scanner.sh GITLEAKS_BIN CONFIG}
config=$(realpath "${2:?a pinned scanner config is required}")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/source"
printf '%s\n' 'ordinary configuration' > "$fixture/source/production.env"
"$scanner" detect --source "$fixture/source" --no-git --redact --no-banner \
  --config "$config" > "$fixture/log" 2>&1
printf 'AWS_ACCESS_KEY_ID=%s%s\n' AKIA Q7W6E5R2T3Y4U5I6 >> "$fixture/source/production.env"
rc=0
"$scanner" detect --source "$fixture/source" --no-git --redact --no-banner \
  --config "$config" --exit-code 1 --report-format json --report-path "$fixture/report.json" \
  > "$fixture/log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "ERROR: synthetic credential was not rejected (exit $rc)" >&2; exit 1; }
jq -e 'any(.[]; .RuleID == "aws-access-token")' "$fixture/report.json" > /dev/null
echo 'ok - clean input passes; synthetic AWS credential fails with the expected rule'
