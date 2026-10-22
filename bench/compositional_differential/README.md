<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Compositional Differential Abundance Benchmark & Method Guide

This benchmark evaluates runtime and memory allocation across all five
differential abundance methods implemented in `src/analysis/differential.jl`
(`nb_glm`, `clr_welch`, `ancom_bc`, `aldex2`, and `songbird`) on three
deterministic synthetic community profiles (`mock`, `gut`, and `soil`), and
enforces a 10% runtime regression gate for the baseline methods (`nb_glm` and
`clr_welch`).

## Running the Benchmark

```bash
# Print runtime and memory table comparing every method against clr_welch
julia --project=. bench/compositional_differential/benchmark.jl

# Record a baseline on a machine before modifying differential.jl
julia --project=. bench/compositional_differential/benchmark.jl --record-baseline /tmp/da_baseline.yml

# Enforce the 10% regression gate on nb_glm and clr_welch
julia --project=. bench/compositional_differential/benchmark.jl --baseline /tmp/da_baseline.yml
```

## Choosing a Differential Abundance Method

Amplicon sequencing observes relative read counts subject to an arbitrary
per-sample sequencing depth rather than absolute microbial cell counts
(Gloor et al. 2017; Nearing et al. 2022). Every method below enforces mandatory
Benjamini–Hochberg (`padj`) false-discovery adjustment across the fitted family
and refuses non-integer or degenerate inputs explicitly.

| Method | Primary Estimand | Zero Handling | Key Assumption & Best Use Case |
|---|---|---|---|
| `nb_glm` | Absolute $\log_2$ fold change | Exact count likelihood (no pseudocount; separated single-group taxa flagged `failed`) | Negative-binomial GLM with `tss` or `rle` size-factor offset (`ml` or `glmGamPoi` dispersion). Best when library size scales proportionally with total microbial load and biological overdispersion is substantial. |
| `clr_welch` | Difference in mean CLR | Bayesian-multiplicative (`zCompositions::cmultRepl`, `replacement_delta`) | Fast two-sample Welch's t-test on centred log-ratios. Best for well-observed communities with low sparsity and approximately symmetric compositional changes. |
| `ancom_bc` | Bias-corrected $\log_2$ fold change | Unit pseudocount $\log(Y + 1)$ with within-group sample offsets | Estimates unknown between-group sampling-fraction bias $\delta$ via a safeguarded SQUAREM 3-component Gaussian mixture (Lin & Peddada 2020) and propagates $\widehat{\mathrm{Var}}(\hat{\delta})$ into two-sided Wald tests. **Recommended when total microbial load or asymmetric shifts (e.g. blooms) would shift the geometric mean under standard CLR**, provided fewer than half of the tested taxa are differentially abundant ($d \ge 10$ recommended). |
| `aldex2` | Standardized CLR effect size (`median(btw / winmax)`) | `Dirichlet(count + 0.5)` Monte-Carlo draws (`mc_samples`, seeded by `seed`) | Propagates technical sampling uncertainty on low-depth and sparse tables without deterministic zero imputation (Fernandes et al. 2013, 2014). Conservative false-positive control across diverse 16S cohorts (Nearing et al. 2022). |
| `songbird` | CLR-centred multinomial differential ($\sum_j \hat{\gamma}_j = 0$) | Exact multinomial likelihood; completely separated single-group taxa flagged `failed` | Reference-frame invariant differentials from baseline-category multinomial regression (Morton et al. 2019; Zhang et al. 2017) with $O(K)$ Sherman–Morrison Fisher-information inversion. Conditions on read totals without extra-multinomial biological overdispersion, so inspect effect magnitudes alongside `ancom_bc` or `aldex2` when biological dispersion is large. |

## References

- Anders S, Huber W (2010). Differential expression analysis for sequence count data. *Genome Biology* 11:R106.
- Benjamini Y, Hochberg Y (1995). Controlling the false discovery rate: a practical and powerful approach to multiple testing. *Journal of the Royal Statistical Society: Series B* 57(1):289–300.
- Fernandes AD, Macklaim JM, Linn TG, Reid G, Gloor GB (2013). ANOVA-like differential expression (ALDEx) analysis for mixed population RNA-Seq. *PLoS ONE* 8(7):e67019.
- Fernandes AD, Reid JN, Macklaim JM, McMurrough TA, Edgell DR, Gloor GB (2014). Unifying the analysis of high-throughput sequencing datasets: characterizing RNA-seq, 16S rRNA gene sequencing and selective growth experiments by compositional data analysis. *Microbiome* 2:15.
- Gloor GB, Macklaim JM, Pawlowsky-Glahn V, Egozcue JJ (2017). Microbiome datasets are compositional: and this is not optional. *Frontiers in Microbiology* 8:2224.
- Lin H, Peddada SD (2020). Analysis of compositions of microbiomes with bias correction. *Nature Communications* 11:3514.
- Martín-Fernández JA, Barceló-Vidal C, Pawlowsky-Glahn V (2003). Dealing with zeros and missing values in compositional data sets using nonparametric imputation. *Mathematical Geology* 35(3):253–278.
- Morton JT, Marotz C, Washburne A, et al. (2019). Establishing microbial composition measurement standards with reference frames. *Nature Communications* 10:2719.
- Nearing JT, Douglas GM, Hayes MG, et al. (2022). Microbiome differential abundance methods produce different results across 38 datasets. *Nature Communications* 13:342.
- Zhang Y, Zhou H, Zhou J, Sun W (2017). Regression models for multivariate count data. *Journal of Computational and Graphical Statistics* 26(1):1–13.
