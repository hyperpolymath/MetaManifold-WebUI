<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Where things stand, 13 November 2026

This page records the state of this fork, its upstream pull requests and its
quality signals as of 2026-11-13. It is a dated snapshot: when it and the code
or a pull request disagree, the code or the pull request is right and this page
is out of date. The previous snapshot of the fork/upstream divergence is
[notes/upstream-sync.md](../../notes/upstream-sync.md) (measured 2026-11-07).

## Two repositories

- **This fork,** `hyperpolymath/MetaManifold-WebUI`, is where the work is
  developed. Its `main` has diverged from upstream (see the sync note).
- **Upstream,** `JoshuaJewell/MetaManifold-WebUI`, is maintained by Joshua
  Jewell. Work is proposed there as pull requests from branches of this fork.
  Nothing listed below as open upstream has been merged upstream.

## Open upstream pull requests

Measured from GitHub on 2026-11-13. None of these is merged.

| Upstream PR | Branch in this fork | State | What it proposes |
| --- | --- | --- | --- |
| #68 | `fix/66-resumable-ssh-stages` | open, ready for review | Recoverable SSH stages: each remote stage keeps a journal in its stage log, so an interruption on the local side does not force the remote work to start again; an attempt that exits 0 without its required outputs is retired instead of being taken as success. Upstream issue #66. |
| #69 | `codex/issue-65-descriptive-statistics` | open, ready for review | Exact descriptive statistics (integer totals, rational proportions, observed richness) with independent pipeline evidence. Upstream issue #65. Its catalogue is `pending_review` (below). |
| #70 | `validation/issue-23-native-da` | **draft** | Native `aldex2` and `ancombc` differential-abundance estimators behind an optional `CompositionalDA` dependency. Waiting on `CompositionalDA` being registered in the Julia General registry ([JuliaRegistries/General#175952](https://github.com/JuliaRegistries/General/pull/175952): open, AutoMerge checks passed, in the mandatory three-day waiting period on 2026-11-13). Upstream issue #23. |
| #71 | — | open | Multinomial and Dirichlet-multinomial differential abundance. Listed for completeness. |
| #72 | `feature/high-precision-diversity` | **draft** | High-precision (MPFR) Shannon entropy and Gini–Simpson diversity as an extension of #69, kept out of #69 so that #69 stays exact-only. |

Joshua's replies are pending on upstream issues #22 and #23.

### Recoverable SSH stages (#68)

On this fork's `main` the remote (SSH) runner does **not** yet have the recovery
protocol: `src/pipeline/remote_session.jl` exists only on the #68 branch. Until
#68 is merged upstream and the fork syncs, an interrupted remote stage on this
fork's `main` is restarted, not recovered.

### Exact statistics and the catalogue's review status (#69, #72)

There are two catalogues, and they are in different states on purpose.

- **This fork's `main`** ships the validated-statistics layer from fork
  issue #1 (`exact_counts` and `high_precision` modes; see
  [VALIDATED_STATISTICS.md](../../VALIDATED_STATISTICS.md)). Its catalogue,
  `config/defaults/validated_statistics.kyaml`, has status `approved`, recorded
  as approved by the fork owner on 2026-09-22 in fork issue #1. That approval
  is the fork owner's scope decision; it is not an independent statistical
  review, which fork issue #1 still lists as an open acceptance gate.
- **Upstream #69 and #72** carry the catalogue
  `config/defaults/validated_statistics.yml` with status **`pending_review`**.
  Their validator *requires* `pending_review`, and the UI shows it, so that
  nothing upstream can present itself as approved before upstream's
  independent review and release approval exist. Changing that status is a
  decision for upstream, not a configuration edit.

### Native differential abundance (#70)

This fork's `main` already offers `ancom_bc` and `aldex2` through its own
implementation (README, "Differential abundance"). #70 is the separate proposal
to give upstream native estimators through `CompositionalDA`. It stays a draft
until the General registration above completes, because before that the
dependency cannot be declared in `Project.toml` without breaking
`Pkg.instantiate()`. The package documents for it are in
[docs/proposals/upstream-pr-70/](../proposals/upstream-pr-70/README.md).

## Quality signals

### SonarCloud (this fork)

Project key `hyperpolymath_MetaManifold-WebUI`, Automatic Analysis, the
built-in Sonar way gate; how the gate works and why one bug fails it is in
[docs/sonar-quality-gate.md](../sonar-quality-gate.md).

On 2026-11-13, before the fix below, `main` measured:

| Measure | Value |
| --- | --- |
| Open bugs | 22 (reliability rating C) |
| Open vulnerabilities | 3 (security rating C) |
| Security hotspots | 0 |
| Code smells | 679 (maintainability rating A) |
| Duplicated lines | 0.1% |
| Quality gate (new code, 3-day window) | passed |

The gate passed because it judges only new code; the 25 findings were older
than the window. All 25 are addressed by the change that adds this page; the
table in [docs/sonar-quality-gate.md](../sonar-quality-gate.md#the-25-findings-open-on-main-in-november-2026)
says how each one was fixed. The overall numbers above should be re-read from
SonarCloud after that change merges, not assumed.

### Codecov

- **Upstream** reports coverage for the Julia backend (the frontend is not
  measured; see `codecov.yml`). Upstream `main` measured 80.72% on 2026-11-13.
  On #69, Codecov reports project coverage of 78.31% at the head against
  75.73% at its base, and patch coverage of 99.53%: 1,058 of 1,063 changed
  lines covered, 5 not. The patch status is informational and green.
- **This fork** has no active Codecov repository (the Codecov API reports it as
  not activated, with no totals), so there is no fork-side coverage number to
  quote.

### Note for Joshua on #69's uncovered lines

*Written for upstream; not posted anywhere.*

Codecov lists five changed lines on #69 that no test executes. The check is
green, because `codecov.yml` makes patch coverage informational. Whether and how
to cover them is your call; this note only says what they are, with line
numbers at #69's head as Codecov reports them.

| File | Line(s) | What the line does |
| --- | --- | --- |
| `src/server/routes/validated_statistics.jl` | 226–227 | The `catch` that turns an exception from `_body_filter_params` into `ArgumentError("invalid filter parameters: …")`, re-throwing an `InterruptException` unchanged. Reached only when the already-normalised filters still fail to parse. |
| `src/server/routes/validated_statistics.jl` | 286 | `_statistics_cancellation` accepting `time_limit_seconds` as a floating-point number. The tests send an integer, so only that branch runs. |
| `src/analysis/derived_analyses.jl` | 127 | The `rethrow()` after a failed `hardlink` when no competing record exists at the final path, i.e. a publish failure that is not a lost race. |
| `src/canonical.jl` | 220 | `_shortest_digits`, the branch for a `repr(::Float64)` mantissa with no decimal point. Julia's `repr` of a `Float64` normally contains one, so this may be unreachable rather than untested. |

The first three can be reached from a test (a filter value that passes
normalisation but fails the second parse, a float time limit, and a hard link
into a read-only directory); the fourth may be better removed or asserted than
tested. None of these is a claim that the code is wrong.

## What changed in this fork on 2026-11-13

- The 25 SonarCloud findings on `main` were fixed (3 vulnerabilities, 22 bugs);
  see the table in [docs/sonar-quality-gate.md](../sonar-quality-gate.md).
- `config.json`'s `apiBase` is now validated before use; see README,
  "Split deployment".
- This page, the README, the Sonar page, the sync note, the #70 package and
  `VALIDATED_STATISTICS.md` were brought up to date with the above. Matching
  edits to the wiki's status, testing and operator pages were prepared as a
  patch on the pull request that adds this page; the wiki itself is unchanged
  until that patch is applied.

Agents wrote this change and these pages. The person answering for them is
Jonathan D. A. Jewell (The Open University).
