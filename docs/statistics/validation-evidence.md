<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Issue #1 — acceptance evidence map

This file maps each acceptance criterion to an artifact that can be inspected,
and states plainly which criteria are **not** satisfied by the implementation
alone. A green test run is evidence for the rows it covers; it is not evidence
for a row that names a reviewer or a dataset.

Status vocabulary: **Met** (checkable artifact in this repository, rerun in
CI), **Open — owner input** (cannot be produced by an implementation agent
without fabricating a result).

## 1. Bounded method catalogue, approved

**Met.** `config/defaults/validated_statistics.kyaml` is the KYAML source of
truth; `src/analysis/method_catalogue.jl` validates it; `GET
/api/v1/statistics/catalogue` publishes it as canonical JCS; `/statistics`
renders it. Approval record: `hyperpolymath`, 2026-09-22,
`#issuecomment-5775420481` (catalogue v1, via the review history of PR #55).
Tests: `test/unit/test_method_catalogue.jl` (status vocabulary, evidence
requirements, limit agreement, mutation rejection, endpoint canonicity).
Human record: `docs/statistics/method-catalogue-v1.md`.

## 2. Numeric conversion, cross-language and storage contracts

**Met.** `docs/statistics/numeric-contracts.md` states each boundary; the
claims are tested by `test_statistics_boundaries.jl` (JSON integer/rational
round trips, DuckDB TINYINT→HUGEINT, Node `JSON.parse` precision loss, Rscript
double/integer loss, JCS round trips) and `test_canonical.jl`. The Node and
Rscript arms **skip and say so** on a runner without those tools; a skip is
never counted as a pass.

## 3. Known-answer and independent references

**Met.** Julia known-answer tests in `test_exact_summaries.jl` and
`test_high_precision.jl`; independent Python `fractions` and `decimal`
references in `test/references/exact_summary_reference.py` and
`test/references/check_high_precision_references.py`, with the CI step
`Check independent high-precision references` verifying the constants embedded
in the Julia tests. The reference implementations share no code with the layer.

## 4. Numerical stability and adversarial tests

**Met.** `test_statistics_adversarial.jl`: policy limits, matrix shape, label
hygiene, booleans/floats/negative/oversized counts, request-byte caps, count-bit
caps, deadline validation, cancellation, derived-ID traversal, and canonical
error bodies. `test_statistics_boundaries.jl` adds 2^53±1, 2^127 aggregation,
and float count columns. `test_validated_statistics.jl` already covers malformed
JSON fuzz, SQL-sum overflow, and tamper recovery.

## 5. Property/generative and fuzz tests

**Met.** `test_statistics_properties.jl` (seeded): exact proportions reconstruct
counts and sum to exactly one; scale invariance; storage round trips; Shannon
and Gini–Simpson against independent 512-bit references; uniform and
single-species closed forms; zero-count feature and feature-permutation
invariance; rational budget enforcement; high-precision storage round trips at
64/128/256/1024 bits. `test_validated_statistics.jl` contains the deterministic
JSON fuzz corpus, including random byte strings.

## 6. Negative controls and mutation evidence

**Met, campaigned in CI.** `scripts/statistics/mutation_check.py` plants six
reviewed defects one at a time (unapproved catalogue, limit drift, request-limit
drift, weakened CSP, float-derived proportions, zero-total reported as zero),
runs the focused test file, and requires a non-zero exit. The script refuses a
dirty target, restores from a saved copy, and re-verifies the file hash. The CI
job runs a bounded subset and retains `statistics-mutation-report.json`.

## 7. Simulation studies with pre-set tolerances

**Met.** `scripts/statistics/simulation_study.jl`: 200 seeded exact replicates
(tolerance 0) plus 40 seeded precision replicates at 128/256/512 bits against an
independent 4096-bit computation, with the tolerance `2^-(bits-16)` declared in
the script before the run. CI runs it and retains
`statistics-simulation-report.json`. This studies implementation error, not
estimator coverage — no estimator is claimed.

## 8. Representative biological validation

**Open — owner input.** The runner exists:
`scripts/statistics/biological_validation.jl` compares the validated layer with
the existing `DiversityMetrics` Float64 implementation on a real count matrix,
with a pre-set relative tolerance and explicit recording of the intentional
zero-total divergence. It **refuses to run without a provenance string** and
does not synthesise a matrix. No representative, licensed count matrix is
checked into this repository (the bundled `data/MiSeq_SOP` contains FASTQ reads
only), so this row needs either an owner-supplied run or an approved, cited
public dataset before it can be closed.

## 9. Reproducibility, serialization, concurrency, cancellation, limits, recovery

**Met.** `VALIDATED_STATISTICS.md §Derived-analysis records` documents the
content-addressed store; `test_derived_analyses.jl` covers atomic publication,
concurrent identical publication, conflict detection and tamper recovery;
`test_statistics_adversarial.jl` covers cancellation, deadlines and every
published limit; `test_validated_statistics.jl` covers concurrent identical
requests and repeat retrieval. Scope limit: atomic visibility is not a claim of
durability after a filesystem or machine failure.

## 10. UI-to-backend workflow, accessibility, provenance, unsuccessful states

**Met.** `/statistics` is Julia-rendered with no script, served under
`default-src 'none'`, and posts a standard URL-encoded form.
`test_statistics_ui.jl` asserts labelled controls, `aria-describedby`, skip
link, table captions and column scopes, provenance (policy fingerprint,
`input_sha256`, derived ID), escaped echo of user input, display caps, and every
failure state with its documented status and "did not produce a result"
wording. The mutational control `ui-csp-weakened` proves the CSP test can fail.

## 11. Regression proof that existing behaviour is unchanged

**Met.** The full suite still runs every pre-existing test, including the
integration pipeline and the server smoke tests. The new layer is additive: no
existing route, R-backed workflow, saved-analysis reader or Float64 diversity
function was modified, except that validated-statistics responses now use JCS
(already the documented contract) and summary functions accept an optional
`cancellation` keyword defaulting to `nothing`. `test_differential.jl`,
`test_diversity.jl`, `test_analysis_duckdb.jl` and `test_r_runtime.jl` are
unchanged and still run in CI.

## 12. Benchmark and bounding expensive operations

**Met.** `bench/validated_statistics.jl` records dimensions, precision,
runtime, allocations and versions; CI retains
`validated-statistics-benchmark.json`. Every expensive input is bounded before
work starts: 16 MiB request body, 100,000 cells, 1,000,000 bits/digits, 3,600 s
deadline, 64 MiB derived-record read cap, and a 20,000-cell UI display cap.

## 13. Repository standards gates in CI, with retained artifacts

**Met.** A dedicated CI job pins the standards commit
(`hyperpolymath/standards` at `c6d7860`), installs `yq` v4.53.3 with a SHA-256
check, builds `hyperpolymath/ijson-jcs` at `3a9a4ee`, then runs:

- `scripts/kyaml-format.sh --check config/defaults/validated_statistics.kyaml`
  (YAML-POLICY Y-3 / D307 — the `.kyaml` file is byte-identical to
  `yq -p yaml -o kyaml`, i.e. flow style, quoted strings, two-space indent,
  `---` and a final newline);
- `scripts/check-ijson-jcs.sh --enforce` over the repository's tracked JSON
  (JSON-POLICY J-1 / D306).

The canonical renderings and the check log are uploaded as the
`statistics-standards` artifact. A missing tool is exit 2 in both standards
scripts and therefore a failed job, never a passing skip.

## 14. Independent statistical/scientific review and explicit release approval

**Open — reviewer input.** This cannot be self-certified. The review packet is:
this file, `docs/statistics/numeric-contracts.md`,
`docs/statistics/method-catalogue-v1.md`, the benchmark and simulation reports,
and the PR discussion. Release approval requires a named reviewer's explicit
sign-off on the claim language ("descriptive only; no hypothesis test,
confidence interval, significance claim or estimator coverage guarantee").

## 15. Deferred scope

Exact statistical tests are **deferred** and are not part of the initial gate;
the catalogue publishes that state. Symbolic mathematics is out of scope, and
issue #2 remains blocked until this layer is approved.

## How to reproduce the evidence

```bash
# Focused
julia --project=. -t2 --compiled-modules=no test/runtests.jl \
  validated_statistics numeric_policy exact_summaries high_precision \
  derived_analyses method_catalogue statistics_boundaries \
  statistics_adversarial statistics_properties statistics_ui

# Independent references
python3 test/references/check_high_precision_references.py --check \
  test/unit/test_high_precision.jl

# Simulation, mutation, benchmark
julia --project=. -t2 scripts/statistics/simulation_study.jl --output simulation-report.json
python3 scripts/statistics/mutation_check.py --output mutation-report.json
julia --project=. -t2 bench/validated_statistics.jl --output benchmark.json

# Standards
bash scripts/kyaml-format.sh --check config/defaults/validated_statistics.kyaml
ijson-jcs check frontend/public/config.json
```
