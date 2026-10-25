<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Repository hygiene: branches, pull requests and CI cost

This document records how branches are classed, what happens to each class, and
the measurement taken on 2026-10-25 with the actions that followed. It exists
because the repository reached a state where the cost of a stale branch was not
its storage but its silence: thirteen branches shared one list, each with an
open pull request, and none of them could be told apart from a fresh change
without doing the comparison by hand.

The rule the repository already had is in [CONTRIBUTING.md](../../CONTRIBUTING.md):
a branch starts at the tip of `main` (rule 1) and carries no merge commits from
it (rule 2). Nothing enforced either sentence. This document describes the
enforcement added on 2026-10-25 and the cleanup it made possible.

## Classes

`scripts/maintenance/triage-branches.sh` measures every remote head against the
base branch and prints one class per branch. It never writes to the remote: the
reading is cheap and repeatable, the decision is not automatic.

| Class | Meaning | What happens to it |
| --- | --- | --- |
| `base` | The base branch itself. | Nothing. |
| `unrelated` | No common ancestor with the base. In this repository that is `governance-badges` only, the orphan branch the `Publish badges` job force-pushes on every push to `main`. | Never delete. It holds shields.io endpoint JSON read through `img.shields.io/endpoint`; it has no pull request and never will. |
| `contained` | Every commit is already an ancestor of the base (`ahead` is 0). | The pull request is closed and the branch deleted. There is nothing to merge; the displayed diff is the base moving ahead. Any file it still "has" that the base does not was deliberately deleted from the base later. |
| `fresh` | Merge base is the base tip. It satisfies rule 1. | Eligible for review. Rule 2 is checked separately by `check-pr-freshness.sh`, which fails a `fresh` branch that carries a merge commit. |
| `salvage` | Behind the base, but it carries at least one file the base does not have. | Do **not** merge it: it would revert later work on every file it also touches. Its unique files are re-applied on the current tip, or the branch is deliberately abandoned. Closing the pull request preserves the content at `refs/pull/<n>/head`; see [Recovery](#recovery). |
| `stale` | Behind the base, and every file it touches also exists in the base. | Closed and deleted. Merging it would revert the commits that superseded it. |

A shallow clone cannot answer any of this: it reports its graft point as the
merge base, which makes every branch look `fresh`. Both scripts refuse to run in
a shallow clone (`git fetch --unshallow`, or `fetch-depth: 0` in CI) rather than
print a number they cannot stand behind.

## Enforced, not just written down

| Where | What it does |
| --- | --- |
| `.github/workflows/pr-freshness.yml` | Runs `scripts/maintenance/check-pr-freshness.sh` on every pull request open, push, reopen and ready-for-review. Fails with a check annotation naming how far behind the branch is, or which merge commit breaks rule 2. |
| `.github/workflows/branch-hygiene.yml` | Weekly, and on demand: runs the triage and updates **one** rolling issue, closing it when no drifted branch remains. One issue updated in place, because a job that opens an issue every week is the mechanism that produced the pile it is meant to clear. |
| `scripts/tests/test-triage-branches.sh`, `scripts/tests/test-check-pr-freshness.sh` | Both scripts are tested against fixture repositories: merged, drifted-with-nothing-new, drifted-with-a-dropped-file, orphan, unrelated-history and shallow cases. They run with the other shell tests in the `Advisory scan contract` job. |

The pull-request check is advisory by configuration, not by intent: GitHub only
blocks a merge on a check named in a ruleset. Adding **Branch freshness** to the
`Branch-Floor` ruleset is an owner action (Settings → Rules → Branch-Floor), and
it can only be done *after* this workflow is on `main` — a required check that no
workflow produces blocks every pull request, including the one that would add it.

## Recovery

Deleting a branch does not delete its pull request, and a closed pull request
keeps its head reachable:

```
git fetch origin pull/<n>/head:review/pr-<n>
git log --oneline main..review/pr-<n>
```

That is the difference between cleaning up and losing work, and it is why the
2026-10-25 cleanup closed pull requests before deleting the branches instead of
deleting the branches and hoping.

## Measurement, 2026-10-25

`main` at `f3816e5a`. Fifteen remote heads, thirteen of them with an open pull
request. Every one of the thirteen violated CONTRIBUTING rule 1; one also
violated rule 2; one was a second copy of a fix already on `main`.

| Branch | Class | Ahead | Behind | Files only here | Pull request | Action |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `arena/00d742e3-metamanifold-webui` | contained | 0 | 35 | 0 | #283 | closed, deleted |
| `archive/pre-sync-2026-10-17` | contained | 0 | 70 | 13 | #281 | closed, deleted |
| `work/glmgampoi-r-shrinkage` | stale | 41 | 119 | 0 | #284 | closed, deleted |
| `arena/b38170ca-metamanifold-webui` | stale | 43 | 119 | 0 | #280 | closed, deleted |
| `arena/bb2c7f54-metamanifold-webui` | stale | 43 | 119 | 0 | #279 | closed, deleted |
| `arena/1cf75265-metamanifold-webui` | stale | 4 | 7 | 0 | #278 | closed, deleted |
| `arena/57ce87e1-metamanifold-webui` | stale | 9 | 5 | 0 | #274 | closed, deleted |
| `arena/2fe2daad-metamanifold-webui` | fresh, 1 merge commit | 2 | 0 | 0 | #277 | closed, deleted |
| `arena/3bcf0318-metamanifold-webui` | salvage | 2 | 45 | 11 | #276 | closed, deleted |
| `prepare/lwr-63-lean` | salvage | 43 | 119 | 2 | #272 | closed, deleted |
| `upstream/placement-evidence` | salvage | 44 | 119 | 2 | #270 | closed, deleted |
| `wip/pr62-theta` | salvage | 45 | 119 | 1 | #269 | closed, deleted |
| `review/evidence-27-contract` | salvage | 42 | 119 | 2 | #271 | closed, deleted |
| `governance-badges` | unrelated | – | – | 5 | none | kept, by design |
| `main` | base | – | – | – | – | – |

### What the four `salvage` branches actually hold

Nothing on them is in `main`, and nothing on them is worth a merge either — the
branches are built on `257bcdec`, 119 commits before the current tip, so any
merge would revert the files that changed in between. The content is preserved
at its pull-request ref and worth a second look only if its feature is wanted:

- `arena/3bcf0318` — the Full Evidence Mode surface (`frontend/src/evidence/*`,
  `EvidenceModeToggle.tsx`, 11 files). Issue #7 was closed as parked: the
  absorption register excludes `frontend/src/**` from the offer set until the
  replacement work is ready. Parked, not lost: `git fetch origin pull/276/head`.
- `prepare/lwr-63-lean`, `upstream/placement-evidence` — `ComputingNote.tsx` and
  `placementLwr.test.ts`, a component and a threshold test for the placement-LWR
  display whose feature is already in `main`. If the test is wanted, it needs
  re-writing against the current `frontend/src/tree/model.ts`, not cherry-picking.
- `wip/pr62-theta` — `ComputingNote.tsx` alone; its theta reporting is in
  `main`.
- `review/evidence-27-contract` — `docs/reviews/evidence-27-contract.md` and a
  probe script, reviewing a state of the code that has since been replaced.

## The CI cost this created

Thirteen open pull requests were not only untidy, they were expensive, and the
expense is what made the situation stable rather than self-correcting:

- Every pull request triggers the full `CI` suite: `Julia tests` (about 30–45
  minutes), `Statistics standards and evidence` (up to 60), `Agda proofs`,
  `Occupancy typed peak`, `Occupancy disagreement test`, plus `Governance (fork)`,
  `DOI`, `Format readiness evidence` and `Secret Scanner`. `Code relevance`
  skips the expensive jobs only for a diff that touches nothing the suite
  exercises, and none of the thirteen was such a diff: #274 touched
  `bench/null_calibration` and the workflow, #278 touched the workflows and
  `scripts/`, the rest touched `src/`.
- Six of those jobs are required contexts in the `Branch-Floor` ruleset. A
  branch that cannot pass them reports `BLOCKED` indefinitely, so a reviewer
  sees thirteen blocked pull requests and no signal about which of them is
  alive.
- On `main`, `concurrency` is deliberately *not* cancel-in-progress for pushes,
  so that "each merge gets a test result". Two pushes forty seconds apart
  therefore serialise: at the time of this measurement the run for `a3a4a8e` was
  still in progress and the run for `f3816e5a` had not started, 25 minutes later.
  The queue is correct by design; the pile-up it produces is the design's cost,
  and it is worth a decision (see below).

Two red checks on those pull requests were not caused by their content:

- **SonarCloud Code Analysis** failed on most of them with `C Security Rating on
  New Code`. It is not a required context; it is documented in
  [docs/sonar-quality-gate.md](../sonar-quality-gate.md) and reproduced locally
  by `scripts/lint-sonar-reliability.sh`. It analyses "new code" as the changed
  lines, and a branch that appears to change 40,000 lines gets a large surface.
- **Hypatia** failed with "9 new alerts including 5 errors" on the largest ones,
  for the same reason: an enormous, entirely stale diff is a large scan.

Both are symptoms of the same root cause and cleared with the branches.

## Order of work, and why that order

The remediation was done in this order because each step depended on the one
before it:

1. **Measure.** `triage-branches.sh` first, on a full clone. Every later
   decision is a table row, not an impression.
2. **Enforce the rule that already existed.** A check that never existed is a
   wish. `pr-freshness.yml` + `check-pr-freshness.sh` land first so that no new
   drifted branch can be created while the old ones are being closed.
3. **Close the pull requests, then delete the branches.** In that order, because
   the pull request is what keeps the head reachable.
4. **Leave the data branch alone.** `governance-badges` is not a spare branch;
   it is an output. A triage that cannot tell the two apart deletes a badge
   pipeline.
5. **Make the measurement recurring, in one issue.** `branch-hygiene.yml`
   updates a single rolling issue and closes it when clean.
6. **Only then touch the ruleset.** Making **Branch freshness** required is
   safe once the workflow is on `main`, and it cannot be done before then.

## Decisions for the owner

These are not cleanup, they are choices with trade-offs; the reasoning is
recorded here so the choice does not have to be rediscovered.

1. **Make `Branch freshness` a required context.** Add it to the `Branch-Floor`
   ruleset after this lands. Until then the check reports but does not block.
2. **Push-run concurrency on `main`.** `cancel-in-progress: false` for pushes
   gives every merge its own result and serialises the queue. Setting it to
   true would let the newest commit cancel an older validation; the newest tree
   contains the older one, so the loss is a per-commit result rather than
   coverage. Either answer is defensible; the current one is not wrong, only
   slow.
3. **`governance-badges` never gets a pull request.** It is an orphan branch of
   generated JSON, force-pushed by the `Publish badges` job. Excluding it from
   branch listings (a `--exclude`-style pattern in whatever lists branches) or
   publishing the JSON as a release asset would remove it from every human's
   branch list without touching the pipeline. Not done here because it changes
   where the badges are read from, and the `img.shields.io/endpoint` URLs in
   `README.md` point at that branch.
4. **`docs/milestones/02-deferred-issues.md` is referenced by issue #4 and does
   not exist on `main`.** The pre-sync archive carried it; the sync dropped it.
   Either restore it or edit the issue's reference. Not done here because the
   content overlaps `docs/statistics/method-catalogue-v1.md` and the owner may
   prefer the issue to point at that instead.
