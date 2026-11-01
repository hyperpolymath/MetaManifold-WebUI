#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Exercise collection boundaries with synthetic scanner envelopes. These stubs
# are test doubles, never evidence; no application scanner result is fabricated.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/workspace/owner" "$tmp/bin"
git init -q -b arena/884d53b3-metamanifold-webui "$tmp/workspace/owner"
git -C "$tmp/workspace/owner" config user.name 'Evidence test'
git -C "$tmp/workspace/owner" config user.email 'evidence@example.invalid'
printf 'source fixture\n' > "$tmp/workspace/owner/source.txt"
git -C "$tmp/workspace/owner" add source.txt
git -C "$tmp/workspace/owner" commit -qm 'synthetic base'
base=$(git -C "$tmp/workspace/owner" rev-parse HEAD)
git -C "$tmp/workspace/owner" worktree add -q --detach "$tmp/workspace/upstream" "$base"
printf 'changed fixture\n' > "$tmp/workspace/owner/source.txt"
git -C "$tmp/workspace/owner" commit -qam 'synthetic fork change'
fork=$(git -C "$tmp/workspace/owner" rev-parse HEAD)
git -C "$tmp/workspace/owner" worktree add -q --detach "$tmp/workspace/fork" "$fork"
jq -n --arg base "$base" --arg fork "$fork" '{
  schema_version:1, trees:{upstream:{revision:$base},fork:{revision:$fork}},
  merge_base:$base, expected_changed_paths:1,
  expected_upstream_only_commits:0, expected_fork_only_commits:1
}' > "$tmp/config.json"
cat > "$tmp/bin/panic-attack" <<'STUB'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == --version ]]; then echo 'synthetic test double'; exit 0; fi
out=''
while [[ $# -gt 0 ]]; do if [[ "$1" == -o ]]; then out=$2; shift; fi; shift; done
jq -n '{schema_version:"2.6",coverage:{status:"partial",inputs:[],analyzed_files:0,candidate_files:1},weak_points:[]}' > "$out"
exit 2
STUB
cat > "$tmp/bin/pons" <<'STUB'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --version) echo 'synthetic test double'; exit 0 ;;
  validate-report) echo 'synthetic schema validation'; exit 0 ;;
esac
format=json
while [[ $# -gt 0 ]]; do if [[ "$1" == --format ]]; then format=$2; shift; fi; shift; done
if [[ "$format" == sarif ]]; then
  jq -n '{version:"2.1.0",runs:[{}]}'
else
  jq -n '{schema_version:"0.5.0",execution:{exit_code:0},scanned:{inventory:[],coverage_status:"complete-within-policy"},findings:[]}'
fi
if [[ "${FAIL_PONS:-0}" == 1 ]]; then exit 2; fi
STUB
cat > "$tmp/bin/rustc" <<'STUB'
#!/usr/bin/env bash
echo 'synthetic rustc test double'
STUB
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
bash "$ROOT/scripts/evidence/collect-two-tree.sh" "$tmp/config.json" "$tmp/workspace" \
  "$tmp/bin/panic-attack" "$tmp/bin/pons" "$tmp/results"
[[ "$(cat "$tmp/results/upstream/panic.exit")" == 2 ]]
[[ "$(jq -r .coverage.status "$tmp/results/upstream/panic-attack.json")" == partial ]]
[[ "$(jq -r .changed_paths_no_renames "$tmp/results/baselines.json")" == 1 ]]
(cd "$tmp/results" && sha256sum -c SHA256SUMS >/dev/null)
echo 'ok - partial scanner exit and report preserved without a pass'
rc=0
bash "$ROOT/scripts/evidence/collect-two-tree.sh" "$tmp/config.json" "$tmp/workspace" \
  "$tmp/bin/panic-attack" "$tmp/bin/pons" "$tmp/results" >/dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]]
echo 'ok - existing evidence is not overwritten'
printf 'untracked\n' > "$tmp/workspace/fork/untracked.txt"
rc=0
bash "$ROOT/scripts/evidence/collect-two-tree.sh" "$tmp/config.json" "$tmp/workspace" \
  "$tmp/bin/panic-attack" "$tmp/bin/pons" "$tmp/dirty-results" >/dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]]
echo 'ok - dirty target refused'
rm "$tmp/workspace/fork/untracked.txt"
FAIL_PONS=1 bash "$ROOT/scripts/evidence/collect-two-tree.sh" "$tmp/config.json" "$tmp/workspace" \
  "$tmp/bin/panic-attack" "$tmp/bin/pons" "$tmp/mismatch-results" >/dev/null 2>&1 && {
    echo 'JSON/SARIF exit mismatch was accepted' >&2; exit 1;
  }
echo 'ok - JSON/SARIF exit mismatch refused'
# The temporary push trigger and its public transport certificate must not
# become a permanent branch-specific CI policy.
if grep -q 'branches: \[arena/884d53b3-metamanifold-webui\]' "$ROOT/.github/workflows/two-tree-evidence.yml"; then
  echo 'ok - temporary collection trigger still present (remove before finalizing)'
else
  [[ ! -e "$ROOT/config/evidence/issue-300-transport.pem" ]]
  grep -q 'required: true' "$ROOT/.github/workflows/two-tree-evidence.yml"
  echo 'ok - finalized workflow requires an explicit public transport certificate'
fi
