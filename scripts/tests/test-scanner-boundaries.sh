#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run the actual workflow blocks on synthetic inputs, capturing all output.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
extract() {
  awk -v name="$1" '
    $0 == "      - name: " name { found=1; next }
    found && (/^      - name: / || /^  [a-zA-Z_-]+:/) { exit }
    found && /^        run: \|/ { script=1; next }
    script && /^          / { sub(/^          /, ""); print }
  ' "$ROOT/.github/workflows/secret-scanner-reusable.yml"
}
extract 'Check for hardcoded secrets in Rust' > "$fixture/rust.sh"
extract 'Gitleaks secret scan — AsciiDoc mirror (gating)' > "$fixture/adoc.sh"
[ -s "$fixture/rust.sh" ] && [ -s "$fixture/adoc.sh" ]
mkdir -p "$fixture/repo/src" "$fixture/tmp"
# This is a disposable fixture, not a branch in the application repository.
git init -q -b arena/b1571410-metamanifold-webui "$fixture/repo"
git -C "$fixture/repo" config user.name 'Scanner test'
git -C "$fixture/repo" config user.email 'scanner-test@example.invalid'
printf '%s\n' 'PASSWORD="${LONG_PASSWORD:?}"' > "$fixture/repo/env.sh"
printf '%s\n' 'initial fixture' > "$fixture/repo/README"
git -C "$fixture/repo" add README env.sh
git -C "$fixture/repo" commit -qm 'clean fixture'
(cd "$fixture/repo" && bash "$ROOT/scripts/ci/check-shell-secrets.sh") > "$fixture/log" 2>&1
# Construct a dummy value at runtime; never commit a credential-shaped literal
# to the application repository or publish the fixture's matching source.
dummy="synthetic-$(printf '%s' 'credential-fixture-123456789')"
printf 'SERVICE_TOKEN="%s"\n' "$dummy" > "$fixture/repo/removed.sh"
rc=0
(cd "$fixture/repo" && bash "$ROOT/scripts/ci/check-shell-secrets.sh") > "$fixture/log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ! grep -Fq "$dummy" "$fixture/log"
echo 'ok - working-tree shell credential blocks without value disclosure'
git -C "$fixture/repo" add removed.sh
git -C "$fixture/repo" commit -qm 'synthetic historical credential'
git -C "$fixture/repo" rm -q removed.sh
git -C "$fixture/repo" commit -qm 'remove fixture credential'
rc=0
(cd "$fixture/repo" && bash "$ROOT/scripts/ci/check-shell-secrets.sh") > "$fixture/log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ! grep -Fq "$dummy" "$fixture/log"
echo 'ok - deleted historical shell credential still blocks without disclosure'
printf '[package]\nname="fixture"\nversion="0.1.0"\n' > "$fixture/repo/Cargo.toml"
for path in src/lib.rs crates/example.rs; do
  mkdir -p "$fixture/repo/$(dirname "$path")"
  printf 'const AUTH_TOKEN: &str = "%s";\n' "$dummy" > "$fixture/repo/$path"
done
rc=0
(cd "$fixture/repo" && ENFORCE_RUST_WIDE_SCAN_FROM=2026-08-21 bash -eo pipefail "$fixture/rust.sh") > "$fixture/log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ! grep -Fq "$dummy" "$fixture/log"
grep -q 'src/lib.rs:1: \[REDACTED\]' "$fixture/log"
grep -q 'crates/example.rs:1: \[REDACTED\]' "$fixture/log"
echo 'ok - Rust findings inside and outside src block without value disclosure'
printf '%s\n' 'ordinary documentation' > "$fixture/repo/sample.adoc"
printf '%s\n' '[extend]' 'useDefault = true' > "$fixture/repo/.gitleaks-estate.toml"
cat > "$fixture/tmp/gitleaks" <<'STUB'
#!/usr/bin/env bash
set -eu
report=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = --report-path ]; then report=$2; shift; fi
  shift
done
rm -f "$report"
case "$SCAN_MODE" in
  clean) printf '[]' > "$report"; exit 0 ;;
  error) printf '[]' > "$report"; exit 2 ;;
  nonzero-empty) printf '[]' > "$report"; exit 1 ;;
  missing) exit 0 ;;
  invalid) printf 'invalid JSON' > "$report"; exit 0 ;;
  finding) printf '[{"RuleID":"fixture-rule","File":"sample.adoc.txt"}]' > "$report"; exit 1 ;;
esac
STUB
chmod +x "$fixture/tmp/gitleaks"
for mode in clean error nonzero-empty missing invalid finding; do
  rc=0
  (cd "$fixture/repo" && SCAN_MODE="$mode" RUNNER_TEMP="$fixture/tmp" ADOC_TODAY=2026-10-23 \
    bash -eo pipefail "$fixture/adoc.sh") > "$fixture/log" 2>&1 || rc=$?
  case "$mode" in
    clean) [ "$rc" -eq 0 ] ;;
    *) [ "$rc" -ne 0 ] ;;
  esac
  echo "ok - AsciiDoc mode $mode returns $rc"
done
