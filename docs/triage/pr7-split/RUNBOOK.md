<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Runbook — landing parent PR #7 in reviewable pieces

Parent PR [JoshuaJewell/MetaManifold-WebUI#7][p7] is **CLEAN and mergeable
as-is**. The 14 stacks in this kit exist so a human can *understand* the
319-file change — you do not have to split the PR to land it. Pick one:

- **Option A (recommended): merge #7 as-is**, reviewing stack-by-stack
  from this kit. Least process, same comprehension.
- **Option B: 14 stacked PRs.** Close #7, open one PR per stack, merge in
  order. Most review surface per PR, most process.
- **Option C: close #7 and re-do the work.** Not recommended — the branch
  is the only copy of this work and it merges cleanly.

All commands run on **your** machine with **your** credentials (the Arena
bot cannot push branches or act on the parent repo).

## 0. One-time setup

```sh
git clone https://github.com/JoshuaJewell/MetaManifold-WebUI.git mm-parent
cd mm-parent
# The split kit lives on the fork until it merges; fetch it:
git fetch https://github.com/hyperpolymath/MetaManifold-WebUI.git \
  arena/01a0dd12-metamanifold-webui
git checkout FETCH_HEAD -- docs/triage/pr7-split
# The two endpoints of PR #7:
git fetch origin main:refs/remotes/upstream/main
git fetch https://github.com/hyperpolymath/MetaManifold-WebUI.git \
  feat/stipple-typed-studies-ui:refs/remotes/fork/stipple
# Regenerate + verify the 14 patches (checks coverage AND tree equality):
UPSTREAM_REF=refs/remotes/upstream/main BRANCH_REF=refs/remotes/fork/stipple \
  docs/triage/pr7-split/make-stacks.sh
```

Expected: `OK: all stacks, disjoint, cover all 319 files.` then
`OK: stacks applied in order reproduce the branch tree exactly.`

## Option A — review by stack, merge #7 whole (recommended)

1. Read `STACKS.md`, then review each stack's patch in order:
   `patches/01-repo-roots.patch` … `patches/14-bench-scripts.patch`.
   Suggested focus per stack is in `STACKS.md`; anything marked
   "1-line" is almost always just the SPDX header.
2. Run the checks the branch itself carries (upstream CI runs `ci.yml`
   from the PR):
   ```sh
   git checkout -b review/pr7 refs/remotes/fork/stipple
   # …run the project's documented checks…
   ```
3. Merge #7 on GitHub (or `gh pr merge 7 --repo
   JoshuaJewell/MetaManifold-WebUI --squash|--merge` from your account).
4. Delete the `feat/stipple-typed-studies-ui` branch on the fork once
   merged, so it stops shadowing future diffs.

## Option B — 14 stacked PRs

```sh
cd mm-parent
base=upstream/main   # after the fetches in §0
prev="$base"
for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  spec="docs/triage/pr7-split/stacks/$n-"*.paths
  name="$(basename "$spec" .paths)"
  branch="pr7-stack/$name"
  git checkout -b "$branch" "$prev"
  git apply --index "docs/triage/pr7-split/patches/$name.patch"
  git -c commit.gpgsign=false commit -m "pr7-stack: $name" --no-verify
  git push -u origin "$branch"
  gh pr create --repo JoshuaJewell/MetaManifold-WebUI \
    --base "${prev#upstream/}" --head "$branch" \
    --title "$(grep "| $n |" docs/triage/pr7-split/STACKS.md \
      | sed 's/.*| //')" \
    --body "Stack $n of 14 splitting #7 (see STACKS.md in
hyperpolymath/MetaManifold-WebUI \`docs/triage/pr7-split/\`).
Base: \`${prev}\`. Merge in numeric order; closes part of #7."
  prev="$branch"
done
```

Notes:

- Pushes go to `origin` = the **parent** repo, so run this with an
  account that can push there (yours).
- The `--title` extraction reads the suggested title from the `STACKS.md`
  table; adjust wording per PR before sending.
- Merge 01→14 in order (each PR's base is the previous stack's branch;
  retarget to `main` as each lands, or merge the chain at the end).
- Close #7 with a comment pointing at the stack once stack 01 opens —
  or keep #7 open as the tracking issue until 14 lands.
- If a stack needs fixes during review, commit on that stack's branch
  and `git rebase --update-refs` the children (they are disjoint file
  sets, so rebases are conflict-free by construction).

## Appendix 1 — closing the three dead parent PRs

Parent PRs #8, #10 and #11 have **deleted head branches**, render as
60k-line whole-tree noise, and their real deltas (2 commits, 0 commits,
1 commit respectively) are already on fork `main` (verified
patch-identical: `6c29b53b`, `c0be9516`, `0ef5eeec`). They can never
merge. The bot has no write access to the parent repo, so close them
from your account:

```sh
for n in 8 10 11; do
  gh pr close "$n" --repo JoshuaJewell/MetaManifold-WebUI \
    --comment "Closing: head branch deleted and the real delta is already
on hyperpolymath/MetaManifold-WebUI main (verified patch-identical;
see fork triage report docs/triage/2026-09-26-notification-backlog.md).
This PR rendered as whole-tree noise after the fork's git-filter-repo
rewrite and can never merge. Reopen if you disagree."
done
```

## Appendix 2 — unblocking CI (owner action, both repos)

Since 2026-09-25 22:19 UTC **every file-based workflow run**
(`CI`, `DOI publication contracts`, `Stipple UI contracts`, incl. the
long-untouched `ui.yml`) ends in `startup_failure` with zero jobs, for
bot actors and Dependabot alike — while dynamic CodeQL/Dependabot runs
succeed. The workflow files are active and unchanged-at-the-break, so
this is a settings/platform-side block, not a code break. On each repo:

1. Open any failed run (e.g. fork run `36210537997`) and read the exact
   banner text (a previous session reported
   "Actor is not allowed to trigger Actions workflows").
2. Settings → Actions → General: confirm the Actions permissions level
   allows these workflows, and check fork-PR / third-party-action
   restrictions if the repos sit under an organisation policy.
3. Push an empty commit from your **human** account and confirm a `CI`
   run starts — this discriminates "bot actors blocked" from
   "Actions broken for everyone".
4. If human pushes fail identically, raise it with GitHub Support
   (platform-side incident) — and re-run the failed Dependabot Updates
   run on fork `main` once green (`gh run rerun 36210545146`).
5. Until CI runs again, PRs cannot go green: any stack PRs from this
   kit are gated on this fix — and fork PR #75 (merged 2026-09-26
   without green CI, closing fork issue #20) still owes its
   post-merge verification (first real Julia execution of its tests).

[p7]: https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/7
