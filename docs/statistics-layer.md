# The exact-arithmetic statistics layer

Status: implemented, additive, **descriptive only** — awaiting independent
scientific review before any inferential method is added (issue #1).

This document is the layer's published scope. Where it says a method is
supported, that is the whole of what is claimed; everything it does not say is
not claimed.

## 1. What this layer is

MetaManifold's existing analyses — alpha diversity, taxonomic composition,
differential abundance, PERMANOVA — are unchanged and remain the default path.
The statistics layer is a separate, opt-in set of descriptive summaries that:

* preserve read counts as exact arbitrary-precision integers;
* produce exact rational values where a statistic has one (Simpson's index,
  proportions, means, rarefaction expectation);
* compute the statistics that have no exact value (Shannon's index, Pielou
  evenness) at an explicitly requested precision, tagged as approximations;
* store every result as an immutable, content-addressed record with its inputs,
  settings, versions and diagnostics;
* refuse, with a named code, whatever it cannot compute honestly.

It is reachable only through its own endpoints (§5). No pipeline stage and no
existing analysis calls it, so a run that never asks for it is unaffected.

### What it is not

* **Not a test.** There is no hypothesis test, p-value, confidence interval or
  model fit anywhere in this layer. Exact statistical tests are a later,
  separately validated extension.
* **Not model-based.** No distribution is assumed, so no estimator is claimed to
  be unbiased for a population quantity.
* **Not symbolic.** Symbolic mathematics is out of scope.
* **Not a fix for measurement error.** Exact arithmetic removes representation
  error. Sampling uncertainty, model misspecification, PCR bias, primer bias,
  extraction bias, copy-number variation and every other biological or technical
  bias are untouched by anything here.

## 2. Method catalogue

The catalogue is data: `MetaManifold.ExactStatistics.METHOD_CATALOGUE`, served at
`GET /api/v1/studies/{study}/analysis/statistics/catalogue`. A method is only in
it if it can state its response type, numeric modes, uncertainty statement and
limitations.

| Method | Computes | Exact in `exact` mode | Approximate otherwise |
|---|---|---|---|
| `summarise.counts` | per-sample and per-feature totals, richness, zero counts, means | totals, richness, means | means |
| `describe.alpha` | richness, Gini–Simpson, Shannon, Pielou evenness | richness, Simpson | Simpson, Shannon, evenness |
| `describe.proportions` | each feature's share of its sample and of the corpus | proportions | proportions |
| `rarefaction.expected_richness` | Hurlbert's (1971) expected richness at a chosen depth | the expectation | the expectation |
| `compare.taxon_ratio` | exact ratio of two named features' totals | the ratio | the ratio |

Supported response: a **non-negative integer count matrix**, samples × features.
Anything else is refused (§4). Every method is `design_required = false`: none of
them needs study-design information, which is exactly why none of them infers
anything.

**Uncertainty, effect size, multiple testing.** Every entry states these
explicitly: uncertainty is not estimated (no sampling model is assumed), there is
no effect size (no comparison between groups is made), and multiple testing is
not applicable (no test is performed). Those are "not applicable" statements with
a reason, not omissions.

**Rarefaction specifics.** The expectation is computed in closed form as a
product of rational factors per feature, so no binomial coefficient is
materialised, no random number is drawn, and there is no Monte Carlo error. A
depth above a sample's library size is refused for that sample
(`depth_exceeds_library`) rather than clamped, and depths above 10,000 or
feature × depth products above 5,000,000 are refused for the request
(`resource_limit`).

## 3. The numeric policy

One immutable `NumericPolicy` per request, resolved from
`analysis.statistics.numeric` in the config cascade and optionally overridden per
request:

```yaml
analysis:
  statistics:
    numeric:
      mode: float64        # float64 | bigfloat | exact
      precision_bits: 256  # 53 .. 4096, used by bigfloat
      max_digits: 4096     # 16 .. 100000, bounds every exact value
      display_digits: 6    # 0 .. 50, display strings only
```

* `float64` — binary64 (53-bit significand), matching the rest of the
  application.
* `bigfloat` — MPFR at `precision_bits`. Higher precision, still an approximation.
* `exact` — arbitrary-precision integers and exact rationals only. A statistic
  with no exact value is refused with `unsupported_numeric_mode`. It is never
  computed at another precision and returned as though the request had been met.

Every argument is validated strictly, and a mistyped key is an error rather than a
silently ignored setting.

### Precision isolation

Julia's `BigFloat` precision is process-global. All arithmetic that depends on it
runs inside `ExactNumeric.with_precision`, which takes a process-wide lock, sets
the precision, and restores it in a `finally` before releasing the lock. Two
analyses asking for different precisions therefore cannot observe each other's
setting, and nothing is left behind afterwards. The tests run 64 concurrent
analyses at four precisions and compare each with its sequential result.

### The serialisation contract

Published as data by `ExactNumeric.numeric_contract()`.

| Kind | Representation | JSON |
|---|---|---|
| exact integer | arbitrary precision | `{"kind":"exact","type":"integer","value":"<decimal string>","display":"..."}` |
| exact rational | lowest terms, positive denominator | `{"kind":"exact","type":"rational","numerator":"...","denominator":"...","value":"n/d","display":"...","display_rounded":true}` |
| approximation | MPFR at a stated precision, or binary64 | `{"kind":"approximation","type":"mpfr" or "binary64","value":"<decimal string>","precision_bits":N,"rounding":"round-to-nearest-ties-to-even","display":"...","display_rounded":true}` |

Rules:

1. Exact values are **always decimal strings**, never JSON numbers. A count above
   2^53−1 does not survive a JSON round trip as a number, and emitting it as one
   is how exact counts quietly stop being exact in a browser or an R session.
2. Rationals are normalised; a zero denominator is refused.
3. Approximations carry their engine, precision and rounding mode and are never
   promoted to exact by a later step.
4. Display values are rounded separately, half to even, and marked
   `display_rounded`. They never feed a computation.
5. Unsupported representations are rejected explicitly: NaN, infinities,
   fractional counts, float counts above 2^53−1, `Bool`, and exact values beyond
   `max_digits`.

`parse_exact_json` reverses the round trip; the tests check
`parse_exact_json(exact_json(x)) == x` for integers and rationals.

## 4. Failures are states, not fallbacks

Each refusal carries a stable code, a scope, and a message:

| Code | Meaning |
|---|---|
| `invalid_input` | input cannot be represented exactly: fractional count, NaN, ∞, float count > 2^53−1, `Bool` |
| `zero_denominator` | the requested ratio, index or proportion has no value |
| `resource_limit` | an exact value, work bound or depth bound was exceeded |
| `unsupported_numeric_mode` | the operation has no representation in `exact` mode |
| `depth_exceeds_library` | rarefaction depth above a sample's library size |

A record's `status` is `complete`, `partial` (some entries explicitly
unsuccessful, each naming its own code, while the rest are usable) or
`unsuccessful` (nothing could be computed). A partial result never fills a failed
entry with a plausible-looking number: a zero-read sample has no proportions, a
sample with one observed feature has no Pielou evenness, and the record says so.

## 5. API

```
GET  /api/v1/studies/{study}/analysis/statistics/catalogue
POST /api/v1/studies/{study}/runs/{run}/analysis/statistics
GET  /api/v1/studies/{study}/runs/{run}/analysis/statistics
GET  /api/v1/studies/{study}/runs/{run}/analysis/statistics/{analysis_id}
```

POST body:

```json
{
  "table": "merged",
  "method": "rarefaction.expected_richness",
  "options": {"depth": 1000},
  "numeric": {"mode": "exact"},
  "filter": "...", "colFilters": {}, "sampleReads": {"min": 100}
}
```

The POST answers `200` with the stored record whenever the analysis ran, even when
its `status` is `partial` or `unsuccessful`: the request succeeded, and the
outcome is the result. A client must read `status`. Only a malformed request, an
unknown method or option, or an invalid numeric policy is an HTTP error.

The statistics surface obeys `analysis.exclude_categories` when a config names
`statistics` in an entry's `apply_to`. The factory default does not, so the layer
sees the unfiltered table until an exclusion says otherwise.

## 6. Records

`projects/{study}/[{group}/]{run}/analysis/statistics/{analysis_id}.json`

* `analysis_id` is the SHA-256 of the record's canonical JSON (RFC 8785),
  excluding `analysis_id` and `created_at`: the same analysis of the same input
  under the same settings hashes identically wherever it is recomputed, while a
  changed setting, input or method version produces a different id.
* Records are **write-once**. Re-running an unchanged analysis is idempotent and
  keeps the original file; a differing body at the same id is a `RecordConflict`,
  never an overwrite. New settings produce a new record beside the old one, and
  each record names the input fingerprint it was computed from.
* The file is written atomically (temporary file, then rename) and is
  byte-identical across machines for the same analysis and timestamp.
* `list_records` reports a damaged file as `unreadable` rather than hiding it: a
  missing record and a broken one are different facts.

The input fingerprint is the SHA-256 of canonical JSON over the ordered sample
names, ordered feature names and every count as a decimal string. It changes if a
count, a name, or the order of either changes.

Provenance recorded with every result: method name and version, numeric policy,
parameters, seed (recorded even though no catalogue method draws a random number),
Julia version, MPFR version, package version and the input fingerprint.

## 7. Validation

The evidence this layer ships with:

| Evidence | Where | Runs in CI |
|---|---|---|
| Independent reference values in another language (`fractions.Fraction`, `decimal.Decimal` at 80 digits) | `scripts/statistics-reference.py` → `test/fixtures/statistics_known_answers.json` | yes (the fixture is checked by the suite) |
| Exhaustive subset enumeration, sharing no algebra with the closed form | `test/unit/test_exact_statistics.jl` | yes |
| Metamorphic relations (permutation, uniform rescaling) and bounds | same | yes |
| Adversarial cases: huge counts, all-zero tables, tiny probabilities, non-finite input, counts above 2^53, depth above library, work bounds | same | yes |
| Generative tests with seeded random tables | same | yes |
| Parsing fuzz at the exact-value and policy boundaries | `test/unit/test_exact_numeric.jl` | yes |
| Negative controls (8 mutants, each expected to be caught) | `scripts/statistics-negative-controls.jl`, enforced by the suite | yes |
| Simulation study: simulated mean vs exact expectation, pre-set 4-SE tolerance | small version in the suite; full study in `scripts/statistics-simulation.jl` | small version yes |
| Precision isolation under concurrency | `test/unit/test_exact_statistics.jl` | yes |
| Record reproducibility, immutability, corruption handling | same | yes |
| Existing behaviour unchanged when the layer is not selected | same | yes |
| Cost and allocation of the exact path | `scripts/statistics-simulation.jl` | no (opt-in) |

Reproduce everything locally:

```console
$ python3 scripts/statistics-reference.py       # regenerate the fixture, then
$ julia --project=. test/runtests.jl exact      # run the two layer test files
$ julia --project=. scripts/statistics-negative-controls.jl
$ julia --project=. scripts/statistics-simulation.jl
```

The simulation study's tolerance is set in advance at four standard errors of the
simulated mean: a correct implementation fails roughly once in 30,000 such
studies, while a bias above about 1% is caught. Seeds are fixed, so the study is
deterministic rather than flaky.

### What has *not* been established

Stated plainly, because a green test run is not the same as a validated method:

* **No independent scientific review has happened.** The acceptance criteria in
  issue #1 require it, and no amount of passing tests substitutes for it.
* **No inferential method exists**, so no coverage, error-rate or power claim is
  made anywhere.
* **The layer has no UI panel.** It is backend-first by design: the issue rules
  out new application TypeScript, and accessibility and workflow testing of a
  panel is its own piece of work.
* **Cost on realistic large tables is not benchmarked in CI.** The opt-in script
  reports it; the budgets there are advisory unless run with
  `--strict-benchmark`.
* **Cross-language storage round trips** are validated against this document's
  contract and a Python reference for the mathematics, not yet against R, DuckDB
  or a browser client.

## 8. Residual risks and limitations

* Counts reach the layer as binary64 from the results database. Values above
  2^53−1 are refused, so a table whose counts exceed that cannot be summarised
  here even though DuckDB could hold them exactly. This is a deliberate
  refusal over a silent loss of exactness.
* Exact rationals grow. `max_digits` bounds them, and exceeding it in `exact` mode
  fails the entry rather than degrading to floating point. A user who wants a
  number at any cost can select `bigfloat` explicitly.
* `describe.alpha` does not normalise for sequencing depth. Comparing raw index
  values across samples of different depth is not valid, and the method's
  limitations say so; `rarefaction.expected_richness` exists for the
  depth-standardised question.
* Simpson's index here is the plug-in Gini–Simpson complement on observed
  relative abundances. It is not an unbiased estimator of the population index.
* No statistic in this layer accounts for compositionality beyond the warning in
  `describe.proportions`.
* The `float64` mode rounds as binary64 does, so its values can differ in the last
  bit from the existing `DiversityMetrics` routines even where both are correct.
  The `exact` mode is the authoritative path.

## 9. Acceptance criteria in issue #1

| Criterion | Status |
|---|---|
| Approve a bounded method catalogue and publish supported/unsupported conditions | done (§2) — bounded to five descriptive methods |
| Publish numeric conversion and cross-language/storage contracts, refusing unsupported representations | done (§3, §4); round trips tested for integers and rationals |
| Known-answer cases and independent reference implementations | done (`scripts/statistics-reference.py`, enumeration) |
| Numerical stability across precision levels; adversarial cases | done in the suite |
| Property/generative tests and boundary fuzzing | done |
| Negative controls and mutation sensitivity, commands and evidence recorded | done (`scripts/statistics-negative-controls.jl`) |
| Simulation studies for bias and error rates with pre-set tolerances | bias study done; interval coverage is not applicable, because no interval is estimated |
| Representative biological datasets and null/alternative cases | **open** — needs reviewed datasets; no inferential claim exists to validate yet |
| Reproducibility, serialization, concurrent precision isolation, failure recovery | done except cancellation of a long request, which needs the job queue and is **open** |
| UI-to-backend-to-result workflows, accessibility, provenance display | **open** — backend endpoints and provenance exist; no panel |
| Existing behaviour unchanged when unselected | tested |
| Benchmarks and bounds on expensive operations | bounds enforced; timings opt-in |
| Repository/owner standards gates in CI | runs through the ordinary CI workflow; results must be reviewed on the PR |
| Independent statistical/scientific review and release approval | **open** — owner action |

The remaining open items are exactly the ones that cannot be closed by writing
code: reviewed datasets, a UI panel, cancellation through the job queue, and
independent scientific sign-off. Until they are closed, no inferential method
should be added and the companion symbolic-engine work stays blocked.
