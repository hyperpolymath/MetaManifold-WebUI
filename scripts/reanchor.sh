#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Hyperpolymath engineering series
#
# reanchor.sh — turn the fork↔upstream divergence into a GRANULAR history.
#
# WHY
# ---
# The fork and upstream share the root commit ("Initial commit", 7884553) but
# diverged at the second commit and then developed in parallel (fork: ~221
# commits; upstream: ~89). Because BOTH sides changed almost everything from a
# near-empty base, a single `git merge` surfaces ~159 conflicting files at once
# (see docs/integration/conflict-map-2026-09-25.md).
#
# Re-anchoring fixes this: `git rebase --onto upstream/main <base> <fork>`
# replays the fork's commits ONE AT A TIME onto upstream. Git auto-applies every
# commit that does not collide, and surfaces only the genuine overlaps — as a
# sequence of tiny, per-commit decisions instead of one wall. Measured 2026-09-25
# with the default policy: the whole fork re-anchors with THREE decisions (all
# "upstream deleted this file"), leaving 0 residual conflicts.
#
# The result is a granular branch — upstream's history, then the fork's ~206
# commits on top — that (a) the maintainer can review/merge incrementally or all
# at once, and (b) shares a real merge base with upstream, so FUTURE upstream
# changes merge cleanly too.
#
# Doctrine: fail loudly; no hidden dependencies (bash + git + awk); never touch
# the caller's working tree or current branch (all work happens in a worktree).
#
# Usage: scripts/reanchor.sh <command> [options]
#   plan                     Read-only: classify each fork commit (auto / overlap / delete-risk)
#   run [options]            Perform the re-anchor in a worktree (see options)
#   status                   Report an in-progress re-anchor
#
# run options:
#   --policy theirs|manual   theirs (default): auto-resolve content in the fork's
#                            favour and respect upstream's deletions — the whole
#                            fork lands with a handful of logged decisions.
#                            manual: stop at every conflict for hands-on review.
#   --branch NAME            Create/point branch NAME at the result (default: none, detached)
#   --worktree PATH          Where to build (default: $TMPDIR/metamanifold-reanchor)
#   --keep                   Leave the worktree in place afterwards (default: remove on success)
#
# Env: UPSTREAM_REMOTE (default upstream), FORK_REMOTE (default origin),
#      UPSTREAM_REF (default main), FORK_REF (default main).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
FORK_REMOTE="${FORK_REMOTE:-origin}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
FORK_REF="${FORK_REF:-main}"
UPSTREAM="$UPSTREAM_REMOTE/$UPSTREAM_REF"
FORK="$FORK_REMOTE/$FORK_REF"

die() { printf 'reanchor: %s\n' "$*" >&2; exit 1; }

require_ref() { git rev-parse -q --verify "$1" >/dev/null 2>&1 || die "ref not found: $1 (fetch it first, e.g. 'git fetch $UPSTREAM_REMOTE')"; }

find_base() {
    local b; b="$(git merge-base "$UPSTREAM" "$FORK" 2>/dev/null || true)"
    [ -n "$b" ] || die "no common ancestor between $UPSTREAM and $FORK — re-anchoring is not possible; use the profile/triage path instead (just integrate)"
    printf '%s\n' "$b"
}

preflight() {
    require_ref "$UPSTREAM"
    require_ref "$FORK"
    # Only uncommitted TRACKED changes block; the rebase runs in an isolated
    # worktree at the fork ref, so untracked files are irrelevant to it.
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted tracked changes present — commit or stash before re-anchoring"
    local gd; gd="$(git rev-parse --git-dir)"
    if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
        die "a rebase is already in progress — finish or 'git rebase --abort' first"
    fi
}

# --------------------------------------------------------------------------- #
cmd_plan() {
    require_ref "$UPSTREAM"; require_ref "$FORK"
    local base; base="$(find_base)"
    printf 'Fork        : %s (%s)\n' "$FORK" "$(git rev-parse --short "$FORK")"
    printf 'Upstream    : %s (%s)\n' "$UPSTREAM" "$(git rev-parse --short "$UPSTREAM")"
    printf 'Merge base  : %s  %s\n' "$(git rev-parse --short "$base")" "$(git log -1 --format='%s' "$base")"
    printf 'Fork commits since base : %s\n' "$(git rev-list --count "$base..$FORK")"
    printf 'Upstream commits since base : %s\n' "$(git rev-list --count "$base..$UPSTREAM")"
    echo ""

    git diff --name-only "$base" "$UPSTREAM" | sort -u > /tmp/.reanchor_up.$$ 2>/dev/null || true
    local upchanged=/tmp/.reanchor_up.$$
    printf 'Upstream changed %s file(s) since base.\n\n' "$(wc -l < "$upchanged" | xargs)"

    # Files upstream DELETED but the fork still touches → modify/delete hotspots.
    git diff --diff-filter=D --name-only "$base" "$UPSTREAM" | sort -u > /tmp/.reanchor_del.$$ 2>/dev/null || true
    local updeleted=/tmp/.reanchor_del.$$

    local clean=0 overlap=0 c files ov tot
    printf '%-8s %-6s %-9s %s\n' "CLASS" "OVLAP" "RISK" "COMMIT"
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        files="$(git show --name-only --format= "$c" 2>/dev/null || true)"
        [ -n "$files" ] || continue
        ov="$(comm -12 <(printf '%s\n' "$files" | sort -u) "$upchanged" | wc -l | xargs)"
        tot="$(printf '%s\n' "$files" | grep -c . || true)"
        if [ "$ov" -eq 0 ]; then
            clean=$((clean+1))
        else
            overlap=$((overlap+1))
            # delete-risk: does this commit touch a file upstream deleted?
            local delrisk="-"
            comm -12 <(printf '%s\n' "$files" | sort -u) "$updeleted" | grep -q . && delrisk="DELETE"
            printf '%-8s %-6s %-9s %s\n' "overlap" "$ov/$tot" "$delrisk" "$(git log -1 --format='%h %s' "$c")"
        fi
    done < <(git rev-list "$base..$FORK")

    echo ""
    printf 'SUMMARY: %s commit(s) auto-apply (touch only fork-owned files); %s overlap upstream.\n' "$clean" "$overlap"
    printf 'A one-shot merge would show all overlaps at once; a re-anchor resolves them per commit.\n'
    printf 'Next: scripts/reanchor.sh run            (automated, fork-wins, logged decisions)\n'
    rm -f "$upchanged" "$updeleted"
}

# --------------------------------------------------------------------------- #
cmd_run() {
    local policy="theirs" branch="" wt="${TMPDIR:-/tmp}/metamanifold-reanchor" keep=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --policy) policy="${2:?--policy needs a value}"; shift 2;;
            --branch) branch="${2:?--branch needs a name}"; shift 2;;
            --worktree) wt="${2:?--worktree needs a path}"; shift 2;;
            --keep) keep=1; shift;;
            *) die "run: unknown option '$1'";;
        esac
    done
    case "$policy" in theirs|manual) ;; *) die "--policy must be 'theirs' or 'manual'";; esac

    preflight
    local base; base="$(find_base)"

    rm -rf "$wt"
    git worktree add --detach "$wt" "$FORK" >/dev/null 2>&1 || die "could not create worktree at $wt"
    # shellcheck disable=SC2064
    trap "cd '$ROOT'; git worktree remove --force '$wt' >/dev/null 2>&1 || true" EXIT

    cd "$wt"
    export GIT_EDITOR=true
    printf 'reanchor: rebasing %s onto %s (policy=%s, base=%s)\n' "$FORK" "$UPSTREAM" "$policy" "$(git rev-parse --short "$base")"
    local decisions=/tmp/.reanchor_decisions.$$; : > "$decisions"
    git -c core.editor=true rebase --onto "$UPSTREAM" "$base" -X theirs >/dev/null 2>&1 || true

    local gd; gd="$(git rev-parse --git-dir)"
    local iters=0
    while [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; do
        iters=$((iters+1))
        [ "$iters" -gt 400 ] && { printf 'reanchor: SAFETY CAP hit (%s iterations) — leaving the rebase in place for inspection.\n' "$iters" >&2; return 3; }
        local cf; cf="$(git diff --name-only --diff-filter=U)"
        if [ -z "$cf" ]; then git -c core.editor=true rebase --continue >/dev/null 2>&1 || true; continue; fi
        local cur; cur="$(git log -1 --format='%h %s' REBASE_HEAD 2>/dev/null || echo '?')"
        if [ "$policy" = "manual" ]; then
            printf '\nreanchor: STOPPED for manual review at %s\n' "$cur" >&2
            printf 'Conflicted files:\n%s\n' "$cf" >&2
            printf 'Resolve, then: git -C %s rebase --continue   (or: git -C %s rebase --abort)\n' "$wt" "$wt" >&2
            return 2
        fi
        local f
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if git cat-file -e "$UPSTREAM":"$f" 2>/dev/null; then
                if git checkout --theirs -- "$f" 2>/dev/null && git add -- "$f" 2>/dev/null; then
                    printf 'CONTENT fork-wins : %s   [%s]\n' "$f" "$cur" >> "$decisions"
                else
                    git rm -f -- "$f" >/dev/null 2>&1 && printf 'DELETE  (fork)    : %s   [%s]\n' "$f" "$cur" >> "$decisions"
                fi
            else
                git rm -f -- "$f" >/dev/null 2>&1 && printf 'DELETE  (upstream): %s   [%s]\n' "$f" "$cur" >> "$decisions"
            fi
        done <<< "$cf"
        git -c core.editor=true rebase --continue >/dev/null 2>&1 || true
    done

    local ahead; ahead="$(git rev-list --count HEAD --not "$UPSTREAM")"
    local residual; residual="$(git diff --name-only --diff-filter=U | wc -l | xargs)"
    printf '\nreanchor: COMPLETE.\n'
    printf '  granular commits on top of upstream : %s\n' "$ahead"
    printf '  residual conflicts                  : %s\n' "$residual"
    printf '  decisions the policy made           : %s\n' "$(grep -c . "$decisions" || echo 0)"
    if [ -s "$decisions" ]; then printf '\n  --- decisions ---\n'; sed 's/^/  /' "$decisions"; fi
    local drift; drift="$(git diff --name-only "$FORK" HEAD | wc -l | xargs)"
    printf '\n  files the re-anchored tree keeps that the fork dropped (review these): %s\n' "$drift"
    git diff --name-only "$FORK" HEAD | sed 's/^/    /' | head -20

    if [ -n "$branch" ]; then
        git branch -f "$branch" HEAD >/dev/null 2>&1 && printf '\n  branch %s -> %s\n' "$branch" "$(git rev-parse --short HEAD)"
    fi
    printf '\nNext:\n'
    printf '  review : git -C %s log --oneline %s..HEAD | head\n' "$wt" "$UPSTREAM"
    printf '  stray build output (e.g. web/dist) is upstream-committed; drop it: git -C %s rm -r web/dist\n' "$wt"
    printf '  land  : merge this granular branch into upstream, or cherry-pick tiers.\n'

    rm -f "$decisions"
    if [ "$keep" -eq 1 ]; then trap - EXIT; printf '\n(worktree kept at %s)\n' "$wt"; fi
    return 0
}

cmd_status() {
    local gd; gd="$(git rev-parse --git-dir)"
    if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
        echo "reanchor: a rebase is in progress."
        git status | sed -n '1,8p'
    else
        echo "reanchor: no re-anchor in progress."
    fi
}

usage() { sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        plan)   cmd_plan "$@";;
        run)    cmd_run "$@";;
        status) cmd_status "$@";;
        ""|help|-h|--help) usage;;
        *) die "unknown command '$cmd' (try: plan|run|status)";;
    esac
}

main "$@"
