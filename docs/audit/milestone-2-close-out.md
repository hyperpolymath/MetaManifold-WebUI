<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Milestone 2 Close-Out Audit — Baseline Tests, Benchmarks, CI/CD, Project Board

**Date:** 2026-09-22
**Audit type:** Close-out verification of issue #15. Claims were re-run against the repository rather than read back from the milestone document.
**Auditor:** Agentic audit; commands and their output are quoted so each verdict is reproducible.
**Revision audited:** `main` @ `22d228f5`

## Verdict

All four of #15's acceptance criteria hold: the test suite and its pathways are
documented, the benchmarks exist and run, CI is extended and green on `main`, and the
board is linked. Two claims in
`docs/milestones/02-baseline-tests-benchmarks.md` no longer described what the
repository does, and both are corrected in the same PR as this audit:

1. the ">10% regression gate fails CI" claim (frontend **and** Julia) — the gate was
   deliberately superseded by an informational comparison, with measured reasoning;
2. the test-suite figures, which had drifted upward as tests were added.

Neither correction invalidates the milestone: the first is a decision the owner took
after the document was written and is recorded in `ci.yml`; the second is a snapshot
that has aged in the safe direction.

## What was run

| Command | Where |
| --- | --- |
| `bun test` / `bun test --coverage` | `frontend/` |
| `ls test/unit/*.jl \| wc -l`, `cat test/unit/*.jl \| wc -l` | repository root |
| `ls bench/`, `ls frontend/bench/` | repository root |
| `grep` over `ci.yml`, `README.md`, `bench/**`, `frontend/bench/baseline.json` | repository root |
| `GET /actions/runs?branch=main&status=success` | GitHub API |

## Claims, evidence, verdicts

### Frontend test suite

**Claimed** (doc, local run 2026-09-18): 581 pass, 5 todo, 0 fail, 3350 expects,
586 tests across 16 files, 415 ms.

**Measured** (2026-09-22): 599 pass, 5 todo, 0 fail, 3368 expects, 604 tests across
16 files, 461 ms.

**Verdict: holds, grown by 18 tests.** The shape is unchanged — the same 5 todos, the
same 16 files, no failures. The todo count is the interesting one: it has not moved,
so the DOM-lane debt the document records is still exactly that debt and has not
silently grown.

### Frontend coverage

**Claimed:** 40.19% functions, 47.53% lines (issue: "40% funcs, 47% lines").
No gate, by policy.

**Measured:** 40.23% functions, 47.50% lines.

**Verdict: holds.** Regenerated independently; the difference is rounding.
Under-covered files remain the DOM-only ones (`DataTable.tsx` 0.00/0.93,
`CardActions.tsx` 0.00/3.51, `NameDialog.tsx` 0.00/2.38), which is the documented
consequence of the unit lane being DOM-less rather than a regression. The e2e lane is
where those files are exercised — see #32, whose dialog specs run in real Chromium.

### Julia test suite

**Claimed:** 27 unit test files, 6830 lines.

**Measured:** 30 unit test files, 8310 lines.

**Verdict: holds, grown by 3 files and 1480 lines.** Reproducible with the two
commands above.

### Benchmarks

**Claimed:** `table_loading`, `epistemic_parsing`, `duckdb_aggregation`,
`permanova_nmds`, `tree_rendering`, plus a comprehensive runner; frontend harness
with 7 workloads.

**Measured:** all five `bench/<category>/benchmark.jl` present, plus
`bench/comprehensive_benchmark.jl` and `bench/analysis_config/benchmark.jl`; every
category has a committed `baseline.json`. `frontend/bench/baseline.json` holds
exactly 7 workloads: `run-table-json-parse`, `figure-colour-overrides`,
`table-loading-sample-columns`, `epistemic-parsing`, `duckdb-aggregation`,
`permanova-nmds`, `tree-rendering-clade-cumulus`.

**Verdict: holds.** The 7 names match the document one-for-one.

### The >10% regression gate — superseded

**Claimed:** "Regression gate: >10% fail in CI"; frontend Node script fails on
>10% delta; each Julia `bench/*.jl` fails on >10% when `ENV["CI"] == "true"`.

**Measured: not what the repository does.** `ci.yml` states the deltas are
"REPORTED, never gated" and gives the measurement behind that decision: two
consecutive runs of *identical* benchmark code on a hosted runner produced
per-workload deltas between **-16% and +52%**, flapping in both directions, because
the harness workloads import no application code at all — a delta measures the runner,
not the commit. `bench/table_loading/benchmark.jl` agrees: a >10% delta prints
`NOTE`, emits `@warn "…(informational)"`, and carries the comment "Never gates in
CI."

**Verdict: claim no longer true; the deviation is deliberate, evidenced, and now
documented.** A hard gate below the noise floor would block at random, which is worse
than no gate — and worse for the repository's own philosophy, since a gate that fails
for reasons the commit cannot influence teaches people to ignore it. The document has
been corrected to describe the informational comparison, the measured noise floor,
and what still holds for real: checksum hard-fails, the workload freeze policy, and
deltas plus machine factor shipped as artifacts for review.

### CI/CD extension

**Claimed:** tests and benchmarks on every push/PR, artifacts, and the new categories
`analysis-config` and `cladistic-explorer`.

**Measured:** frontend `bun test --coverage`, typecheck, build and the benchmark
harness are CI steps; the Julia side runs all five categories plus
`bench/analysis_config/benchmark.jl` and `bench/comprehensive_benchmark.jl`;
`test/unit/test_analysis_config.jl` runs as a step of its own; artifacts
`frontend-tests-benchmarks` (junit.xml, lcov.info, results.json, baseline.json),
`julia-coverage-lcov` (lcov.info) and `julia-benchmarks-comprehensive` are declared.
For the cladistics category the repository carries `frontend/src/components/
CladeCumulus.tsx` and the `tree-rendering-clade-cumulus` workload; a
`test_clade_cumulus.jl` does **not** exist, which is what the document already says
("future, will test…"). The accepted reading is that the *benchmark category* exists
and the *unit category* remains future work, and the document is precise on that.

**Verdict: holds**, with the naming clarified above.

### Codecov and gitar

**Claimed:** Codecov removed (config deleted, README badge removed, upload replaced by
a local artifact); gitar absent (`grep -i gitar` returns 0).

**Measured:** no `codecov.yml`; no Codecov badge or slug in `README.md`; `ci.yml`
uploads coverage as a local artifact named `julia-coverage-lcov` with the step
comment "Codecov removed per Milestone 2"; `grep -rin gitar` over the tree returns
nothing.

**Verdict: holds.** Note that the older
`docs/audit/type-system-reconnaissance.md` still *mentions* a Codecov slug pointing
at the parent repository — that document records a state that has since been
remediated, and it is a historical audit, not a current claim.

### CI runtime

**Claimed:** 15–20 minutes.

**Measured:** the last four successful `main` runs took 29:18, 14:12, 15:17 and
22:21 (median ≈ 19 minutes).

**Verdict: holds as a range, with a caveat worth recording.** The variance is
dominated by the renv restore — 79 R packages built from source, resumable from a
cache, and the single largest cost in the workflow. A cold cache is the 29-minute
case.

### Local sandbox RAM

**Claimed in the document:** the local sandbox is memory-blocked
("876Mi vs 2.5GB required").

**Corroborated incidentally:** this audit's own environment could not precompile
`DataFrames` or `XLSX` — the two heaviest direct dependencies — and the memory ceiling
is the plausible explanation; `MetaManifold` itself precompiled in 116 s once the
lighter tree was built. The audit therefore ran its Julia-side verification through a
harness that mounts the real `Provenance` module (whose only sibling dependency is
`RRuntime`) rather than the whole package. The claim is consistent with what the
environment does.

### Project board

**Claimed:** https://github.com/users/hyperpolymath/projects/45 — "Analysis Layer &
Cladistics Development", 11 items, PRs #11–#14 linked.

**Measured: not verifiable with the credentials available to this audit.** The board
is a user-level Projects v2 board; reading it needs the `read:project` scope, which is
granted per-token, and the token in use during this audit carries `repo` and
`workflow` only.

**Verdict: unverified, and recorded as such rather than assumed.** Everything else on
this page was re-derived from the repository or the API. The link and the board's own
existence are the owner's to confirm; nothing in the codebase depends on it.

## Consequences

- `docs/milestones/02-baseline-tests-benchmarks.md` carries dated audit notes beside
  the figures it recorded, and its regression-gate section now describes the
  informational comparison that replaced the gate.
- No code change is implied by this audit. The tests, the benchmarks and the CI
  wiring are as the milestone describes them, except where noted above.
- Two things are deliberately left as they are: `test_clade_cumulus.jl` is still
  future work, and the benchmark comparison is still informational. Both are
  decisions, not oversights, and both are now written down where a reader will find
  them.
