<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Method catalogue v1 — approved scope

The catalogue answers one question before any analysis runs: **which methods
does this release claim, and which does it deliberately not claim?** A missing
method must be a visible state, never a fallback.

- Machine-readable source of truth:
  `config/defaults/validated_statistics.kyaml` (KYAML, standards YAML-POLICY
  Y-3 / D307).
- Loader and validator: `src/analysis/method_catalogue.jl`.
- HTTP view: `GET /api/v1/statistics/catalogue` (canonical JCS).
- Human-facing view: `GET /statistics` renders the same approved block.
- Test: `test/unit/test_method_catalogue.jl`.

## Approval record

| Field | Value |
| --- | --- |
| Catalogue ID | `metamanifold.statistics-method-catalogue.v1` |
| Status | `approved` |
| Approved by | `hyperpolymath` |
| Approved on | `2026-09-22` |
| Approval reference | https://github.com/hyperpolymath/MetaManifold-WebUI/issues/1#issuecomment-5775420481 |
| Fingerprint | SHA-256 of the canonical (JCS) catalogue data: `catalogue_sha256` |

The fingerprint covers parsed data, not whitespace or comments, so a
reformatting that preserves meaning does not change the catalogue ID. Any
change to a status, a limit, a condition or an evidence path **does** change it
and requires re-approval.

## Status vocabulary

| Status | Meaning | May the layer claim a result? |
| --- | --- | --- |
| `supported` | Implemented, with documented conditions, published evidence and reviewed limits | Yes, within the stated conditions |
| `unsupported` | Named because users ask for it; not implemented in this release | No — the request fails explicitly |
| `deferred` | Intentionally postponed beyond the initial increment, with its own validation burden | No |
| `out_of_scope` | Not part of issue #1; the companion issue remains blocked | No |

`validate_catalogue` refuses any other status, a `supported` entry with an
empty `evidence` list, a duplicated method ID, a non-ISO approval date, or a
limit that differs from the constant the code enforces.

## v1 entries

### `exact-descriptive-summaries` — supported

Per-sample and per-group integer totals, observed richness and exact rational
proportions. Integer counts are summed in Julia `BigInt`; proportions are
`Rational{BigInt}`. Floating-point counts are refused, never upgraded.

- Not claimed: sampling uncertainty, confidence intervals, any hypothesis test.
- Zero totals: proportions are `null` and `status` is `undefined_zero_total`.
- Evidence: `test/unit/test_exact_summaries.jl`,
  `test/unit/test_statistics_boundaries.jl`,
  `test/unit/test_statistics_adversarial.jl`,
  `test/unit/test_statistics_properties.jl`,
  `test/references/exact_summary_reference.py`,
  `docs/statistics/numeric-contracts.md`.

### `high-precision-descriptive-diversity` — supported

Observed richness, Shannon entropy (`-sum(p log p)`, natural logarithms) and
Gini–Simpson diversity (`1 - sum(p^2)`) computed from exact integer counts at
an explicit MPFR precision above 53 bits.

- Not claimed: exactness, uncertainty intervals, group summaries (refused in
  this mode rather than silently ignored).
- Evidence: `test/unit/test_high_precision.jl`,
  `test/references/check_high_precision_references.py`,
  `test/unit/test_statistics_boundaries.jl`,
  `test/unit/test_statistics_adversarial.jl`,
  `test/unit/test_statistics_properties.jl`,
  `docs/statistics/numeric-contracts.md`.

### `parametric-model-fits` — unsupported

Maximum-likelihood count and composition models. Unavailable until a
conditions document, convergence and identifiability checks, known-answer
evidence and independent review exist. Selecting a model name performs no fit.

### `nonparametric-resampling` — unsupported

Permutation and bootstrap. Unavailable until resampling units, exchangeability,
seeds, Monte Carlo limitations and coverage evidence are published. A seed is
not a validation of exchangeability.

### `exact-statistical-tests` — deferred

Exact Fisher, permutation and negative-binomial tests. Deferred beyond the
initial descriptive increment (owner triage, 2026-10-15) and requiring their
own assumptions, designs, computational limits and validation. An approximate
method must never be substituted silently when an exact method is infeasible.

### `symbolic-mathematics` — out of scope

Not part of issue #1. The companion symbolic-engine issue stays blocked until
this layer is validated and explicitly approved.

## Claim language

> descriptive only; no hypothesis test, confidence interval, significance
> claim or estimator coverage guarantee is made by a supported method in this
> release

This sentence is stored in the catalogue, shown on `/statistics`, and repeated
in `VALIDATED_STATISTICS.md`. A response whose `claim` field contradicts it is
a defect.

## How to verify the catalogue

```bash
# Machine-readable view; must be canonical JCS
curl -s http://127.0.0.1:8080/api/v1/statistics/catalogue

# Validation, limits and the approval record
julia --project=. test/runtests.jl method_catalogue

# Standards formatting (yq v4.53.3, standards scripts/kyaml-format.sh)
bash scripts/kyaml-format.sh --check config/defaults/validated_statistics.kyaml
```

## Change control

1. Edit the KYAML catalogue and the code together. The loader refuses a limit
   that is not the enforced constant.
2. Update this document and the evidence paths.
3. Re-run `test_method_catalogue` and the standards gates.
4. Record the new approval reference. A catalogue whose `status` is not
   `approved`, or whose approval date is not ISO `YYYY-MM-DD`, fails to load —
   the layer refuses to run without an approved catalogue rather than
   defaulting to one.
