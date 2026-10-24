#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Apply the fork-local, upstream-inherited TypeScript exception without mutating
# Hypatia's raw JSON or SARIF outputs. Only exact allowlisted .ts/.tsx paths and
# the cicd_rules/banned_language_file rule are affected. CI passes the pinned
# ijson-jcs CLI to validate raw inputs and canonicalize the effective JSON.
set -euo pipefail

# Write the command synopsis to standard error and exit the script with status 2.
usage() {
  echo "Usage: $0 RAW_FINDINGS.json RAW.sarif ALLOWLIST.txt EFFECTIVE_FINDINGS.json EFFECTIVE.sarif [IJSON_JCS]" >&2
  exit 2
}

[[ $# -eq 5 || $# -eq 6 ]] || usage
raw_findings=$1
raw_sarif=$2
allowlist=$3
effective_findings=$4
effective_sarif=$5
canonicalizer=${6:-}

for input in "$raw_findings" "$raw_sarif" "$allowlist"; do
  if [[ ! -s "$input" ]]; then
    echo "Required input is missing or empty: $input" >&2
    exit 1
  fi
done

# Resolve relative components and symlinks portably, including output paths
# whose parent directories do not exist yet. Python's standard library avoids
# relying on GNU-only `realpath -m`. Neither output may overwrite any input or
# the other output.
canonicalize_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}
raw_findings=$(canonicalize_path "$raw_findings")
raw_sarif=$(canonicalize_path "$raw_sarif")
allowlist=$(canonicalize_path "$allowlist")
effective_findings=$(canonicalize_path "$effective_findings")
effective_sarif=$(canonicalize_path "$effective_sarif")
for output in "$effective_findings" "$effective_sarif"; do
  if [[ "$output" == "$raw_findings" || "$output" == "$raw_sarif" || "$output" == "$allowlist" \
      || "$output" -ef "$raw_findings" || "$output" -ef "$raw_sarif" || "$output" -ef "$allowlist" ]]; then
    echo "Input, allowlist, and output paths must resolve to distinct files." >&2
    exit 1
  fi
done
if [[ "$effective_findings" == "$effective_sarif" || "$effective_findings" -ef "$effective_sarif" ]]; then
  echo "Input, allowlist, and output paths must resolve to distinct files." >&2
  exit 1
fi

if [[ -n "$canonicalizer" ]]; then
  if [[ ! -x "$canonicalizer" ]]; then
    echo "ijson-jcs canonicalizer is missing or not executable: $canonicalizer" >&2
    exit 1
  fi
  # Validate raw inputs before jq sees them, so unsafe I-JSON numbers or
  # duplicate keys cannot be silently normalized during the transform.
  "$canonicalizer" canon < "$raw_findings" >/dev/null
  "$canonicalizer" canon < "$raw_sarif" >/dev/null
fi
jq -e 'type == "array" and all(.[]; type == "object")' "$raw_findings" >/dev/null
jq -e 'type == "object" and (.runs | type == "array") and all(.runs[]; type == "object" and ((.results // []) | type == "array"))' "$raw_sarif" >/dev/null

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Comments and blank lines make the tracked allowlist self-documenting.
jq -Rn '[inputs | sub("\\r$"; "") | select(length > 0) | select((startswith("#")) | not)] | unique' "$allowlist" > "$tmpdir/allowlist.json"
jq -e 'length > 0 and all(.[]; type == "string" and (startswith("/") | not) and (contains("\\") | not) and (test("(^|/)\\.\\.?(/|$)") | not) and test("\\.(ts|tsx)$"))' "$tmpdir/allowlist.json" >/dev/null

# The input to this step is already repository-relative. Normalize harmless
# leading ./ and Windows separators, but otherwise require an exact path match.
jq --argjson allowed "$(cat "$tmpdir/allowlist.json")" '
  # Yield a path with forward slashes and one leading ./ prefix removed,
  # including repeated slashes in that prefix. Yield "" for non-string inputs.
  def norm_path:
    if type == "string" then gsub("\\\\"; "/") | sub("^\\./+"; "") else "" end;
  map(
    . as $finding
    | (($finding.file // "") | norm_path) as $path
    | if $finding.rule_module == "cicd_rules"
         and $finding.type == "banned_language_file"
         and ($path | test("\\.(ts|tsx)$"))
         and (($allowed | index($path)) != null)
      then empty
      else $finding
      end
  )
' "$raw_findings" > "$tmpdir/effective-findings.json"

jq --argjson allowed "$(cat "$tmpdir/allowlist.json")" '
  # Yield a path with forward slashes and one leading ./ prefix removed,
  # including repeated slashes in that prefix. Yield "" for non-string inputs.
  def norm_path:
    if type == "string" then gsub("\\\\"; "/") | sub("^\\./+"; "") else "" end;
  .runs |= map(
    . as $run
    | .results = (($run.results // []) | map(
        . as $result
        | (($result.locations[0].physicalLocation.artifactLocation.uri // "") | norm_path) as $path
        | select(
            (
              $result.ruleId == "hypatia/cicd_rules/banned_language_file"
              and ($path | test("\\.(ts|tsx)$"))
              and (($allowed | index($path)) != null)
            ) | not
          )
      ))
  )
' "$raw_sarif" > "$tmpdir/effective.sarif"

if [[ -n "$canonicalizer" ]]; then
  "$canonicalizer" canon < "$tmpdir/effective-findings.json" > "$tmpdir/effective-findings.jcs.json"
  "$canonicalizer" check "$tmpdir/effective-findings.jcs.json" >/dev/null
  mv "$tmpdir/effective-findings.jcs.json" "$tmpdir/effective-findings.json"
fi

mkdir -p "$(dirname "$effective_findings")" "$(dirname "$effective_sarif")"
cp "$tmpdir/effective-findings.json" "$effective_findings"
cp "$tmpdir/effective.sarif" "$effective_sarif"

raw_count=$(jq 'length' "$raw_findings")
effective_count=$(jq 'length' "$effective_findings")
if [[ -n "$canonicalizer" ]]; then
  echo 'Effective findings are I-JSON validated and JCS canonicalized with the supplied pinned ijson-jcs CLI.' >&2
fi
printf 'Upstream-inherited TypeScript exception: excluded %d of %d findings; raw scan outputs were preserved.\n' \
  "$((raw_count - effective_count))" "$raw_count" >&2
