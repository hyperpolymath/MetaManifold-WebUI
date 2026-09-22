<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Numeric conversion and storage contracts (v1)

**Status:** published, implemented in `src/analysis/numeric_policy.jl` (issue #1).
**Scope:** how numbers become exact, approximate or rounded; what may cross each
boundary; what is refused. Methods and their assumptions are catalogued separately in
`method-catalogue-v1-draft.md`.

## Why this document exists

Most statistics are not exact, and no policy makes them so. What a policy can do is
stop three different claims from wearing the same representation:

| Kind | What it means | May be called a fact? |
| --- | --- | --- |
| **exact** | an integer count, or a rational built from counts; no rounding in its history | yes, as a count or proportion |
| **approximate** | any floating-point value, *including arbitrary precision* | no — it is a number |
| **rounded** | an approximation cut to N digits for display | no — it is a rendering |

Higher precision is not exactness. `BigFloat` at 4096 bits still rounds; it simply
rounds further away. The only exact arithmetic in this layer is integer and rational.

## The policy

`numeric_policy(; mode, precision_bits, max_denominator_bits, round_digits)` returns an
immutable `NumericPolicySpec`, validated at construction:

| Field | Modes / limits | Default |
| --- | --- | --- |
| `mode` | `:ordinary`, `:exact_counts`, `:high_precision` | `:ordinary` |
| `precision_bits` | 2 … 1 000 000 | 53 (Float64's significand) |
| `max_denominator_bits` | ≥ 32 | 4096 |
| `round_digits` | ≥ 0 | 6 |

`:ordinary` is Float64 throughout and is the only mode under which previously saved
analyses are unchanged. Nothing in the layer switches mode on its own: a caller that
needs `:exact_counts` and is handed an `:ordinary` policy fails through
`assert_mode`, rather than receiving a Float64 that looks like the exact answer.

**Provenance.** `policy_fingerprint(spec)` is a SHA256 over the policy's fields. Two
runs may be compared only when this agrees; it is recorded alongside a run, so a
result can never be attributed to a policy that was not in force.

## Contracts, boundary by boundary

**Counts.** `require_count(x)` accepts integers, and floats only when finite, integral
and within 2^53. Beyond that a Float64 holds *a* value but cannot prove *which*
integer it was — and the float in hand may have been rounded earlier by R, a CSV
reader or a JavaScript client, a history that cannot be inspected. Such a value is
refused. `checked_count_sum` refuses to wrap: overflow raises `CountOverflowError`
unless `on_overflow = :widen` carries the total in `BigInt`.

**Proportions.** `exact_relative_abundance(count, total)` returns `Rational{BigInt}`, or
`nothing` when `total == 0`. Julia's own `//` would answer `1//0` here — a non-finite
`Rational` that renders as a number — so the zero denominator is refused before the
division. `nothing` means "this sample has no composition", an unsuccessful state the
presentation layer must render as such, never as `0.0`. `exact_rational_sum` bounds
denominator growth and raises `ResourceLimitError` when the budget is exhausted.

**JSON and the browser.** A JSON number on the way through a JavaScript client is a
Float64, so:

| Value | JSON form |
| --- | --- |
| integer, \|n\| ≤ 2^53 − 1 | JSON number |
| integer beyond that | **string** (a count of 9007199254740993 arrives as …93, not …92) |
| rational | **string** `"n/d"` |
| `BigFloat` | **string**, decimal — its precision is why it is not a Float64 |
| finite `Float64` | JSON number |
| `NaN`, `±Inf` | **refused** — JSON has no representation for them |

`to_storage` applies the same rules to a wrapped value; `to_display` is the *only*
place a value is rounded, and the string it returns names its own kind.

**CSV.** Text in, text out, no types. A count read back from CSV is a `Float64` via any
parser that sniffs types, so a CSV round trip of a big count is lossy and must be
declared: re-import through `require_count`, which refuses what cannot be proven.

**R.** RCall conversions go through `Float64` unless the R side returns a string;
`as.integer` overflows at 2^31, and R numerics are doubles. Counts crossing to R and
back are therefore treated as unproven integers and re-checked on return.

**DuckDB.** Integers reach 64-bit; beyond that, values must be stored as the string
form above rather than as `DECIMAL`, whose precision is a column definition and not a
property of the value.

**Records and other implementations.** Nothing in this contract normalises a version
string or a rounded display value: a value that has been rounded is marked rounded
where it is created, so no later reader has to guess.

## Concurrency

`with_precision(f; bits)` runs `f` at an explicit BigFloat precision and returns
`(result, achieved_bits)`. Precision is a **process global** in Julia, not a
task-local, so the scope is serialised behind a lock (the same trade the R runtime
makes), and the achieved bits are read inside the scope — reading them afterwards
reports the previous precision. Separate processes have separate globals; the lock
guards one process. The test suite asserts six concurrent tasks each observe their own
precision and the default is restored afterwards.

## What this document does not claim

- It does not make any statistical method exact. Methods, their assumptions and their
  supported designs are the catalogue's business, and that catalogue is a draft
  awaiting review.
- It does not remove measurement error, sampling uncertainty, model misspecification or
  biological bias. Precision is not accuracy.
- It does not cover symbolic mathematics, which is out of scope for issue #1.
- Exact statistical tests (Fisher, exact negative binomial, permutation) remain
  deferred; when they arrive they need their own assumptions, limits and known-answer
  cases, and an approximate method must never be substituted silently.
