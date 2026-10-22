# Issue #1 validation matrix: validated descriptive statistics

This matrix covers only the increment in the associated pull request. It is not
a validation claim for the pre-existing differential methods and it is not
independent scientific review.

## Method conditions and evidence

| Operation | Bounded domain / explicit unsuccessful condition | Independent or known-answer check | Adversarial and property evidence | Status in this increment |
| --- | --- | --- | --- | --- |
| Integer count validation | Non-negative integer; booleans, fractions, NaN/Inf and unsafe float history rejected | Literal integer and unit-rational fixtures | Negative, fractional, nonfinite, Boolean, `2^54` float, ragged JSON and exponent-token tests | Implemented; final CI evidence attached to PR |
| Checked totals | Fixed-width overflow throws unless widening was explicitly selected | `typemax(Int)` boundary | Fixed-width overflow and mixed `BigInt` cases | Implemented |
| Exact sample proportions | Non-negative counts and positive total; zero total gives undefined values | `[1,1,1]` gives three `1/3`; single nonzero feature gives `1//1` | Values beyond `2^53`, zero-total samples, scale invariance, feature permutations, random integer matrices with proportions summing to one | Implemented |
| Exact group proportions | Same count contract; members and group labels are bound to the input fingerprint | Hand-computed two-group fixture | Empty groups and aligned-label failures; group zero-total state | Implemented |
| Observed richness | Number of strictly positive exact counts; empty sample richness is zero | Uniform three-taxon and single-taxon fixtures | Empty and extreme-scale samples | Implemented |
| High-precision Shannon | Positive total; scoped MPFR precision above 53 bits; undefined at zero total | Python `decimal` references for `log(2)`, `log(3)`, and counts `[1,2,3,4]` at a 220-digit context | Extreme rare-taxon scale that underflows `Float64`; precision round-trip and concurrent 128/256/512/1024-bit scopes | Implemented; no exactness or sampling-error claim |
| High-precision Gini–Simpson | Positive total; exact `(N²-Σc²)/N²` intermediate within the configured rational budget; undefined at zero total | Exact known answers `2/3`, `0`, and `7/10`, converted once to MPFR | Extreme scale, budget exhaustion, serialization and concurrency tests | Implemented |
| Fixed-decimal display | Display only; exact/storage values remain separate | `1/3`, `1/2`, and negative half-way fixtures | Huge `BigFloat` display avoids `Float64` overflow; ties-away-from-zero check | Implemented |
| Direct JSON boundary | JSON object, explicit validated policy, features-by-samples matrix, 16 MiB / 100,000-cell limits | In-process and real-listener request fixtures | Deterministic malformed-input fuzz, wrong shapes, unsafe integers, float representations and unknown policies | Implemented |
| Run/DuckDB boundary | Read-only database; supported integer column schemas; no missing/negative counts; bounded grouped matrix | Taxon totals computed by hand | `HUGEINT` pair whose sum overflows SQL `SUM`, float schema, NULL and negative controls, unsupported sample-read filter | Implemented |
| Immutable derived analysis | Canonical JSON-safe record; content ID recomputed on load; no replacement of an existing destination | Repeat save/load and canonical-byte round trip | Concurrent publishers, same-ID tampering, invalid record, failed publication cleanup and source/run ownership checks | Implemented |

The high-precision reference generator is
`test/references/check_high_precision_references.py`; it uses Python's `decimal`
module and does not read output from the Julia implementation. The CI job checks
that the constants embedded in the Julia tests still match that independent
generator.

## Serialization, concurrency and failure recovery

- Exact values larger than the I-JSON range, all rationals, and MPFR decimals are
  strings in canonical records. JSON response tests cover a value above `2^53`.
- A stored MPFR decimal is parsed directly into a new `BigFloat` at its recorded
  precision and checked for value equality, without a `Float64` intermediate.
- Concurrent tests vary precision in spawned tasks and publish the same derived
  ID repeatedly. Exactly one publisher may report `created=true`; all must see
  the same complete record.
- A modified same-ID record fails its content check and is not overwritten.
  Failure before publication leaves no final or temporary file.
- The run route uses the existing read-only opener. Derived files live outside
  the merged results database directory.

## Performance evidence

`bench/validated_statistics.jl` measures exact summaries at three table sizes,
high-precision summaries at 64/256/1024 bits, and sequential/concurrent batches.
It reports every trial, median runtime, median allocation, software versions,
platform and thread count. CI retains the resulting JSON artifact for 30 days.
There is intentionally no cross-platform timing threshold and no claim that
higher precision is computationally free.

## What remains open

The following cannot be inferred from the tests above:

1. **Representative biological validation.** Synthetic boundary fixtures are not
   biological certification. Applicable comparisons with real or curated
   biological data and any pre-registered reference analyses remain required.
2. **UI/workflow acceptance.** The new modes are exposed through the API in this
   increment. Browser presentation, accessibility, warnings, provenance
   workflows and their tests remain an acceptance task; no application
   TypeScript was added.
3. **Simulation-based estimator evaluation.** These operations are deterministic
   descriptive transformations, not newly proposed estimators with a claimed
   confidence/coverage property. A simulation cannot certify the separate
   pre-existing inferential methods; method-specific simulation and sensitivity
   studies remain necessary wherever issue #1 requires them.
4. **Mutation and broader recovery/soak testing.** Negative controls and
   metamorphic properties are present, but a retained mutation-testing campaign,
   expensive-operation cancellation tests, crash-durability tests and long soak
   runs are not claimed.
5. **Independent review and release approval.** The implementation author and CI
   cannot supply independent statistical/scientific review or the project's
   explicit release approval. Those records must come from the designated
   reviewers.
6. **Deferred methods.** Exact Fisher/permutation/NB tests and symbolic
   mathematics are not implemented or unblocked.

Consequently, this matrix supports review of a bounded increment; it does not
justify administrative closure of issue #1 on its own.
