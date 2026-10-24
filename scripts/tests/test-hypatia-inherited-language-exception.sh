#!/usr/bin/env bash
# Tests the narrow upstream-inherited TypeScript exception for both Hypatia
# findings JSON and SARIF, including the negative cases that must remain visible.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FILTER="$ROOT_DIR/scripts/filter-hypatia-inherited-language.sh"
canonicalizer_arg=${IJSON_JCS:-}
if [[ -n "$canonicalizer_arg" && ! -x "$canonicalizer_arg" ]]; then
  echo "IJSON_JCS is not executable: $canonicalizer_arg" >&2
  exit 1
fi
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/allowlist.txt" <<'EOF'
# Test snapshot
frontend/src/App.tsx
frontend/src/api/client.ts
EOF
cp "$tmpdir/allowlist.txt" "$tmpdir/allowlist.original.txt"

cat > "$tmpdir/raw-findings.json" <<'EOF'
[
  {"rule_module":"cicd_rules","type":"banned_language_file","file":"./frontend/src/App.tsx","severity":"critical"},
  {"rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/src/api/client.ts","severity":"critical"},
  {"rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/src/utils/text.test.ts","severity":"critical"},
  {"rule_module":"code_safety","type":"unsafe_call","file":"frontend/src/App.tsx","severity":"high"},
  {"rule_module":"cicd_rules","type":"banned_language_file","file":"scripts/new-tool.py","severity":"high"}
]
EOF

cat > "$tmpdir/raw.sarif" <<'EOF'
{
  "version": "2.1.0",
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "runs": [{
    "tool": {"driver": {"name": "Hypatia"}},
    "results": [
      {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"./frontend/src/App.tsx"}}}]},
      {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/src/api/client.ts"}}}]},
      {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/src/utils/text.test.ts"}}}]},
      {"ruleId":"hypatia/code_safety/unsafe_call","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/src/App.tsx"}}}]},
      {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"scripts/new-tool.py"}}}]}
    ]
  }]
}
EOF

cp "$tmpdir/raw-findings.json" "$tmpdir/raw-findings.original.json"
cp "$tmpdir/raw.sarif" "$tmpdir/raw.original.sarif"
bash "$FILTER" \
  "$tmpdir/raw-findings.json" \
  "$tmpdir/raw.sarif" \
  "$tmpdir/allowlist.txt" \
  "$tmpdir/effective-findings.json" \
  "$tmpdir/effective.sarif" \
  "$canonicalizer_arg"
if [[ -n "${IJSON_JCS:-}" ]]; then
  "$IJSON_JCS" check "$tmpdir/effective-findings.json" >/dev/null
fi

# Only the two exact inherited TypeScript paths are removed from findings.
jq -e 'length == 3' "$tmpdir/effective-findings.json" >/dev/null
jq -e 'any(.[]; .file == "frontend/src/utils/text.test.ts" and .rule_module == "cicd_rules" and .type == "banned_language_file")' "$tmpdir/effective-findings.json" >/dev/null
jq -e 'any(.[]; .file == "frontend/src/App.tsx" and .rule_module == "code_safety")' "$tmpdir/effective-findings.json" >/dev/null
jq -e 'any(.[]; .file == "scripts/new-tool.py" and .type == "banned_language_file")' "$tmpdir/effective-findings.json" >/dev/null
jq -e 'all(.[]; .file != "./frontend/src/App.tsx" and .file != "frontend/src/api/client.ts" or .rule_module != "cicd_rules" or .type != "banned_language_file")' "$tmpdir/effective-findings.json" >/dev/null

# The corresponding SARIF filter has the same narrow scope.
jq -e '.runs[0].results | length == 3' "$tmpdir/effective.sarif" >/dev/null
jq -e '[.runs[0].results[] | select(.ruleId == "hypatia/cicd_rules/banned_language_file" and .locations[0].physicalLocation.artifactLocation.uri == "frontend/src/utils/text.test.ts")] | length == 1' "$tmpdir/effective.sarif" >/dev/null
jq -e '[.runs[0].results[] | select(.ruleId == "hypatia/code_safety/unsafe_call")] | length == 1' "$tmpdir/effective.sarif" >/dev/null
jq -e '[.runs[0].results[] | select(.ruleId == "hypatia/cicd_rules/banned_language_file" and .locations[0].physicalLocation.artifactLocation.uri == "scripts/new-tool.py")] | length == 1' "$tmpdir/effective.sarif" >/dev/null

# Exercise the committed upstream snapshot itself: App.tsx is inherited, while
# the fork-only test file is intentionally absent from the allowlist.
cat > "$tmpdir/repo-findings.json" <<'EOF'
[
  {"rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/src/App.tsx","severity":"critical"},
  {"rule_module":"cicd_rules","type":"banned_language_file","file":"frontend/src/utils/text.test.ts","severity":"critical"}
]
EOF
cat > "$tmpdir/repo.sarif" <<'EOF'
{
  "version": "2.1.0",
  "runs": [{"results": [
    {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/src/App.tsx"}}}]},
    {"ruleId":"hypatia/cicd_rules/banned_language_file","locations":[{"physicalLocation":{"artifactLocation":{"uri":"frontend/src/utils/text.test.ts"}}}]}
  ]}]
}
EOF
bash "$FILTER" \
  "$tmpdir/repo-findings.json" \
  "$tmpdir/repo.sarif" \
  "$ROOT_DIR/config/hypatia/upstream-typescript-allowlist.txt" \
  "$tmpdir/repo-effective-findings.json" \
  "$tmpdir/repo-effective.sarif" \
  "$canonicalizer_arg"
if [[ -n "${IJSON_JCS:-}" ]]; then
  "$IJSON_JCS" check "$tmpdir/repo-effective-findings.json" >/dev/null
fi
jq -e 'length == 1 and .[0].file == "frontend/src/utils/text.test.ts"' "$tmpdir/repo-effective-findings.json" >/dev/null
jq -e '.runs[0].results | length == 1 and .[0].locations[0].physicalLocation.artifactLocation.uri == "frontend/src/utils/text.test.ts"' "$tmpdir/repo-effective.sarif" >/dev/null

# The source artifacts are immutable audit evidence.
cmp "$tmpdir/raw-findings.json" "$tmpdir/raw-findings.original.json"
cmp "$tmpdir/raw.sarif" "$tmpdir/raw.original.sarif"

# Direct callers may supply different spellings for the same path. Reject
# dot-segment and symlink aliases before any output can replace source evidence.
ln -s "$tmpdir/raw.sarif" "$tmpdir/raw-sarif.alias"
ln -s "$tmpdir/allowlist.txt" "$tmpdir/allowlist.alias"
assert_alias_rejected() {
  local label=$1
  local output_findings=$2
  local output_sarif=$3
  if bash "$FILTER" \
    "$tmpdir/raw-findings.json" \
    "$tmpdir/raw.sarif" \
    "$tmpdir/allowlist.txt" \
    "$output_findings" \
    "$output_sarif" \
    "$canonicalizer_arg" >/dev/null 2>&1; then
    echo "FAIL: accepted colliding paths for $label" >&2
    exit 1
  fi
  cmp "$tmpdir/raw-findings.json" "$tmpdir/raw-findings.original.json"
  cmp "$tmpdir/raw.sarif" "$tmpdir/raw.original.sarif"
  cmp "$tmpdir/allowlist.txt" "$tmpdir/allowlist.original.txt"
  echo "PASS: rejected colliding paths for $label"
}
assert_alias_rejected 'dot-segment raw findings alias' \
  "$tmpdir/./raw-findings.json" "$tmpdir/alias-effective.sarif"
assert_alias_rejected 'effective findings symlink to raw SARIF' \
  "$tmpdir/raw-sarif.alias" "$tmpdir/alias-effective.sarif"
assert_alias_rejected 'effective SARIF symlink to the allowlist' \
  "$tmpdir/alias-effective.json" "$tmpdir/allowlist.alias"
assert_alias_rejected 'effective SARIF cross-alias to raw findings' \
  "$tmpdir/alias-effective.json" "$tmpdir/raw-findings.json"
assert_alias_rejected 'effective outputs share a dot-segment path alias' \
  "$tmpdir/shared-output.json" "$tmpdir/./shared-output.json"

if [[ -n "$canonicalizer_arg" ]]; then
  echo "PASS: inherited TypeScript paths are narrowly filtered; raw, fork-only, and unrelated findings remain; effective JSON is I-JSON/JCS checked."
else
  echo "PASS: inherited TypeScript paths are narrowly filtered; raw, fork-only, and unrelated findings remain (JCS check skipped: no ijson-jcs CLI supplied)."
fi
