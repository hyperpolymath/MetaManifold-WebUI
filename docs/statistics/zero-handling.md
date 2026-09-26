# SPDX-License-Identifier: CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

# Zero handling

What this repository does with zeros, why it does that, and what it costs. Issue #21.

## 1. The problem, stated without drama

A count table has zeros in it. Two very different things produce them, and the pipeline
cannot tell them apart:

* a **structural zero** — the taxon is not in the sample, and no amount of sequencing depth
  would find it;
* a **sampling zero** — the taxon is there, below the detection limit this run happened to
  reach.

Every method that works on log-ratios (CLR, ILR, and anything downstream of them) needs the
second kind to have a number, because `log(0)` is not a number. Every method that fills one
in makes an assumption. That is the whole of it: the choice is not between a biased and an
unbiased treatment, it is between stated and unstated bias. This repository states it:

> **All replacement is biased.** A replaced value is not a measurement. No rule determined by
> the observed data can be faithful for both of two datasets that agree on which entries are
> zero — `proofs/agda/NoRigidReplacement.agda`, machine-checked.

The provenance of every replaced table carries that sentence, because the sentence is a
theorem here and not a disclaimer.

## 2. What the policies are

| `zero_policy` | What it does | Cost |
| --- | --- | --- |
| `pseudocount` (default) | Adds a constant to every entry. | Moves the ratios among *observed* parts — the property compositional methods depend on. Cheap, well understood, wrong for CLR/ILR in the strict sense. |
| `multiplicative_replacement` | `x̃ᵢ = δ·DLᵢ` for a zero, observed parts scaled by `1 − Δ`. | Preserves the sample total and the observed-part ratios **exactly**. δ is a choice, so the result is a one-parameter family of answers. |
| `bayesian_multiplicative` | `x̃ᵢ = tᵢ·s/(S+s)` with `t` the leave-one-out profile and `s` a Dirichlet concentration. | Same invariants, and the inserted values depend on the rest of the table instead of only on the detection limit. Two assumptions (prior mean, prior concentration) instead of one. |
| `refuse` | Leaves the zeros. | `log(0)` for CLR/ILR — refused at runtime even with the acknowledgement token; for NB_GLM it means the zeros are modelled as they are, which is the honest choice for a count model but not a compositional one. |

## 3. Multiplicative replacement (Martín-Fernández et al. 2003)

Reference: Martín-Fernández, J.A., Barceló-Vidal, C., Pawlowsky-Glahn, V. (2003),
*Dealing with zeros and missing values in compositional data sets using nonparametric
imputation*, Mathematical Geology 35(3):253–278. Implementation compared against:
`zCompositions::multRepl`.

For a sample with total `S`, a per-part detection limit `DLᵢ` (by default the smallest
observed value of that part across the table), and a chosen `δ ∈ (0,1)`:

```
Δ   = δ · Σ_{i ∈ zeros} DLᵢ / S
x̃ᵢ  = δ · DLᵢ            for i a zero
x̃ᵢ  = (1 − Δ) · xᵢ       otherwise
```

Two properties hold exactly, and both are proved rather than asserted
(`proofs/agda/ZeroReplacement.agda`): the sample total `Σx̃ = Σx`, and every ratio among
observed parts `x̃ᵢ/x̃ⱼ = xᵢ/xⱼ`. The replaced values are strictly positive and strictly below
their own part's detection limit.

`δ = 0.65` is the reference's `frac` and the default here. Values below `0.01` put replaced
values far below every detection limit and warn; values at or above `0.9` approach the
observed parts and warn. `δ` outside `(0,1)` is refused at the door, and so is any δ for
which `Δ ≥ 1` — the error names the largest admissible δ for that sample, because the number
is a property of the sample and the user should not have to search for it.

**Relation to the reference, precisely.** `multRepl` divides the zeros by the adjustment and
closes the table to its original total; this implementation scales the observed parts by
`1 − Δ` and preserves each sample's total. The two agree exactly on closed tables (where the
divisor and the closure cancel) and this one, unlike the reference's `output="p-counts"`,
preserves totals on count tables with differing library sizes. Dividing our result by the
sample total reproduces the reference's proportional output in both regimes.

## 4. Bayesian multiplicative replacement (Martín-Fernández et al. 2015)

Reference: Martín-Fernández, J.A., Hron, K., Templ, M., Filzmoser, P., Palarea-Albaladejo, J.
(2015), *Bayesian-multiplicative treatment of count zeros in compositional data sets*,
Statistical Modelling 15(2):134–158. Implementation compared against:
`zCompositions::cmultRepl(method = "GBM")`.

The zero of part `i` in sample `j` is given the posterior mean of a Dirichlet-multinomial
model whose prior mean is that part's **leave-one-out** profile

```
tᵢⱼ = (Σ_{k≠j} xᵢₖ) / (Σ_{k≠j} Σᵢ xᵢₖ)
```

and whose prior concentration is `s = 1/gmean(t)` unless the caller supplies `alpha`:

```
p̃ᵢⱼ = tᵢⱼ · s/(Sⱼ + s)      for a zero
x̃ᵢⱼ = (1 − Σp̃) · xᵢⱼ          otherwise,  returned in counts (× Sⱼ)
```

`adjust = true` (the reference's default) caps a replaced value at `threshold ×` the smallest
observed proportion of that part, with `threshold = 0.65`; the number of capped entries is
reported rather than hidden. Sums of replaced proportions that would reach 1 are refused, as
the reference does. A part observed in fewer than two samples has no leave-one-out profile
and is refused by name.

**Relation to the reference, precisely.** The returned counts are the closed (proportional)
table times the sample total, so they match `cmultRepl(output = "prop") × S`; the reference's
`output = "p-counts"` instead converts its proportions back with the row total and leaves the
observed counts untouched, so its totals grow while ours are preserved. Sample totals and
observed-part ratios hold exactly here.

**The parameter is a choice.** `alpha` supplied by hand is recorded in the DEED as a
deviation from the reference's estimator, and trying several δ values and reporting the
best-looking one is exactly the p-hacking the DANGER banner exists for: at three or more δ
trials the configuration is marked dangerous and the banner names the reason.

## 5. What the alternatives are, if you do not want a replacement at all

Replacement is not the only honest answer, and for count models it is often not the best one:

* **NB_GLM with `zero_policy = "refuse"`** — the negative binomial likelihood is defined at
  zero counts; nothing has to be inserted. This is the correct pairing for a count model, and
  it is why the pipeline refuses CLR/ILR + refuse instead of quietly repairing it.
* **Zero-inflated or hurdle models** — they model the probability of a structural zero
  explicitly. Not in v1 of this pipeline; when they arrive they make the structural/sampling
  distinction a parameter rather than an assumption.
* **Occupancy/observation models** — the principled version of "the taxon may be there below
  the detection limit". They insert nothing and report uncertainty instead.
* **Filtering** — raise `advanced.min_prevalence` so sparse taxa are removed rather than
  imputed. Crude, honest, and for many amplicon datasets the right call.

The refusals above are why the pipeline's error messages name these alternatives in the
policy help (`ZeroReplacement.describe_zero_policy`), rather than leaving the user to
rediscover them.

## 6. Conditions of use, in the catalogue's form

| Condition | Value |
| --- | --- |
| Applies to | any policy other than `refuse`; CLR/ILR require a replacement, count models do not |
| Invariants | sample totals and observed-part ratios preserved exactly (MR and GBM); replaced values strictly positive; GBM replaced values additionally capped by the observed proportions |
| Parameters | `delta` ∈ (0,1), default 0.65 (MR); `alpha` > 0, estimated by default (GBM); `threshold` ∈ (0,1), default 0.65 (GBM) |
| Refused | δ outside (0,1); Δ ≥ 1; all-zero samples; never-observed parts; parts observed in fewer than two samples (GBM); Σp̃ ≥ 1; α ≤ 0 or non-finite; threshold outside (0,1) |
| Warnings | δ < 0.01; δ ≥ 0.9; three or more δ trials (DANGER banner) |
| Provenance | method, parameter, detection-limit source, definition, citation, invariants, and the bias statement |
| Proved | totals and ratios, positivity, below-limit (`proofs/agda/ZeroReplacement.agda`); impossibility of unbiased recovery (`proofs/agda/NoRigidReplacement.agda`) |
| Not proved | that any particular δ or prior is the right one. That is a modelling judgement and belongs to the analyst and the paper's methods section. |

## 7. Where this lives in the code

* `src/analysis/zero_replacement.jl` — the two operators, their refusals, runtime invariants,
  diagnostics and provenance; `describe_zero_policy` is the single source of the help text
  the API and the frontend show.
* `src/analysis/Execution.jl` — `prepare_analysis_table` calls them with the configured
  overrides; the replaced table is what every downstream estimator sees.
* `src/analysis/AnalysisConfig.jl` — δ/α validation, warnings, DEED echo, DANGER banner.
* `test/unit/test_zero_replacement.jl` — the fixture comparison, the invariants, the
  refusals, and (where R is installed) the direct comparison against `zCompositions`.
* `test/fixtures/issue21/golden.json` — the pinned numbers and how they were derived.
* `proofs/agda/ZeroReplacement.agda`, `proofs/agda/NoRigidReplacement.agda` — the laws and
  the impossibility result.
