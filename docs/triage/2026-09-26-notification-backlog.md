<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Notification-backlog triage — 2026-09-26

Request: clear the [GitHub notifications][notif] backlog — finish chores,
close issues, resolve unmergeable PRs, and split huge PRs into mergeable,
comprehensible pieces.

Caveat first: the Arena bot token cannot read the personal
`/notifications` page (API: `403 Resource not accessible by
integration`), so this triage reconstructs the backlog from public repo
state instead: all open PRs/issues on the fork
(`hyperpolymath/MetaManifold-WebUI`) and the parent
(`JoshuaJewell/MetaManifold-WebUI`), plus Actions health. If a
notification is not covered below, point at it and it gets triaged next.

Note: the owner merged fork PR #75 **during this triage** (09:47 UTC);
the report was updated to match. Fork open PRs are now **zero**.

## TL;DR

| Item | Verdict |
|------|---------|
| Fork PR #73 (338 files, conflicting) | **Closed by this triage** — wrong-base duplicate of parent #7 |
| Fork PR #75 (71 files, ILR bases) | **Merged by the owner during triage** (09:47 UTC) → fork issue #20 auto-closed. Post-merge verification still owed (below) |
| Parent PRs #8, #10, #11 (300+ files, conflicting) | **Close them** (owner click — bot has no parent write access; commands in `pr7-split/RUNBOOK.md`). Head branches deleted, real deltas already on fork `main` |
| Parent PR #7 (319 files, clean) | **Keep.** Split into 14 verified stacks: `pr7-split/` (`STACKS.md`, `RUNBOOK.md`, `make-stacks.sh`) |
| CI on the fork | **Broken repo-wide since 2026-09-25 22:19 UTC** — every file-based workflow `startup_failure`s with zero jobs, including the #75 merge commit. Settings/platform-side; owner action required (runbook appendix 2) |
| Fork issues (12 open; #20 closed by the #75 merge) | **All remaining stay open** — verified one by one (epic gate, recorded deferrals). Closing any of them now would contradict recorded owner decisions |
| Branch `arena/01a0db67` (no PR) | **Deleted at owner's request** — content preserved in `docs/triage/db67-rescue/` (stale docs branch, not DOI-deleting — see report) |
| Parent issue #12 (owner memo) | Awaits the addressee's eyes; summarised below, not closed |
| Dependabot Updates on fork `main` | **Two consecutive failures** (`36210545146`, `36233872771`); re-run once CI is fixed |

## Actions taken by this triage

1. **Closed fork PR #73** with an explanatory comment ([comment][c73]):
   same head branch (`feat/stipple-typed-studies-ui` @ `eab8ea0`) is open
   upstream as parent #7 where it is CLEAN; the fork-side PR rendered as
   338-file / +65k whole-tree noise after the fork's `git-filter-repo`
   rewrite severed the merge base back to the initial commit, and was
   CONFLICTING. Branch untouched; nothing lost.
2. Recovered the three **deleted head commits** of parent PRs #8/#10/#11
   by SHA from the fork (`f451f1c0`, `c0be9516`, `b46aee09`) and proved
   their content is already on fork `main` (`git cherry` patch-identical:
   `6c29b53b`, ancestor, `0ef5eee`). Wrote the close comments + commands
   for the owner (bot is `403` on the parent).
3. Built the **parent-#7 split kit** (`docs/triage/pr7-split/`): 14
   disjoint stacks covering all 319 files, verified to reproduce the
   branch tree byte-for-byte, with per-stack review guide and runbook.
4. Diagnosed the **CI outage** (evidence below) to a settings/platform
   cause with owner fix steps.
5. Audited all open fork issues against merged work: #20 closed by the
   #75 merge; none of the rest qualifies for closure (details below).
6. Merged the #75 merge commit into this branch, resolving the one
   `.gitignore` clash (kept both sides: `docs/formal/` + `docs/triage/`).

## The huge PRs, explained

All four 300+ file PRs are the same disease with different prognoses.
On ~2026-09-24/25 fork `main` was rewritten with `git-filter-repo`
(~260 MiB of dead blobs stripped; HEAD tree byte-identical — see the
parent #7 description). The rewrite severed every merge base back to the
initial commit, so any branch diffed against the "wrong" base renders as
a whole-tree diff:

- **Parent #7** (319 files, +22,662/−404): branch is `upstream/main` + 3
  commits, so the diff is REAL and the PR is CLEAN. Genuinely large →
  split kit provided.
- **Fork #73** (338 files, +65,571/−22): same branch against rewritten
  fork `main` → noise + conflicts → closed as duplicate.
- **Parent #8/#10/#11** (~315–345 files, ~+60k): branches cut from
  fork `main`, PR'd at upstream `main` (July snapshot) → noise; real
  deltas were 2/0/1 commits, all now on fork `main`; branches deleted
  → close.

## Fork PR #75 — merged during triage (verification owed)

`feat(analysis): PhILR, SBP and balance-dendrogram ILR bases`
(`e2adbb9`, 71 files, +6,918/−78) was merged by the owner at 09:47 UTC
with CI `startup_failure` and CodeFactor FAILURE — i.e. the PR's own
"Closes #20 once CI is green" condition was bypassed, and fork issue
#20 auto-closed. That is the owner's call to make; the owed follow-up:

1. Once CI runs again, confirm the `CI` + `DOI publication contracts`
   lanes pass on the merge commit — the PR author never executed Julia
   in their sandbox, so CI is the first real execution of the new tests,
   reference implementation and benchmarks.
2. Check whether the CodeFactor FAILURE flagged anything actionable in
   the merged code.
3. Re-run Dependabot Updates (failed twice on `main`).

## CI outage — evidence

- Since 2026-09-25 22:19 UTC, **100% of file-based workflow runs** end
  `startup_failure` with **zero jobs**: `CI`, `DOI publication
  contracts`, `Stipple UI contracts` — on `main` pushes, PRs, bot and
  Dependabot actors alike (e.g. runs `36210930780`, `36210537997`,
  `36196688881`, and the #75 merge runs `36233864893`/`36233864472`).
- The break is **not the workflow files**: `ui.yml` last ran green on
  2026-09-21, is unchanged since, and fails identically now. All
  workflows report `active`. Before 22:19 the same files executed jobs
  (red, but running).
- Dynamic (non-file) workflows still run: CodeQL succeeds on the same
  commits; Dependabot Updates jobs execute (and fail on their own
  merits).
- A previous session saw the UI banner: *"Actor is not allowed to
  trigger Actions workflows"*; `gh run rerun` is refused
  ("workflow file may be broken" — GitHub's stock message for
  un-rerunnable startup failures).
- A sibling probe branch (`arena/01a0db23`, "probe whether file-based
  workflows can start here") also startup-fails.

Conclusion: settings- or platform-side block on starting file-based
workflows. Owner steps: read the exact banner on any failed run,
check Settings → Actions → General on both repos, push a no-op commit
from a human account to discriminate actor-block vs global break, and
escalate to GitHub Support if humans fail too. Full steps in
`pr7-split/RUNBOOK.md` appendix 2. **Everything merge-gated waits on
this**: any #7 stack PRs, Dependabot, and post-merge verification of #75.

## Issues — why the remaining 12 stay open

| # | Issue | Why it stays open |
|---|-------|-------------------|
| 1 | Validated Julia statistics layer (epic) | 14-item acceptance gate ending in *independent review + explicit owner approval*; the issue text says closing it administratively does not open the symbolic gate |
| 2 | BLOCKED symbolic-engine gate | Blocked by #1 by recorded owner decision; it is the gate, not work |
| 3 | Exact statistics (Fisher/exact-NB/permutation) | Recorded owner *decision* to defer (catalogue item 4, excluded from v1); code shows only refusal/doc mentions |
| 4 | Symbolic engine for formulae | Deferred; gated by #1/#2 |
| 5 | ANCOM-BC / ALDEx2 / Songbird | Deferred; no implementation merged |
| 6 | CladeCumulus phylogenetic integration | Deferred; `clade_cumulus.jl` exists on the PR branch, not merged |
| 7 | Full Evidence Mode | Deferred; PR #74 added only a minimal DOI publication page + launcher |
| 8 | Zenodo integration | PR #74 says explicitly "No issue is being closed by this PR" — needs live sandbox acceptance + baselines first |
| 17 | Multinomial / Dirichlet-Multinomial | Deferred roadmap item, no PR |
| 18 | Occupancy / ZINB / hurdle models | Deferred roadmap item, no PR |
| 19 | Constrained ordinations | Deferred roadmap item, no PR |
| 21 | Advanced zero handling | Deferred roadmap item, no PR (PR #75 shares Agda groundwork with it) |

Closed during this triage: **#20** (by the #75 merge). Previously
closed issues (#9–#16, e.g. #9 AnalysisConfig v1) stay closed.

## Flag (resolved): branch `arena/01a0db67-metamanifold-webui`

**Update: deleted on 2026-09-26 at the owner's request; content preserved
in `docs/triage/db67-rescue/`** (`deleted-branch.patch` recreates the
branch tree byte-for-byte; restore commands in that directory's
`README.md`). Branch head at deletion: `d94ecd4e99dbda819fdc0fe1913d5caaabca414a`.

Correction to the first triage note: this branch did **not** actively
delete the DOI subsystem. It was three docs commits on the pre-DOI base
`e33e10f`, so diffed against current `main` it merely *appeared* to
delete `src/doi/*` and the ILR work (base-difference noise — a GitHub
3-way merge would not have reverted PR #74/#75). Its genuine content was
a BerryWiki wiki (`docs/wikis/`, 33 pages), `README.adoc`/`EXPLAINME.adoc`,
the autolink spec, and prose updates to `CHANGELOG`/`CONTRIBUTING`/`NOTICE`
— plus a `README.md` deletion and 32 wiki pages missing SPDX headers,
which were the real landmines and the reason for closing it.

Also already gone: the merged PR #75 branch (`arena/01a0db2e`) was
auto-deleted on merge. Still open and deliberately untouched: the CI
probe branch `arena/01a0db23` (unmerged, no PR — needs its own decision)
and `feat/stipple-typed-studies-ui` (live as parent PR #7).

## Parent issue #12 (owner memo, 0 comments)

"Notice to Project Owner: Comprehensive Review & Roadmap Status
(2026-09-25)" — a long plain-English memo addressed to the project
owner explaining the fork's work (fake-number removal, real models,
refuse-to-guess, the four parent PRs). It is FYI, not actionable, and
needs the *addressee's* eyes before closing — left open deliberately.

## Suggested order of operations for the owner

1. Fix CI (runbook appendix 2) — unblocks everything.
2. Close parent #8/#10/#11 (one command each, runbook appendix 1).
3. Decide parent #7: Option A merge-as-is (review via `STACKS.md`) or
   Option B stacked PRs (`RUNBOOK.md`).
4. ~~Decide `arena/01a0db67`~~ — done: branch deleted, content preserved
   in `docs/triage/db67-rescue/`. Remaining: decide the CI probe branch
   `arena/01a0db23` (unmerged, no PR).
5. Read parent #12, then close it.
6. Post-merge verification of #75 once CI runs (Julia tests, CodeFactor
   findings, Dependabot re-run).

[notif]: https://github.com/notifications
[c73]: https://github.com/hyperpolymath/MetaManifold-WebUI/pull/73#issuecomment-5845153601
[p7]: https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/7
