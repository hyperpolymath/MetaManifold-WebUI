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

## TL;DR

| Item | Verdict |
|------|---------|
| Fork PR #73 (338 files, conflicting) | **Closed by this triage** — wrong-base duplicate of parent #7 |
| Parent PRs #8, #10, #11 (300+ files, conflicting) | **Close them** (owner click — bot has no parent write access; commands in `pr7-split/RUNBOOK.md`). Head branches deleted, real deltas already on fork `main` |
| Parent PR #7 (319 files, clean) | **Keep.** Split into 14 verified stacks: `pr7-split/` (`STACKS.md`, `RUNBOOK.md`, `make-stacks.sh`) |
| Fork PR #75 (71 files, draft) | **Keep.** Blocked on CI (see below) + draft + CodeFactor; reviewed, not touched |
| CI on the fork | **Broken repo-wide since 2026-09-25 22:19 UTC** — every file-based workflow `startup_failure`s with zero jobs. Settings/platform-side; owner action required (runbook appendix 2) |
| Fork issues #1–#8, #17–#21 (13 open) | **All stay open** — verified one by one (epic gate, recorded deferrals, or live PRs). Closing any of them now would contradict recorded owner decisions |
| Branch `arena/01a0db67` (no PR) | **Flagged: deletes the entire DOI subsystem.** Needs an owner decision (delete vs rework) |
| Parent issue #12 (owner memo) | Awaits the addressee's eyes; summarised below, not closed |
| Dependabot Updates run `36210545146` | Single failure on fork `main`; re-run once CI is fixed |

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
5. Audited all 13 open fork issues against merged work: none qualifies
   for closure (details below).

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

## CI outage — evidence

- Since 2026-09-25 22:19 UTC, **100% of file-based workflow runs** end
  `startup_failure` with **zero jobs**: `CI`, `DOI publication
  contracts`, `Stipple UI contracts` — on `main` pushes, PRs, bot and
  Dependabot actors alike (e.g. runs `36210930780`, `36210537997`,
  `36196688881`).
- The break is **not the workflow files**: `ui.yml` last ran green on
  2026-09-21, is unchanged since, and fails identically now. All
  workflows report `active`. Before 22:19 the same files executed jobs
  (red, but running).
- Dynamic (non-file) workflows still run: CodeQL succeeds on the same
  commits; a Dependabot Updates job executed (and failed on its own
  merits) at 02:04.
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
this**: fork PR #75, any #7 stack PRs, Dependabot.

## Fork PR #75 (ILR bases, closes #20) — blockers

`feat(analysis): PhILR, SBP and balance-dendrogram ILR bases` — 71 files,
+6,918/−78, MERGEABLE, DRAFT, 6 commits. Well-scoped; needs no split.
Blockers, in order: (1) CI cannot run (above) — the PR itself says
"Closes #20 once CI is green"; (2) DRAFT status (author's call);
(3) CodeFactor FAILURE vs CodeQL/semgrep green — check whether it flags
new code; (4) author's own caveats (Julia never executed in the
authoring sandbox; Agda proofs type-check; frontend 613 pass). Left for
the owning session + owner; this triage did not touch it.

## Issues — why all 13 stay open

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
| 20 | ILR bases (PhILR/SBP/dendrogram) | Live work: fork PR #75 open, "Closes #20 once CI is green" |
| 21 | Advanced zero handling | Deferred roadmap item, no PR (PR #75 shares Agda groundwork with it) |

Previously closed issues (#9–#16, e.g. #9 AnalysisConfig v1) stay closed.

## Flag: branch `arena/01a0db67-metamanifold-webui` (no PR)

Three docs commits on top of current `main` that **delete the entire
DOI subsystem** (39 files: `src/doi/*`, `src/server/routes/doi.jl`,
`test/doi/*`, `test/unit/test_doi*.jl`, `doi.yml`, `scripts/link-doi.sh`,
DOI docs/schemas/templates, `LICENSES/CC-BY-4.0.txt`) while adding
`README.adoc`/`EXPLAINME.adoc` + a `docs/wikis/` dump (91 files changed,
+4,239/−7,547). No PR is open, so it is dormant — but if it ever merges
it silently reverts PR #74. Owner decision needed: delete the branch, or
rescue the wiki docs onto a branch without the deletions. The bot will
not delete another session's branch unasked.

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
4. Decide `arena/01a0db67` (delete vs rescue-docs).
5. Read parent #12, then close it.
6. Re-run Dependabot Updates on fork `main`; re-check fork PR #75 and
   undraft/merge when green.

[notif]: https://github.com/notifications
[c73]: https://github.com/hyperpolymath/MetaManifold-WebUI/pull/73#issuecomment-5845153601
[p7]: https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/7
