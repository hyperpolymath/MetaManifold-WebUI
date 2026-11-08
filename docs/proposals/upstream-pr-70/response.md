<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

<!-- Paste as a comment on upstream #70, replacing the earlier draft of this
     analysis. It answers both Codex threads and the failing check. -->

## On the CI failure and the two review threads

### `Julia tests` — fixed, and green

The failing step was `Instantiate Julia project`, which runs
`Pkg.instantiate()` before any test executes. `Project.toml` listed
`CompositionalDA` under `[deps]`, but that package is not in the General
registry and there was no matching `Manifest.toml` entry, so resolution failed
for every checkout. Nothing was executed — no test ran and no assertion failed.

Three commits fix it:

1. `aac5716` — drop the unresolvable `[deps]` entry (and its `[compat]` bound);
   keep the opportunistic import, so behaviour is unchanged when the package is
   absent and works when it is present.
2. `9ea52fc` — the adapter tests skip loudly instead of importing the package
   at the top of the file; the availability check is exercised whether or not
   the package exists.
3. `d4b659f` — document the dependency caveat, the skip, and how to enable the
   tests once the package is registered.

[Run 42436605157](https://github.com/JoshuaJewell/MetaManifold-WebUI/actions/runs/42436605157)
on the fixed branch: **Julia tests pass (20m55s)**, Agda proofs pass, REUSE
compliance pass, `codecov/patch` pass. Per-testset counts from a job that runs
the two touched files: **1013 passed, 0 failed, 18 skipped** — the skips are the
two adapter-parity files, which need `CompositionalDA` installed.

### `codex-review-state` — a quota message, not a review

The badge reading `Codex review: ❌ Failed` is
`status: "failed"` on `codex-review-state:v1`, and the only failure text is:

> You have reached your Codex usage limits for code reviews.

That is a usage-limit notice from the Codex GitHub app, not a finding about this
change. Supporting evidence:

- The pull request has **no review threads** and **no inline review comments**
  — `listReviewThreads` and `pulls/comments` are both empty. There is nothing
  to resolve and nothing to fix, because no review was produced.
- The check-run history shows no `codex-review` *check run*; the state file and
  the comment are the app's only output.

So there is no outstanding Codex finding to address. Re-triggering with
`@codex review` while the quota is exhausted produces the same message; it
should be retried only after the limit resets.

### The two comment threads

| Thread | What it says | Answer |
|---|---|---|
| One | "Resolving" the review comments, implying findings exist | There are none: the review never ran, so there are no threads to resolve. The only blocking state is `Julia tests`, fixed as above. |
| One | Points at the failing `Julia tests` check | Fixed by the three commits; green in run 42436605157. The failure was dependency resolution at instantiate time, not a test result. |

No comments were edited or deleted; both Codex comments stay as they are, with
this comment as the reply.

## What is still open

1. **Signatures.** The branch's commits are unsigned; `CONTRIBUTING.md` requires
   every commit to show Verified. They will be re-signed (same content, new
   SHAs) before this pull request is considered ready.
2. **Linear history.** The branch currently contains a merge commit from how
   the CI fix was landed; it will be rewritten to a linear series first.
3. **`CompositionalDA` itself.** Until it is registered (or added as a
   `[sources]` git dependency with a regenerated `Manifest.toml`), the two
   estimators refuse by name when the package is absent and the adapter tests
   skip. That is stated in the description rather than papered over.

## What the change asks you to accept

Two estimators behind the existing `analysis.differential.method` switch, with
the config, route, frontend, test and documentation work that goes with them,
plus the honest dependency state above. The full text is in this pull request's
description.
