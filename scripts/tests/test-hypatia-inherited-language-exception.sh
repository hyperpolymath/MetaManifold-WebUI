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

# Every output/input pairing must reject aliases before writing either output.
mkdir -p "$tmpdir/child"
ln -s "$tmpdir" "$tmpdir/parent-alias"
for raw in raw-findings.json raw.sarif; do
  ln -s "$tmpdir/$raw" "$tmpdir/symlink-$raw"
  ln "$tmpdir/$raw" "$tmpdir/hardlink-$raw"
  for alias in "$tmpdir/$raw" "$tmpdir/./$raw" "$tmpdir/child/../$raw" \
      "$tmpdir/parent-alias/$raw" "$tmpdir/symlink-$raw" "$tmpdir/hardlink-$raw"; do
    for output_kind in findings sarif; do
      printf 'untouched companion output\n' > "$tmpdir/companion"
      cp "$tmpdir/companion" "$tmpdir/companion.original"
      outputs=("$alias" "$tmpdir/companion")
      if [[ "$output_kind" == sarif ]]; then
        outputs=("$tmpdir/companion" "$alias")
      fi
      if bash "$FILTER" "$tmpdir/raw-findings.json" "$tmpdir/raw.sarif" \
          "$tmpdir/allowlist.txt" "${outputs[@]}" "$canonicalizer_arg" > "$tmpdir/collision.log" 2>&1; then
        echo "ERROR: accepted $output_kind output colliding with $alias" >&2
        exit 1
      fi
      grep -Fq 'Input, allowlist, and output paths must resolve to distinct files.' "$tmpdir/collision.log"
      cmp "$tmpdir/raw-findings.json" "$tmpdir/raw-findings.original.json"
      cmp "$tmpdir/raw.sarif" "$tmpdir/raw.original.sarif"
      cmp "$tmpdir/companion" "$tmpdir/companion.original"
    done
  done
done

# The allowlist is a protected input just like the raw scanner artifacts.
ln -s "$tmpdir/allowlist.txt" "$tmpdir/symlink-allowlist.txt"
ln "$tmpdir/allowlist.txt" "$tmpdir/hardlink-allowlist.txt"
for alias in "$tmpdir/allowlist.txt" "$tmpdir/./allowlist.txt" \
    "$tmpdir/symlink-allowlist.txt" "$tmpdir/hardlink-allowlist.txt"; do
  for output_kind in findings sarif; do
    printf 'untouched companion output\n' > "$tmpdir/companion"
    cp "$tmpdir/companion" "$tmpdir/companion.original"
    outputs=("$alias" "$tmpdir/companion")
    if [[ "$output_kind" == sarif ]]; then
      outputs=("$tmpdir/companion" "$alias")
    fi
    if bash "$FILTER" "$tmpdir/raw-findings.json" "$tmpdir/raw.sarif" \
        "$tmpdir/allowlist.txt" "${outputs[@]}" "$canonicalizer_arg" > "$tmpdir/collision.log" 2>&1; then
      echo "ERROR: accepted $output_kind output colliding with allowlist alias $alias" >&2
      exit 1
    fi
    grep -Fq 'Input, allowlist, and output paths must resolve to distinct files.' "$tmpdir/collision.log"
    cmp "$tmpdir/allowlist.txt" "$tmpdir/allowlist.original.txt"
    cmp "$tmpdir/raw-findings.json" "$tmpdir/raw-findings.original.json"
    cmp "$tmpdir/raw.sarif" "$tmpdir/raw.original.sarif"
    cmp "$tmpdir/companion" "$tmpdir/companion.original"
  done
done

# Canonicalize raw input aliases too, and reject aliased effective outputs.
for collision in raw-alias output-alias; do
  inputs=("$tmpdir/raw-findings.json" "$tmpdir/raw.sarif")
  outputs=("$tmpdir/companion" "$tmpdir/./companion")
  if [[ "$collision" == raw-alias ]]; then
    inputs=("$tmpdir/symlink-raw-findings.json" "$tmpdir/symlink-raw.sarif")
    outputs=("$tmpdir/raw-findings.json" "$tmpdir/companion")
  fi
  if bash "$FILTER" "${inputs[@]}" "$tmpdir/allowlist.txt" \
      "${outputs[@]}" "$canonicalizer_arg" > "$tmpdir/collision.log" 2>&1; then
    echo "ERROR: accepted $collision collision" >&2
    exit 1
  fi
  grep -Fq 'Input, allowlist, and output paths must resolve to distinct files.' "$tmpdir/collision.log"
  cmp "$tmpdir/raw-findings.json" "$tmpdir/raw-findings.original.json"
  cmp "$tmpdir/raw.sarif" "$tmpdir/raw.original.sarif"
  cmp "$tmpdir/companion" "$tmpdir/companion.original"
done

# Missing output directories remain supported after canonicalization.
bash "$FILTER" "$tmpdir/raw-findings.json" "$tmpdir/raw.sarif" \
  "$tmpdir/allowlist.txt" "$tmpdir/new/findings/effective.json" \
  "$tmpdir/new/sarif/effective.sarif" "$canonicalizer_arg"
cmp "$tmpdir/effective-findings.json" "$tmpdir/new/findings/effective.json"
cmp "$tmpdir/effective.sarif" "$tmpdir/new/sarif/effective.sarif"
echo 'PASS: path collisions are rejected before writes; distinct new output paths remain supported.'

# Command substitution must preserve every trailing newline in resolved paths.
for suffix in $'\n' $'\n\n'; do
  inputs=("$tmpdir/raw-findings.json$suffix" "$tmpdir/raw.sarif$suffix" "$tmpdir/allowlist.txt$suffix")
  cp "$tmpdir/raw-findings.original.json" "${inputs[0]}"
  cp "$tmpdir/raw.original.sarif" "${inputs[1]}"
  cp "$tmpdir/allowlist.original.txt" "${inputs[2]}"
  outputs=("$tmpdir/newline$suffix/effective-findings.json$suffix" "$tmpdir/newline$suffix/effective.sarif$suffix")
  bash "$FILTER" "${inputs[@]}" "${outputs[@]}" "$canonicalizer_arg"
  cmp "$tmpdir/effective-findings.json" "${outputs[0]}"
  cmp "$tmpdir/effective.sarif" "${outputs[1]}"
  cmp "$tmpdir/raw-findings.original.json" "${inputs[0]}"
  cmp "$tmpdir/raw.original.sarif" "${inputs[1]}"
  cmp "$tmpdir/allowlist.original.txt" "${inputs[2]}"
  [[ ! -e "${outputs[0]%$suffix}" && ! -e "${outputs[1]%$suffix}" ]]

  # Symlinks to newline-terminated input names must still be protected.
  ln -sf "${inputs[0]}" "$tmpdir/newline-alias"
  if bash "$FILTER" "${inputs[@]}" "$tmpdir/newline-alias" "${outputs[1]}" \
      "$canonicalizer_arg" > "$tmpdir/collision.log" 2>&1; then
    echo 'ERROR: accepted an output aliasing an input with trailing newlines' >&2
    exit 1
  fi
  grep -Fq 'Input, allowlist, and output paths must resolve to distinct files.' "$tmpdir/collision.log"
  cmp "$tmpdir/raw-findings.original.json" "${inputs[0]}"
  cmp "$tmpdir/effective.sarif" "${outputs[1]}"
done
echo 'PASS: trailing newlines in input and output paths are preserved and aliases remain protected.'

# Simulate macOS/BSD environments where GNU `realpath -m` is unavailable.
mkdir -p "$tmpdir/no-realpath-bin"
cat > "$tmpdir/no-realpath-bin/realpath" <<'EOF'
#!/bin/sh
echo 'ERROR: GNU realpath must not be required' >&2
exit 127
EOF
chmod +x "$tmpdir/no-realpath-bin/realpath"
PATH="$tmpdir/no-realpath-bin:$PATH" bash "$FILTER" \
  "$tmpdir/raw-findings.json" "$tmpdir/raw.sarif" "$tmpdir/allowlist.txt" \
  "$tmpdir/portable/findings/effective.json" "$tmpdir/portable/sarif/effective.sarif" \
  "$canonicalizer_arg"
cmp "$tmpdir/effective-findings.json" "$tmpdir/portable/findings/effective.json"
cmp "$tmpdir/effective.sarif" "$tmpdir/portable/sarif/effective.sarif"
echo 'PASS: path resolution works without a GNU realpath executable.'

if [[ -n "$canonicalizer_arg" ]]; then
  echo "PASS: inherited TypeScript paths are narrowly filtered; raw, fork-only, and unrelated findings remain; effective JSON is I-JSON/JCS checked."
else
  echo "PASS: inherited TypeScript paths are narrowly filtered; raw, fork-only, and unrelated findings remain (JCS check skipped: no ijson-jcs CLI supplied)."
fi
