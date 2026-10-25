# Validated descriptive statistics

This document describes the opt-in `exact_counts` and `high_precision` paths
introduced for issue #1. It is a numeric/storage contract, not a release
certificate. Existing ordinary analysis endpoints, legacy diversity functions,
and the R-backed differential workflow keep their previous defaults and
behavior.

## Scope and claim language

The implemented operations are descriptive:

- per-sample and per-group integer totals and rational proportions;
- observed richness;
- Shannon entropy, `-sum(p * log(p))`, using natural logarithms;
- Gini–Simpson diversity, `1 - sum(p^2)`.

They do **not** provide a hypothesis test, confidence interval, significance
claim, exact Fisher/permutation/NB test, symbolic mathematics, or estimator
coverage guarantee. Higher precision reduces representation and arithmetic
rounding error; it does not remove biological sampling uncertainty and does not
make an MPFR result exact.

Issue #1 also calls for representative biological validation, method-level
review, UI/workflow validation, independent statistical/scientific review, and
explicit release approval. Those are separate acceptance gates. A green unit
suite or this API increment alone must not be used to close the issue or unblock
issue #2.

## Numeric policies

| Mode | Input contract | Arithmetic contract | Output contract |
| --- | --- | --- | --- |
| Existing ordinary workflows | Existing endpoint-specific input | Existing implementation, commonly `Float64` | Existing response, unchanged |
| `exact_counts` | Validated non-negative integers; HTTP accepts JSON-safe integer tokens or whole-number strings | Julia `BigInt` and `Rational{BigInt}` | Counts and proportions are exact; large integers and all rationals are strings |
| `high_precision` | Validated non-negative integer counts; no float upgrade | Exact integer/rational intermediates and scoped MPFR `BigFloat` | Richness is exact; Shannon and Gini–Simpson are marked approximate with achieved precision; displays are separately marked rounded |

A request must select a validated mode explicitly. `ordinary` is not accepted by
the new endpoint, which prevents a client from believing it selected a validated
mode while receiving the legacy implementation.

The immutable policy record contains its mode, precision, rational numerator /
denominator bit budget, display digits, rounding rule, and a deterministic
SHA-256 fingerprint. Precision is scoped for each operation and restored after
success or failure. A conservative lock protects interactions with code that
uses process-default MPFR precision; the tests also exercise concurrent requests
at different precision levels.

## Zero reads and missing values

A zero-total sample or group has no defined probability distribution. Therefore:

- its total is exactly zero;
- each proportion is `nothing` in Julia and `null` in JSON;
- Shannon and Gini–Simpson are `nothing` / `null`;
- its status is `undefined_zero_total`, with an explanatory warning;
- a result containing otherwise valid samples has overall status `partial`, not
  an unqualified numeric success.

The existing legacy diversity functions are deliberately not changed by this
rule. Missing counts, negative counts, nonfinite values, fractional values,
ragged matrices, duplicate/blank labels, and non-integral storage fail instead
of becoming zeros.

## Direct JSON endpoint

`POST /api/v1/statistics/summaries`

The matrix orientation is **features by samples**. For example:

```json
{
  "numeric_policy": {
    "mode": "exact_counts",
    "max_denominator_bits": 4096,
    "round_digits": 8
  },
  "sample_labels": ["A", "B"],
  "feature_labels": ["taxon 1", "taxon 2"],
  "counts": [[1, "9007199254740993"], [3, 1]],
  "groups": ["left", "right"],
  "persist": true
}
```

`groups` is optional. Group summaries are available in `exact_counts` mode;
`high_precision` currently returns per-sample results only. `persist` defaults
to `false` for direct input. If enabled, the persisted source includes the exact
input matrix as strings, making the direct derived record self-contained.

### Optional deadline and cancellation

An optional `"time_limit_seconds"` field (a whole number of seconds greater
than 0 and at most 3600) arms a cooperative deadline for that request. Decimal
and exponent tokens are refused by the same raw-number rule as counts, so the
JSON boundary accepts whole seconds only. Cancellation is checked
between cells, samples, DuckDB rows and streamed chunks, so a bounded request
stops rather than pinning a worker. A cancelled or expired request returns:

```json
{"error": "statistics_cancelled", "message": "…; no partial result was returned"}
```

with HTTP `408`. The deadline is operational only: it never changes a stored
value, is never part of the numeric policy fingerprint, and is never written to
a derived record. A request that times out publishes nothing. Missing or `null`
means no deadline; zero, negative, non-finite, boolean or non-numeric values are
`400`. The same contract applies to the run/DuckDB endpoint.

## Method catalogue

`GET /api/v1/statistics/catalogue`

Returns the approved, bounded catalogue as canonical JCS. It contains the
approval record (`approved_by`, `approved_on`, `approval_reference`), the
`methods` array with a status of `supported`, `unsupported`, `deferred` or
`out_of_scope`, the enforced `limits`, and response-only fields
`catalogue_sha256`, `supported_method_ids`, `method_count` and `file`.

A method that is not `supported` cannot produce a result: `parametric-model-fits`,
`nonparametric-resampling` and `exact-statistical-tests` are published so that
their absence is explicit, and `symbolic-mathematics` is out of scope. The
machine-readable source of truth is `config/defaults/validated_statistics.kyaml`
(KYAML); the loader refuses a catalogue whose status is not `approved` or whose
limits differ from the constants the code enforces. See
[docs/statistics/method-catalogue-v1.md](docs/statistics/method-catalogue-v1.md).

## Julia-rendered statistics page

`GET /statistics` and `POST /statistics` are a server-rendered, JavaScript-free
surface for the same layer. The form accepts the numeric policy, an optional
time limit and a features × samples count table, and renders:

- the approved catalogue block with its fingerprint and approval reference;
- per-sample totals, status and exact proportions (or MPFR metrics);
- group summaries in `exact_counts` mode;
- warnings, diagnostics and a provenance block with the numeric-policy
  fingerprint and `input_sha256`;
- explicit failure states with the documented status and "no result" wording;
- an optional immutable derived record when `persist` is checked.

The page is served with `Content-Security-Policy: default-src 'none';
style-src 'unsafe-inline'; form-action 'self'; base-uri 'none';
frame-ancestors 'none'` and contains no script. It is not a replacement for the
React application and introduces no application TypeScript. The JSON endpoints
remain the machine-readable contract. Per-cell tables are capped at 20,000
cells for display; the summary and provenance stay authoritative.

### JSON number boundary

- A non-negative integer JSON token is accepted only through `2^53 - 1`, the
  I-JSON/browser-safe range.
- A larger count must be a canonical whole-number string, such as
  `"9007199254740993"`.
- `1.0` and `1e0` are rejected even though their mathematical values are
  integral: their JSON representation is floating point.
- Negative strings, decimal strings, exponent strings, NaN, infinity, and
  booleans are not counts.
- Stored approximate `BigFloat` values use a decimal string that can be parsed
  directly at the recorded precision without an intermediate `Float64`.

Validated-statistics requests are also checked against the strict I-JSON profile on the raw request bytes (duplicate keys, unsafe integer tokens and invalid Unicode are rejected with HTTP 400). Float-form count tokens still fail with HTTP 422. Responses and persisted derived records use JCS bytes; see [the migration notes](docs/ijson-jcs.md).

The request body is limited to 16 MiB and a validated matrix to 100,000 cells.
Other reviewed limits are defined in `src/analysis/numeric_policy.jl`; exceeding
one returns an explicit resource error rather than a float fallback.

## Read-only run/DuckDB endpoint

`POST /api/v1/studies/{study}/runs/{run}/statistics/summaries`

The body accepts `numeric_policy`, `table`, optional `taxonomic_level` (or
`rank`), optional sample-column `prefix`, optional aligned `groups`, and the
existing row `filter` / `colFilters` parameters. Inherited diversity exclusion
conditions are also applied and their SQL fragments are recorded in the derived
configuration. With no taxonomic level, the sequence identifier is the feature. With a level, rows are grouped by that taxon;
missing/blank taxonomy is labelled `Unassigned`.

The implementation intentionally does **not** call the legacy
`Analysis.filtered_counts` loader and does **not** use SQL `SUM`:

1. The database is opened read-only through the existing results helper.
2. Sample columns discovered by the existing schema rules must have DuckDB type
   `TINYINT`, `SMALLINT`, `INTEGER`, `BIGINT`, or `HUGEINT`.
   `DOUBLE`/`FLOAT` storage is rejected, not rounded or relabelled as exact.
3. SQL performs row selection and column projection only. Rows are streamed
   and grouped in Julia, so no SQL `SUM` and no arbitrary per-group value is
   involved. Missing and negative count cells are rejected with feature/sample
   coordinates.
4. Integer cells are converted to `BigInt`; taxon and sample totals are then
   summed in Julia. This avoids both `Float64` rounding and fixed-width SQL sum
   overflow.

The legacy `sampleReads` filter is rejected on this endpoint because its current
implementation uses floating totals and SQL sums. Numeric `min`/`max` predicates
on sample-count columns are likewise rejected because their legacy predicate
path uses `Float64`; metadata predicates retain their existing behavior. These
are explicit unsupported conditions, not silently ignored filters.

Run results are always persisted beneath the source run at:

```text
projects/<study>/<run>/derived/validated-statistics/<analysis-id>.json
```

For grouped runs, the existing run-group directory resolution is used. No source
result table is modified.

## Derived-analysis records and reproducibility

A record has schema `metamanifold.derived-analysis.v1` and contains:

- `analysis_id`: SHA-256 of canonical RFC 8785 JSON for the schema, source,
  configuration, and result;
- `source`: direct exact input, or study/run/group/table plus input fingerprint;
- `config`: complete numeric policy and run selection/filter configuration;
- `result`: status, claim, diagnostics, software versions, input fingerprint,
  numeric policy, and typed exact/approximate/display values.

Large integers, rationals, and high-precision numbers are strings before they
reach canonical JSON, so values outside the I-JSON number range never enter the
hash as lossy JSON numbers. The count-matrix fingerprint binds orientation,
feature labels, sample labels, group labels, and every exact count.

Publication writes and closes a temporary file, then atomically hard-links it to
the final content-addressed name. Hard-link publication will not replace an
existing destination. Concurrent identical requests verify and reuse the one
published record; conflicting or tampered content fails closed. Loading checks
the ID against recomputed canonical content. This provides atomic visibility
and failure recovery against partial JSON, but it is not a backup or a claim of
durable storage after a machine/filesystem failure.

Retrieval endpoints:

```text
GET /api/v1/statistics/derived/{id}
GET /api/v1/studies/{study}/runs/{run}/statistics/derived/{id}
```

Run retrieval also checks that the record belongs to the requested study, run,
and run group. Response-only fields such as `derived_analysis.created` are not
part of the immutable result hash.

To reproduce a run analysis, send the stored source/configuration against the
same source data and software versions, then compare `input_sha256` and
`analysis_id`. If the source run changes, the new input receives a different
fingerprint and derived ID rather than overwriting the earlier result. A software
version change also creates a new record deliberately; compare its numerical
content under that new provenance instead of expecting the old content ID.

## Exact and approximate display values

Exact rationals remain `n/d`; a fixed-decimal rendering is only an accompanying
display and is labelled as such. Decimal rendering uses integer quotient and
remainder arithmetic, including after exact conversion of a finite binary
float, so huge values do not pass through an overflowing `Float64` display path.
Fixed-decimal rounding is ties-away-from-zero.

High-precision storage distinguishes:

- `kind: "approximate"` and the round-trip decimal `value`;
- `precision_bits` actually carried by the `BigFloat`;
- a separately rounded `display` with `display_kind: "rounded"`.

MPFR arithmetic uses its nearest rounding mode. Shannon converts each exact
proportion once inside the requested precision scope before taking its
logarithm. Gini–Simpson first computes the exact intermediate
`(N^2 - sum(c_i^2)) / N^2`, then converts once, avoiding a final floating-point
`1 - x` cancellation.

## Validation and reproduction

Focused tests:

```bash
julia --project=. -t2 test/runtests.jl numeric_policy exact_summaries \
  high_precision derived_analyses validated_statistics \
  method_catalogue statistics_boundaries statistics_adversarial \
  statistics_properties statistics_ui
```

Full suite (with the repository's integration and server gates):

```bash
julia --project=. -t2 test/runtests.jl --integration --server
```

The suite includes known answers, independent Python `fractions` and
high-precision `decimal` references, zero/negative/nonfinite/missing controls, values beyond `2^53`, rational budget
failures, SQL-sum overflow controls, feature-permutation and scale invariance,
generative count matrices, malformed JSON fuzz cases, serialization round trips,
concurrent precision scopes, concurrent immutable publication, and tamper
recovery. Reproduce the Python `decimal` references independently with:

```bash
python3 test/references/check_high_precision_references.py
python3 test/references/check_high_precision_references.py --check \
  test/unit/test_high_precision.jl
```

Seeded simulation study with pre-declared tolerances, and the mutation
campaign that proves the tests can fail:

```bash
julia --project=. -t2 scripts/statistics/simulation_study.jl \
  --output simulation-report.json
julia --project=. -t2 scripts/statistics/mutation_check.jl --output mutation-report.json
```

A representative biological count matrix is validated against the existing
`DiversityMetrics` implementation (a separate Float64 code path) with a
pre-declared relative tolerance:

```bash
julia --project=. -t2 scripts/statistics/biological_validation.jl \
  --input counts.csv --source "study/run or DOI" --output biological-report.json
```

Benchmark and retained CI artifact:

```bash
julia --project=. -t2 bench/validated_statistics.jl \
  --output validated-statistics-benchmark.json
```

The benchmark records table dimensions, precision levels, runtime, allocations,
Julia/MPFR versions, platform, thread count, and sequential/concurrent batches.
It is a descriptive performance baseline, not a correctness test or a promise
of equal timing on another platform. CI retains the JSON as
`validated-statistics-benchmark` for 30 days.

## Remaining acceptance work

See the acceptance-criterion map in
[docs/statistics/validation-evidence.md](docs/statistics/validation-evidence.md)
and the [method-by-method validation matrix](VALIDATED_STATISTICS_VALIDATION.md).

Implemented and evidenced here: the approved catalogue, numeric/cross-language
and storage contracts, known-answer and independent references, adversarial and
property-based tests, a seeded simulation study with pre-declared tolerances, a
mutation campaign, cancellation and resource limits, the Julia-rendered UI
surface with provenance and failure states, the regression suite for existing
behaviour, the benchmark, and the CI jobs that rerun the standards gates.

Not self-certified by this increment: the representative biological comparison
(runner supplied by `scripts/statistics/biological_validation.jl`; it requires a
real, licensed count matrix and a provenance string, and refuses to run without
one) and independent statistical/scientific review with explicit release
approval. Those are owner and reviewer gates. Exact statistical tests are
deferred and symbolic mathematics remains out of scope; issue #2 stays blocked.
