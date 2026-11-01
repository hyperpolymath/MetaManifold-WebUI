#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Collect static evidence from two already-prepared, detached worktrees.
# Scanner finding exits are data, not a CI gate. Operational failures are fatal.
set -euo pipefail
if [[ $# -ne 5 ]]; then
  echo 'Usage: collect-two-tree.sh CONFIG WORKSPACE PANIC_BINARY PONS_BINARY OUTPUT' >&2
  exit 2
fi
config=$(realpath "$1"); workspace=$(realpath "$2")
panic=$(realpath "$3"); pons=$(realpath "$4"); out=$(realpath -m "$5")
for exe in git jq timeout sha256sum; do command -v "$exe" >/dev/null; done
[[ -x "$panic" && -x "$pons" ]] || { echo 'Scanner binaries missing' >&2; exit 2; }
jq -e '.schema_version == 1 and (.trees | keys == ["fork", "upstream"])' "$config" >/dev/null
mkdir -p "$out"
[[ -z "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo 'Refusing to overwrite an evidence directory' >&2; exit 2;
}
cp "$config" "$out/config.json"
sha256sum "$panic" "$pons" > "$out/scanner-binaries.sha256"
"$panic" --version > "$out/panic-version.txt"
"$pons" --version > "$out/pons-version.txt"
rustc --version --verbose > "$out/rust-version.txt"
uname -a > "$out/os.txt"

# The checkout that owns the worktrees contains both pinned histories. Never
# substitute a moving main ref, and never scan the harness checkout itself.
owner="$workspace/owner"
[[ -d "$owner/.git" ]] || { echo 'Missing worktree-owner checkout' >&2; exit 2; }
up=$(jq -r '.trees.upstream.revision' "$config")
fork=$(jq -r '.trees.fork.revision' "$config")
base=$(jq -r '.merge_base' "$config")
for sha in "$up" "$fork" "$base"; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && git -C "$owner" cat-file -e "$sha^{commit}"
done
[[ "$(git -C "$owner" merge-base "$up" "$fork")" == "$base" ]]
git -C "$owner" rev-list --left-right --count "$up...$fork" > "$out/commit-counts.txt"
read -r up_count fork_count < "$out/commit-counts.txt"
[[ "$up_count" == "$(jq -r .expected_upstream_only_commits "$config")" ]]
[[ "$fork_count" == "$(jq -r .expected_fork_only_commits "$config")" ]]
for side in upstream fork; do
  tree="$workspace/$side"; dest="$out/$side"; mkdir -p "$dest"
  expected=$(jq -r ".trees.$side.revision" "$config")
  [[ "$(git -C "$tree" rev-parse HEAD)" == "$expected" ]]
  [[ -z "$(git -C "$tree" status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "Dirty measured tree: $side" >&2; exit 2;
  }
  git -C "$tree" ls-tree -r -z "$expected" |
    jq -Rsn '[inputs | split("\u0000")[] | select(length > 0) |
      capture("^(?<mode>[0-9]+) (?<type>[^ ]+) (?<blob>[0-9a-f]{40})\\t(?<path>.*)$")]' \
      > "$dest/git-inventory.json"
  # No project suppression/config file is supplied. Fail if one appears rather
  # than silently accepting a different rule set on a future baseline.
  [[ ! -e "$tree/pons.toml" && ! -e "$tree/.ponsignore" ]] || {
    echo "Unreviewed Pons configuration in $side" >&2; exit 2;
  }
  (
    cd "$tree"
    rc=0
    timeout 300 "$panic" assail . --headless --fail-on-incomplete \
      -o "$dest/panic-attack.json" > "$dest/panic.stdout" 2> "$dest/panic.stderr" || rc=$?
    echo "$rc" > "$dest/panic.exit"
    jq -n --argjson rc "$rc" --arg binary "$panic" \
      '{command: [$binary,"assail",".","--headless","--fail-on-incomplete","-o","<OUTPUT>/panic-attack.json"],
       cwd: ".", exit_code: $rc, configuration: "defaults; no target Pons/Panic configuration; no suppression flags"}' \
      > "$dest/panic-command.json"
    # A coverage exit of 2 can still contain a valid, useful partial report.
    [[ "$rc" == 0 || "$rc" == 2 ]] || exit 1
    jq -e '.schema_version == "2.6" and (.coverage.inputs | type == "array") and
      (.weak_points | type == "array")' "$dest/panic-attack.json" >/dev/null

    rc=0
    timeout 300 "$pons" scan . --format json --no-speculative --fail-on-skips \
      > "$dest/pons.json" 2> "$dest/pons.stderr" || rc=$?
    echo "$rc" > "$dest/pons.exit"
    jq -n --argjson rc "$rc" --arg binary "$pons" \
      '{command: [$binary,"scan",".","--format","json","--no-speculative","--fail-on-skips"],
       cwd: ".", exit_code: $rc, configuration: "defaults; no pons.toml or .ponsignore; no suppressions"}' \
      > "$dest/pons-command.json"
    [[ "$rc" == 0 || "$rc" == 2 ]] || exit 1
    jq -e '.schema_version == "0.5.0" and (.scanned.inventory | type == "array") and
      (.findings | type == "array") and (.execution.exit_code == '"$rc"') and
      all(.findings[]; .evidence != "SPECULATIVE")' "$dest/pons.json" >/dev/null
    "$pons" validate-report "$dest/pons.json" > "$dest/pons-validation.txt"

    # SARIF is supported by Pons scan. At this Panic pin, assail always writes
    # AssailReport JSON; its SARIF renderer belongs to the separate assault
    # command, which is deliberately not run. Do not fabricate Panic SARIF.
    rc=0
    timeout 300 "$pons" scan . --format sarif --no-speculative --fail-on-skips \
      > "$dest/pons.sarif" 2> "$dest/pons-sarif.stderr" || rc=$?
    echo "$rc" > "$dest/pons-sarif.exit"
    jq -e '.version == "2.1.0" and (.runs | length == 1)' "$dest/pons.sarif" >/dev/null
    [[ "$rc" == "$(cat "$dest/pons.exit")" ]]
  )
done
# Git's default rename detection gives 278 paths at this baseline. With
# --no-renames the moved occupancy test contributes two paths (279). Neither
# number is a defect count; the blob inventory below is rename-independent.
changed=$(git -C "$owner" diff --name-only "$up" "$fork" | wc -l)
[[ "$changed" == "$(jq -r .expected_changed_paths "$config")" ]]
jq -n --arg up "$up" --arg fork "$fork" --arg base "$base" \
  --argjson changed "$changed" --argjson upcommits "$up_count" --argjson forkcommits "$fork_count" \
  '{upstream: $up, fork: $fork, merge_base: $base, changed_paths_no_renames: $changed,
    upstream_only_commits: $upcommits, fork_only_commits: $forkcommits,
    interpretation: "Finding exits and within-policy coverage are not whole-application assurance."}' \
  > "$out/baselines.json"
( cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) > "$out/SHA256SUMS"
echo 'Static evidence collected. Inspect coverage and finding exits; this is not a pass.'
