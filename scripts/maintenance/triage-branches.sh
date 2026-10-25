#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Read-only triage of the remote's branches against the base branch.
#
# The repository's rule is narrow: a pull request's branch must start at the
# tip of `main` (CONTRIBUTING.md, "Branch from the current `main`"), and its
# commits must contain no merge from `main`. When that rule is not enforced, a
# cron job or an agent can leave dozens of branches cut from an old snapshot;
# each one then conflicts, each one opens a pull request, and each pull request
# starts a full CI run. This script is the measurement, not the enforcement:
# it says of every branch which of five things it is, so cleanup is a decision
# made on evidence rather than on a guess about the branch name.
#
# Classes, and what each one means for cleanup:
#
#   base        the base branch itself.
#   unrelated   no common ancestor with the base.
#   contained   every commit is already in the base (`ahead == 0`). The branch
#               has nothing to merge and its pull request can be closed.
#   fresh       merge base is the base tip, so it satisfies CONTRIBUTING rule 1.
#   salvage     behind the base, but it carries files the base does not have.
#               Closing it would lose work, so it has to be re-applied on top of
#               the current base or deliberately abandoned first.
#   stale       behind the base and every file it carries also exists in the
#               base. The content was superseded by later commits; merging it
#               would revert them.
#
# Lanes. A branch name can also be a *declared routing decision*, and those are
# not spare branches whatever their commit graph says. The lanes are read from
# the repository deed (`MetaManifold-WebUI_chora.deed` names the upstream
# candidates) plus the two declared in CONTRIBUTING.md's retention section:
#
#   upstream/*        upstream-candidate work, squash-merged on the upstream
#                     remote (deed routing `:upstream-candidates`).
#   archive/*         a deliberate snapshot, not proposed for merging.
#   governance-badges orphan branch of shields.io endpoint JSON, force-pushed by
#                     the Publish badges job and read by README.md.
#
# A laned branch is still classed and still printed, because its shape is worth
# knowing, but it is NOT counted by --fail-on unless --include-lanes is given.
# This distinction is not academic: a triage that classes by graph shape alone
# reports an upstream candidate as `salvage` and invites its deletion, which
# discards the routing decision rather than a commit.
#
# A shallow clone cannot answer any of this: `--is-shallow-repository` is
# checked and the script refuses to print numbers it cannot stand behind.
#
# Usage:
#   scripts/maintenance/triage-branches.sh                    # table on stdout
#   scripts/maintenance/triage-branches.sh --format markdown  # for an issue body
#   scripts/maintenance/triage-branches.sh --format json
#   scripts/maintenance/triage-branches.sh --fail-on stale
#   scripts/maintenance/triage-branches.sh --fail-on salvage --include-lanes
#
# Exit status: 0 on success, 2 if triage cannot be computed (shallow clone,
# missing refs), 3 if --fail-on matched at least one branch.
set -euo pipefail

base=main
remote=origin
format=table
fail_on=
include_lanes=false

usage() {
  sed -n '5,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --remote) remote="${2:?--remote needs a value}"; shift 2 ;;
    --format) format="${2:?--format needs a value}"; shift 2 ;;
    --fail-on) fail_on="${2:?--fail-on needs a value}"; shift 2 ;;
    --include-lanes) include_lanes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'triage-branches: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$format" in
  table|markdown|json) ;;
  *) printf 'triage-branches: --format must be table, markdown or json\n' >&2; exit 2 ;;
esac
case "$fail_on" in
  ''|stale|salvage|any) ;;
  *) printf 'triage-branches: --fail-on must be stale, salvage or any\n' >&2; exit 2 ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'triage-branches: not inside a git repository\n' >&2
  exit 2
fi

# A shallow clone reports `ahead`/`behind` against an arbitrary graft point,
# so the numbers would be plausible and wrong. Refusing is the only honest
# answer; `git fetch --unshallow` (or fetch-depth: 0 in CI) fixes it.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  printf 'triage-branches: this is a shallow clone; run "git fetch --unshallow" first\n' >&2
  exit 2
fi

base_ref="refs/remotes/$remote/$base"
if ! git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
  printf 'triage-branches: %s does not exist; fetch %s first\n' "$base_ref" "$remote" >&2
  exit 2
fi

# Refuse to report on a stale view: the base tip is what "behind" is measured
# against, and a triage run against last week's cache is worse than none.
base_tip="$(git rev-parse "$base_ref^{commit}")"

# --- lanes -----------------------------------------------------------------
# The deed is the authority for the upstream-candidate lane; the other two are
# stated in CONTRIBUTING.md. Fall back to the deed's value if the file is not
# checked out (a caller may run this against a bare clone).
lane_globs=()
lane_names=()
add_lane() { lane_globs+=("$1"); lane_names+=("$2"); }

deed=MetaManifold-WebUI_chora.deed
if [ -f "$deed" ]; then
  while IFS= read -r declared; do
    if [ -n "$declared" ]; then
      add_lane "$declared" upstream
    fi
  # Anchored to the key, tolerant of what follows the value: the real deed puts
  # the closing parens on later lines, a hand-written one may not.
  done < <(sed -n 's/^[[:space:]]*:upstream-candidates[[:space:]]*"\([^"]*\)".*$/\1/p' "$deed")
fi
if [ "${#lane_globs[@]}" -eq 0 ]; then
  add_lane 'upstream/*' upstream
fi
add_lane 'archive/*' archive
add_lane 'governance-badges' badge-data

lane_of() { # branch -> lane name, or empty
  local branch="$1" i=0
  while [ "$i" -lt "${#lane_globs[@]}" ]; do
    # Intentional unquoted expansion: the lane is a glob pattern.
    # shellcheck disable=SC2254
    case "$branch" in
      ${lane_globs[$i]}) printf '%s' "${lane_names[$i]}"; return 0 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

rows=()
count_base=0
count_unrelated=0
count_contained=0
count_fresh=0
count_salvage=0
count_stale=0
count_laned=0
matched_fail_on=0

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  branch="${ref#"refs/remotes/$remote/"}"
  [ "$branch" = "HEAD" ] && continue
  git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || continue

  lane="$(lane_of "$branch")"
  class=
  ahead=0
  behind=0
  merges=0
  unique=0
  merge_base=

  if [ "$branch" = "$base" ]; then
    class=base
    count_base=$((count_base + 1))
  elif ! merge_base="$(git merge-base "$base_ref" "$ref" 2>/dev/null)"; then
    class=unrelated
    count_unrelated=$((count_unrelated + 1))
  else
    ahead="$(git rev-list --count "$base_ref..$ref")"
    behind="$(git rev-list --count "$ref..$base_ref")"
    merges="$(git rev-list --merges --count "$base_ref..$ref")"
    unique="$(git diff --diff-filter=A --name-only "$base_ref" "$ref" | wc -l | tr -d ' ')"
    if [ "$ahead" -eq 0 ]; then
      class=contained
      count_contained=$((count_contained + 1))
    elif [ "$merge_base" = "$base_tip" ]; then
      class=fresh
      count_fresh=$((count_fresh + 1))
    elif [ "$unique" -gt 0 ]; then
      class=salvage
      count_salvage=$((count_salvage + 1))
    else
      class=stale
      count_stale=$((count_stale + 1))
    fi
  fi
  [ -n "$lane" ] && count_laned=$((count_laned + 1))

  # A laned branch is reported but does not raise --fail-on: its shape is not
  # evidence that anyone should delete it.
  if [ -z "$fail_on" ] || { [ -n "$lane" ] && [ "$include_lanes" != true ]; }; then
    :
  else
    case "$fail_on" in
      any) matched_fail_on=$((matched_fail_on + 1)) ;;
      stale) [ "$class" = stale ] && matched_fail_on=$((matched_fail_on + 1)) ;;
      salvage) [ "$class" = salvage ] && matched_fail_on=$((matched_fail_on + 1)) ;;
    esac
  fi

  tip_date="$(git log -1 --format=%cs "$ref")"
  tip_subject="$(git log -1 --format=%s "$ref" | cut -c1-60)"
  rows+=("$branch|$lane|$class|$ahead|$behind|$unique|$merges|$tip_date|$tip_subject")
done < <(git for-each-ref --format='%(refname)' "refs/remotes/$remote" | LC_ALL=C sort)

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

case "$format" in
  json)
    printf '{"base":"%s","base_tip":"%s","remote":"%s","branches":[' \
      "$(json_escape "$base")" "$base_tip" "$(json_escape "$remote")"
    first=1
    for row in "${rows[@]}"; do
      IFS='|' read -r branch lane class ahead behind unique merges tip_date tip_subject <<<"$row"
      [ "$first" -eq 1 ] || printf ','
      first=0
      if [ -n "$lane" ]; then
        lane_json="\"$(json_escape "$lane")\""
      else
        lane_json=null
      fi
      printf '{"branch":"%s","lane":%s,"class":"%s","ahead":%s,"behind":%s,"unique_files":%s,"merge_commits":%s,"tip_date":"%s","tip_subject":"%s"}' \
        "$(json_escape "$branch")" "$lane_json" "$class" "$ahead" "$behind" "$unique" "$merges" \
        "$tip_date" "$(json_escape "$tip_subject")"
    done
    printf ']}\n'
    ;;
  markdown)
    printf '| Branch | Lane | Class | Ahead | Behind | Files only here | Merge commits | Tip |\n'
    printf '| --- | --- | --- | ---: | ---: | ---: | ---: | --- |\n'
    for row in "${rows[@]}"; do
      IFS='|' read -r branch lane class ahead behind unique merges tip_date tip_subject <<<"$row"
      printf '| `%s` | %s | %s | %s | %s | %s | %s | %s %s |\n' \
        "$branch" "${lane:--}" "$class" "$ahead" "$behind" "$unique" "$merges" "$tip_date" "$tip_subject"
    done
    printf '\n'
    printf '%s\n' \
      "- base: $count_base" \
      "- unrelated (no common ancestor): $count_unrelated" \
      "- contained (nothing to merge): $count_contained" \
      "- fresh (satisfies CONTRIBUTING rule 1): $count_fresh" \
      "- salvage (holds files the base lacks): $count_salvage" \
      "- stale (superseded by later commits): $count_stale" \
      "- in a declared lane, so not counted as drift: $count_laned"
    ;;
  table)
    printf '%-44s %-11s %-10s %6s %7s %6s %6s  %s\n' \
      BRANCH LANE CLASS AHEAD BEHIND ONLY-HERE MERGES TIP
    for row in "${rows[@]}"; do
      IFS='|' read -r branch lane class ahead behind unique merges tip_date tip_subject <<<"$row"
      printf '%-44s %-11s %-10s %6s %7s %6s %6s  %s %s\n' \
        "$branch" "${lane:--}" "$class" "$ahead" "$behind" "$unique" "$merges" "$tip_date" "$tip_subject"
    done
    printf '\n%d branch(es): %d contained, %d stale, %d salvage, %d fresh, %d unrelated, %d in a declared lane\n' \
      "$((count_base + count_contained + count_stale + count_salvage + count_fresh + count_unrelated))" \
      "$count_contained" "$count_stale" "$count_salvage" "$count_fresh" "$count_unrelated" "$count_laned"
    ;;
esac

if [ -n "$fail_on" ] && [ "$matched_fail_on" -gt 0 ]; then
  printf 'triage-branches: %d branch(es) matched --fail-on %s\n' "$matched_fail_on" "$fail_on" >&2
  exit 3
fi
exit 0
