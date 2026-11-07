<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Where the fork stands against upstream, and what a sync costs

Measured 2026-11-07. This note exists so the next session does not re-derive
the numbers, and so the decision below is made with them in hand.

## The numbers

| | count |
| --- | --- |
| commits on this fork's `main` that upstream does not have | 131 |
| commits on upstream `main` that this fork does not have | 68 |
| merge base | `257bcde` (2026-10-02), so the fork is a month behind |
| files both sides changed since that base | 48 |
| conflicting diff lines across those files | ~9,400 |

The three open upstream PRs cannot be merged into this fork cheaply for one
reason: each is based on today's upstream `main`, and the fork has never taken
that commit. Landed as-is on fork `main`:

| PR | conflicts |
| --- | --- |
| #68 (SSH recovery) | 48 files |
| #69 (descriptive statistics) | 75 files |
| #70 (native DA) | 48 files |

Those are not conflicts about the PRs' own work. They are the fork's four weeks
of divergence meeting upstream's last four weeks, in files nobody in this
session touched.

## The two ways forward

**A. Merge upstream `main` into the fork once.** One merge, 48 conflicted files,
~9,400 lines to adjudicate. After it, each upstream PR applies on top with only
its own conflicts. The fork's own `CONTRIBUTING` says "no merges from fork main"
— that rule is about branches proposed *upstream*, not about fork `main`, so a
merge commit here does not break it. This is the route the fork's own history
took before (`44a2273`, "sync: merge JoshuaJewell/... main (bcf52af) into the
fork (#109)").

**B. Keep the fork behind and cherry-pick per PR.** Smaller steps, but each PR
still needs its conflicting files adjudicated, and the adjudication is repeated
three times with three chances to disagree with itself.

The largest single conflict is `src/analysis/differential.jl`, where the fork
has ~2,200 lines upstream does not (the compositional and null-calibration
work). That file alone is the argument for doing this once, deliberately, with
someone reading it, rather than three times under time pressure.

## Why this session did not do it

Not capacity, and not a judgement that it is unnecessary. A 9,400-line
adjudication across scientific code — differential abundance, permanova,
rstats interop, memory probing — is a change to what the repository computes.
It cannot be validated here: this environment has no Julia, no R and no bun, and
only a pinned CI run can tell us whether the result still computes the same
numbers. Merging it blind and letting CI decide would be the opposite of what
this fork demands of its own statistics.

That is not a reason to leave it — it is a reason to do it as its own piece of
work, with a Julia and R toolchain, and with the fork's own rule applied: every
number still computed from the data, every method still failing loudly rather
than falling back.

## What was done instead

- The three upstream PRs were completed at their own level: the findings raised
  against them are fixed, and each branch keeps its reviewed, Verified head.
- Two things that need action outside this fork's code are recorded rather than
  guessed at: `docs/proposals/python-test-oracles.md` (a policy boundary that is
  the owner's call) and `notes/commit-signing.md` (the commits that need a key
  this container does not have).
- #70's fork-only CI — which existed only to develop an unregistered package
  into the environment — was removed, because it made the branch unproposable
  upstream and cost it its coverage report.
