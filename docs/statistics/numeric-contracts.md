<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Numeric and serialization contracts (issue #1)

This document is the conversion contract for the validated statistics layer. It
states, boundary by boundary, which representation is carried, which is
refused, and where the rule is tested. A claim here without a test is a bug;
a test without a claim here is an undocumented contract.

The layer is descriptive only. Nothing in this document authorises a hypothesis
test, confidence interval, significance claim or estimator coverage guarantee.

## 1. The shape of an exact value

| Concept | Julia representation | Why |
| --- | --- | --- |
| Count | `BigInt` internally, `Int64` when it round-trips | Counts are integers; `Int64` is an allocation optimisation, never a contract |
| Proportion | `Rational{BigInt}` | `1/3` has no finite binary or decimal expansion; a float is a different number |
| Total | `BigInt` from a checked sum | SQL `SUM(BIGINT)`/`SUM(HUGEINT)` can overflow; Julia addition widens |
| High-precision metric | `BigFloat` at an explicit MPFR precision | Approximation with a recorded precision, never labelled exact |
| Display | `String` rendered at `round_digits` | A rounded display is visibly separate from the stored value |

`MAX_CELLS = 100_000`, `MAX_PRECISION_BITS = MAX_DENOMINATOR_BITS =
MAX_COUNT_BITS = 1_000_000`, `MAX_ROUND_DIGITS = 100_000`,
`MAX_REQUEST_BYTES = 16_777_216`. They are defined once in
`src/analysis/numeric_policy.jl`, restated in the KYAML catalogue
(`config/defaults/validated_statistics.kyaml`) and asserted equal by
`test/unit/test_method_catalogue.jl`.

## 2. JSON: I-JSON in, JCS out

Every validated-statistics request body and response body is
[I-JSON (RFC 7493)](https://www.rfc-editor.org/rfc/rfc7493) and every emitted
value is [JCS (RFC 8785)](https://www.rfc-editor.org/rfc/rfc8785) canonical
bytes, per `hyperpolymath/standards` JSON-POLICY (D306) and the
`hyperpolymath/ijson-jcs` reference reviewed at `3a9a4ee`.

- Object keys are sorted by UTF-16 code units; there is no insignificant
  whitespace and **no trailing newline in an HTTP body**.
- Duplicate keys, lone surrogates, noncharacters, and non-finite numbers are
  refused on the raw text before a value is built.
- JSON numbers carry exactly the safe I-JSON integer range
  `-(2^53-1) .. 2^53-1`.
- **A count above `2^53-1` is a decimal string, never a JSON number.** `1` is a
  number; `"9007199254740993"` is a string.
- **Decimal and exponent tokens are refused even when their value is
  integral.** `1.0` and `1e0` are float tokens for a field that is
  contractually integral; accepting them would silently claim a precision the
  input does not have. `422 invalid_numeric_input`.
- Booleans are not integers and are not counts. `true` in a count cell is
  `422`.
- Request bodies are capped at `MAX_REQUEST_BYTES` **bytes**, not characters,
  so a multi-byte payload cannot pass a codepoint count and exhaust memory.

Evidence: `test/unit/test_statistics_boundaries.jl`,
`test/unit/test_statistics_adversarial.jl`,
`test/unit/test_validated_statistics.jl`, `test/unit/test_canonical.jl`.

### Error envelope

Errors are canonical JSON too: `{"error": "<code>", "message": "<text>"}`.
`message` never contains a stack trace. Documented statuses:

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_statistics_request` | Malformed shape, labels, policy or deadline |
| 404 | `derived_analysis_not_found` | Unknown or non-hexadecimal analysis ID |
| 408 | `statistics_cancelled` | Caller cancellation or `time_limit_seconds` exceeded; no partial result |
| 413 | `numeric_resource_limit` | Cells, bytes, bits or digits above the published limit |
| 422 | `invalid_numeric_input` | Float/boolean/negative/oversized count, or unsupported DuckDB column type |
| 409 | `derived_analysis_conflict` | A stored record does not match its content ID |

## 3. Cross-language boundaries

The same integer has a different representation in each consumer, and each
consumer fails at a different point. The contract is uniform: **exact values
cross a boundary as decimal strings; floating point never carries a count.**

| Boundary | Behaviour | Evidence |
| --- | --- | --- |
| Julia `Int64` → `Float64` | Exact through `2^53`; `2^53 + 1` rounds down silently | `MAX_EXACT_FLOAT`; refusal of `> 2^53 - 1` JSON numbers |
| JavaScript `JSON.parse` | `{"n":9007199254740993}` becomes `9007199254740992` with no error; the string form is byte-exact | Node check in `test_statistics_boundaries.jl` (skipped and announced when `node` is absent) |
| R `numeric` | R has no integer type wider than 32 bits; every number is a double, so `9007199254740993` arrives one short | Rscript check in `test_statistics_boundaries.jl` (skipped and announced when `Rscript` is absent) |
| Python | `int` is arbitrary precision; `decimal`/`fractions` are the independent reference implementations | `test/references/exact_summary_reference.py`, `check_high_precision_references.py` |
| DuckDB | `TINYINT`/`SMALLINT`/`INTEGER`/`BIGINT`/`HUGEINT` are accepted; `FLOAT`/`DOUBLE`/`DECIMAL` are refused with `422` | `_validated_integer_sample_columns`; boundary test builds one table per type |
| CSV/text | There is no CSV writer for this layer. Display strings are for humans and are labelled rounded; they are not a data interchange format | `to_display`, `summary_to_display` |

The Julia module `MetaManifold.Canonical` performs the raw-text validation, so
the browser, R and DuckDB checks are evidence about *other* parsers, not
duplicates of the same check.

## 4. Storage contract

| Artifact | Encoding |
| --- | --- |
| Derived analysis record | JCS bytes of the record object, addressed by `sha256` of `source`+`config`+`result` |
| Statistics response | JCS bytes, no trailing newline |
| Catalogue response | JCS bytes including `catalogue_sha256`, `supported_method_ids`, `method_count`, `file` |
| Counts | JSON number when `|c| <= 2^53-1`, otherwise decimal string |
| Proportions | `"numerator/denominator"` in lowest terms, or `null` when the total is zero |
| MPFR metrics | Shortest decimal that round-trips at the recorded precision, plus `precision_bits`, `kind: "approximate"` and a separate rounded `display` |
| Fingerprints | 64 lowercase hexadecimal characters (SHA-256 over JCS bytes) |

A zero-total sample has `proportions: [null, ...]`,
`proportions_defined: false` and `status: "undefined_zero_total"`. It is never
rendered as a proportion of zero and never contributes a diversity value of
zero. See `docs/statistics/zero-handling.md` for why an undefined composition
must not be replaced silently.

The immutable record file contains exactly the JCS bytes that are hashed and is
verified byte-for-byte on read. It therefore has no trailing newline: adding one
would change the object the ID addresses and break the tamper check that
distinguishes a conflicting record from a consistent one. This is a deliberate,
documented exception to the JSON-POLICY file-level trailing-newline rule, which
applies to repository-tracked JSON documents; the checked-in JSON that the
standards gate scans does carry exactly one trailing LF.

## 5. Precision is not exactness

`high_precision` computes at an explicit MPFR precision (`54` to `1_000_000`
bits) under a global precision lock. The achieved precision is recorded in the
response. It reduces arithmetic rounding error; it does not remove sampling or
measurement error, and it is not an uncertainty interval. Shannon entropy uses
natural logarithms, `-sum(p log p)`.

## 6. Reproducing a result

A result is reproducible from `input_sha256` (canonical matrix fingerprint),
`numeric_policy.fingerprint` (mode and limits) and the recorded software
versions. `time_limit_seconds` is **not** part of the policy: it is an
operational deadline, it never changes a value, and it is never stored in a
derived record. A cancelled request returns `408` and no result at all.

## 7. What would make this contract false

- A count accepted as a JSON float, or a float count silently converted.
- A response assembled with an encoder that does not sort keys or format
  numbers as ECMAScript does.
- A DuckDB `DOUBLE` column silently upgraded to an integer.
- A zero-total sample reported as zero diversity.
- A stored record that verifies despite being edited.
- A limit raised in code without the catalogue, the tests and this document
  changing with it.

Each of these has a failing test in the suite. The mutation campaign described
in `docs/statistics/validation-evidence.md` exercises a subset of them
deliberately.
