# Null-calibration bench report (issue #193)

This report records the one run that has actually been executed, superseding the
reduced 2026-10-22 run in this file's history. Anything not listed here has not
been run. The committed summary CSVs in `results/`
(`calibration_summary.csv`, `power_summary.csv`) are the source of truth for
every number below; the per-cell run records are `results/provenance_summary.csv`
(generated from the per-cell provenance files, not hand-written). The raw
p-value files under `results/raw/` are gitignored and reproducible from the
recorded seeds and arguments.

## Run identity

- **Date:** 2026-10-23 (UTC, per-cell provenance records).
- **Executor:** WebR 0.6.0 (R 4.6.0, wasm32) through `webr_run.mjs`, because the
  sandbox had Node but no native R. `MASS::glm.nb` is provided by sourcing
  MASS 7.3-65's pure-R `negbin.R` (the version pinned in `renv.lock`);
  `calibration.R` strips the block's `MASS::` prefixes as a single mechanical
  substitution and records the fact in every provenance file. Native `Rscript`
  runs use the extracted block byte-identically.
- **Inputs pinned by digest:** `bench/null_calibration/calibration.R`
  md5 `2717e709ff718e57e602eeaff2410e71`; extracted `_FIT_R` block md5
  `cc9efdfdd6e4efe2f9a393ba4d178ce0`.
- **Not available in this sandbox:** `glmGamPoi` and `edgeR` (compiled
  Bioconductor packages). `wald_trend`, `glmgampoi_ql` and `edger_ql` were
  therefore not run; their code paths in `calibration.R` are unexecuted here.
  §"What was not run" gives the commands for a native R/Bioconductor run.
- **Tests run in every cell:** `wald_ml` (the production `_FIT_R` block,
  `da_use_gp = FALSE`), `lrt` and `ql_f` (both from one full `glm.nb` fit, plus
  one intercept-only fit shared by `lrt`).
- **Seeds:** `seed0 = 20261020`; per-sim seed =
  `(seed0 + cell_key × 1000003 + sim) mod 2³¹−1`, where `cell_key` is a hash of
  the cell's identity string. A cell therefore reproduces dataset-for-dataset
  regardless of which other cells are requested, in which order, or in how many
  processes.

## Cells run

| purpose | shape / offset | samples per group | sims × taxa |
|---|---|---|---|
| direct replication | `original` / `tss` | 3, 4, 6, 8, 12, 20 | 1,000 × 40 each |
| shape variation | `constant`, `sparse`, `unequal_lib` / `tss` | 4, 12 | 400 × 40 each |
| offset variation | `original` / `rle` | 4, 12 | 400 × 40 each |
| power | `original` / `tss`, 25% of taxa at \|log2FC\| = 1 | 4, 12 | 400 × 40 each |

16 cells, 10,000 simulated datasets (6 × 1,000 + 10 × 400). Wall-clock
≈ 3 h 45 min across two single-threaded workers.

## Results

A cell is **anti-conservative** when the lower bound of the Wilson 95% interval
for its α = 0.05 rejection rate exceeds 0.05, and **conservative** when the
upper bound is below 0.05; that verdict is a column of
`calibration_summary.csv`. With ~12k–40k null p-values per cell, the KS
statistic is supporting evidence only — it detects departures far too small to
change a decision at any single α, which is why its p-value is extreme in
almost every cell while the α = 0.05 rate may be within a point of nominal.

### Direct replication (original shape, TSS offset, null)

Issue #193 reported Wald at 4/group 0.132 and at 12/group 0.069 (α = 0.05).
This run lands on 0.1395 and 0.0749: **the finding replicates.**

| n/group | test | sims | α=0.01 | α=0.05 (Wilson 95%) | α=0.10 | KS D | fail rate | verdict at 0.05 |
|---:|---|---:|---:|---|---:|---:|---:|---|
| 3 | `wald_ml` | 1000 | 0.0897 | **0.1720** (0.1682–0.1759) | 0.2407 | 0.150 | 5.87% | anti-conservative |
| 3 | `lrt` | 1000 | 0.0421 | 0.1236 (0.1202–0.1270) | 0.1975 | 0.123 | 7.76% | anti-conservative |
| 3 | `ql_f` | 1000 | 0.0064 | 0.0441 (0.0420–0.0462) | 0.0997 | 0.025 | 5.87% | conservative |
| 4 | `wald_ml` | 1000 | 0.0645 | **0.1395** (0.1360–0.1429) | 0.2030 | 0.110 | 2.80% | anti-conservative |
| 4 | `lrt` | 1000 | 0.0319 | 0.1010 (0.0980–0.1040) | 0.1696 | 0.089 | 3.85% | anti-conservative |
| 4 | `ql_f` | 1000 | 0.0092 | 0.0545 (0.0523–0.0568) | 0.1115 | 0.027 | 2.80% | anti-conservative |
| 6 | `wald_ml` | 1000 | 0.0401 | 0.1043 (0.1013–0.1074) | 0.1673 | 0.071 | 0.75% | anti-conservative |
| 6 | `lrt` | 1000 | 0.0225 | 0.0804 (0.0778–0.0831) | 0.1435 | 0.056 | 1.03% | anti-conservative |
| 6 | `ql_f` | 1000 | 0.0117 | 0.0583 (0.0561–0.0607) | 0.1162 | 0.024 | 0.75% | anti-conservative |
| 8 | `wald_ml` | 1000 | 0.0313 | 0.0904 (0.0876–0.0933) | 0.1495 | 0.055 | 0.23% | anti-conservative |
| 8 | `lrt` | 1000 | 0.0182 | 0.0726 (0.0701–0.0752) | 0.1328 | 0.045 | 0.30% | anti-conservative |
| 8 | `ql_f` | 1000 | 0.0124 | 0.0601 (0.0578–0.0625) | 0.1161 | 0.023 | 0.23% | anti-conservative |
| 12 | `wald_ml` | 1000 | 0.0219 | 0.0749 (0.0724–0.0776) | 0.1322 | 0.037 | 0.03% | anti-conservative |
| 12 | `lrt` | 1000 | 0.0143 | 0.0630 (0.0606–0.0654) | 0.1212 | 0.030 | 0.04% | anti-conservative |
| 12 | `ql_f` | 1000 | 0.0124 | 0.0577 (0.0554–0.0600) | 0.1131 | 0.018 | 0.03% | anti-conservative |
| 20 | `wald_ml` | 1000 | 0.0166 | 0.0639 (0.0615–0.0663) | 0.1168 | 0.021 | 0.00% | anti-conservative |
| 20 | `lrt` | 1000 | 0.0124 | 0.0577 (0.0554–0.0600) | 0.1102 | 0.018 | 0.01% | anti-conservative |
| 20 | `ql_f` | 1000 | 0.0120 | 0.0560 (0.0538–0.0583) | 0.1056 | 0.012 | 0.00% | anti-conservative |

Readings:

- **The production default is anti-conservative at every measured size,
  including 20 per group.** At 4/group it rejects a true null at α = 0.05 more
  than twice as often as nominal.
- **The LRT (option 1 in #193) is a mitigation, not a fix.** It removes roughly
  a third of the excess (4/group: 0.1395 → 0.1010) and is still anti-conservative
  in every cell, at the cost of more failed fits at small n.
- **The quasi-likelihood F test is much closer, and still not nominal.** It is
  conservative at 3/group (0.0441, upper bound 0.0462) and mildly
  anti-conservative from 4/group on (0.0545 rising to ~0.060 by 8/group, then
  easing to 0.0560 at 20/group). Its excess is ~1 point at α = 0.05, versus
  ~2.4 points (LRT) and ~9 points (Wald) at 4/group.
- `ql_f` and `wald_ml` have identical fit-failure rates because they use the
  same full fit; `lrt` fails more often because it needs a second fit.

### Other shapes and the RLE offset (α = 0.05, Wilson 95%)

| shape / offset | n/group | test | sims | α=0.05 (95% CI) | α=0.01 | α=0.10 | fail rate | verdict |
|---|---:|---|---:|---|---:|---:|---:|---|
| `constant` / tss | 4 | `wald_ml` | 400 | 0.1397 (0.1343–0.1453) | 0.0617 | 0.2023 | 4.00% | anti-conservative |
| `constant` / tss | 4 | `lrt` | 400 | 0.0992 (0.0945–0.1040) | 0.0299 | 0.1709 | 5.20% | anti-conservative |
| `constant` / tss | 4 | `ql_f` | 400 | 0.0555 (0.0520–0.0593) | 0.0094 | 0.1132 | 4.00% | anti-conservative |
| `constant` / tss | 12 | `wald_ml` | 400 | 0.0745 (0.0705–0.0787) | 0.0215 | 0.1303 | 0.30% | anti-conservative |
| `constant` / tss | 12 | `lrt` | 400 | 0.0625 (0.0588–0.0663) | 0.0148 | 0.1178 | 0.36% | anti-conservative |
| `constant` / tss | 12 | `ql_f` | 400 | 0.0582 (0.0547–0.0620) | 0.0128 | 0.1124 | 0.30% | anti-conservative |
| `sparse` / tss | 4 | `wald_ml` | 400 | 0.1122 (0.1067–0.1180) | 0.0456 | 0.1746 | 15.12% | anti-conservative |
| `sparse` / tss | 4 | `lrt` | 400 | 0.0859 (0.0809–0.0911) | 0.0266 | 0.1491 | 18.06% | anti-conservative |
| `sparse` / tss | 4 | `ql_f` | 400 | 0.0450 (0.0414–0.0488) | 0.0049 | 0.0974 | 15.12% | conservative |
| `sparse` / tss | 12 | `wald_ml` | 400 | 0.0700 (0.0660–0.0742) | 0.0182 | 0.1261 | 4.61% | anti-conservative |
| `sparse` / tss | 12 | `lrt` | 400 | 0.0597 (0.0560–0.0636) | 0.0132 | 0.1163 | 5.01% | anti-conservative |
| `sparse` / tss | 12 | `ql_f` | 400 | 0.0576 (0.0540–0.0614) | 0.0127 | 0.1165 | 4.61% | anti-conservative |
| `unequal_lib` / tss | 4 | `wald_ml` | 400 | 0.1405 (0.1352–0.1461) | 0.0658 | 0.2051 | 1.76% | anti-conservative |
| `unequal_lib` / tss | 4 | `lrt` | 400 | 0.1027 (0.0980–0.1075) | 0.0350 | 0.1726 | 3.08% | anti-conservative |
| `unequal_lib` / tss | 4 | `ql_f` | 400 | 0.0552 (0.0517–0.0588) | 0.0108 | 0.1120 | 1.76% | anti-conservative |
| `unequal_lib` / tss | 12 | `wald_ml` | 400 | 0.0730 (0.0690–0.0771) | 0.0226 | 0.1302 | 0.03% | anti-conservative |
| `unequal_lib` / tss | 12 | `lrt` | 400 | 0.0622 (0.0585–0.0660) | 0.0148 | 0.1183 | 0.07% | anti-conservative |
| `unequal_lib` / tss | 12 | `ql_f` | 400 | 0.0576 (0.0541–0.0613) | 0.0131 | 0.1103 | 0.03% | anti-conservative |
| `original` / rle | 4 | `wald_ml` | 400 | 0.1417 (0.1363–0.1473) | 0.0640 | 0.2105 | 2.97% | anti-conservative |
| `original` / rle | 4 | `lrt` | 400 | 0.1056 (0.1008–0.1105) | 0.0322 | 0.1748 | 3.95% | anti-conservative |
| `original` / rle | 4 | `ql_f` | 400 | 0.0553 (0.0518–0.0590) | 0.0086 | 0.1132 | 2.97% | anti-conservative |
| `original` / rle | 12 | `wald_ml` | 400 | 0.0805 (0.0764–0.0848) | 0.0262 | 0.1381 | 0.04% | anti-conservative |
| `original` / rle | 12 | `lrt` | 400 | 0.0678 (0.0640–0.0718) | 0.0159 | 0.1255 | 0.05% | anti-conservative |
| `original` / rle | 12 | `ql_f` | 400 | 0.0620 (0.0584–0.0659) | 0.0144 | 0.1174 | 0.04% | anti-conservative |

Readings:

- The inflation is **not specific to the original mean-varying dispersion
  shape**. Constant dispersion, sparse/zero-heavy tables and unequal library
  sizes all show Wald anti-conservative at 4 and 12 per group.
- **RLE is not a remedy.** At 12/group the Wald rate under RLE (0.0805) is
  *worse* than under TSS (0.0749), the largest departure measured at that size.
- Sparse tables are the hardest: 15% of Wald fits fail at 4/group and 4.6% at
  12/group. Failures are reported outside the tested family, so the rejection
  rates above are conditional on a fit succeeding.
- Under `sparse`, `ql_f` is conservative at 4/group (0.0450) — the same pattern
  as 3/group under `original`.

### Power and BH behaviour (25% of taxa at \|log2FC\| = 1, 400 sims)

BH is applied within each simulated dataset over its tested family, as
production does. "Null rate" is the α = 0.05 rejection rate among the truly null
taxa in the same cells.

| n/group | test | null rate @0.05 | raw power | BH power | BH FDR | mean discoveries |
|---:|---|---:|---:|---:|---:|---:|
| 4 | `wald_ml` | 0.1501 | 0.4614 | 0.2754 | **0.3618** | 4.43 |
| 4 | `lrt` | 0.1120 | 0.3908 | 0.1149 | 0.1915 | 1.63 |
| 4 | `ql_f` | 0.0610 | 0.2850 | 0.0223 | 0.0369 | 0.28 |
| 12 | `wald_ml` | 0.0936 | 0.7034 | 0.5361 | **0.1183** | 6.27 |
| 12 | `lrt` | 0.0781 | 0.6810 | 0.4681 | 0.0778 | 5.21 |
| 12 | `ql_f` | 0.0700 | 0.6742 | 0.4331 | 0.0630 | 4.74 |

Readings:

- **Wald's extra BH "power" is bought with an uncontrolled FDR**: 0.36 at
  4/group and 0.12 at 12/group against a nominal 0.05.
- At 12/group the quasi-likelihood F test keeps most of the raw power
  (0.674 vs 0.703) and much more of the BH power than the LRT (0.433 vs 0.468)
  while its FDR (0.063) is closest to nominal.
- At 4/group the QL F test is nearly powerless after BH (2.2%): with only six
  residual degrees of freedom its critical value is `F(1,6)` ≈ 5.99, i.e.
  |t| > 2.45. The calibration at that size is bought with power, and no measured
  option is a free lunch at 3–4 samples per group.

## What was not run, and why

`glmGamPoi` and `edgeR` are compiled Bioconductor packages and are not
installable in this sandbox (no native R, and the WebAssembly package repository
does not carry them). Their bench code paths are therefore unexecuted here:

```sh
Rscript -e 'renv::restore()'   # native R with the lockfile
Rscript bench/null_calibration/calibration.R \
  --shapes=original --offsets=tss --n-per=4,12 --sims=1000 --taxa=40 \
  --tests=glmgampoi_ql,edger_ql,wald_trend
Rscript bench/null_calibration/summarise.R
```

They skip *loudly* when absent (a stdout line plus a provenance record), so the
committed results never silently imply they ran. Issue #193's own measurement
remains the reference for glmGamPoi's QL F-test (0.046 and 0.048 at 4 and 12
per group); this bench adds a dispersion-scaled QL F test that can be run
without Bioconductor. Both land within about a point of nominal, against 0.14
and 0.075 for the production Wald test at the same sizes.

## Checklist mapping (#193)

Done: the 1,000-sim direct replication at six group sizes with Wilson intervals
at α = 0.01/0.05/0.10 and KS tests; constant, sparse and unequal-library shapes;
RLE as well as TSS offsets; the LRT and an additional quasi-likelihood F test
paired on identical datasets; power and BH-FDR at \|log2FC\| = 1; the bench lives
in `bench/null_calibration/` and never runs in CI.

Not done here: glmGamPoi QL F, edgeR QL F and the production `glmGamPoi`
dispersion-trend Wald option, all of which need native R + Bioconductor
(commands above); the full 1,000-sim count on the shape/offset/power cells
(400 each — sufficient to resolve a 4-point difference at α = 0.05, and stated
above rather than implied).

## Consequence for the production caveat

`_calibration_caveat` in `src/analysis/differential.jl` says the `ml` Wald test
was above nominal at every measured size through 20 per group. That claim is
unchanged by this run and is now backed by 1,000 sims per size. The caveat
needs no text change; the bench is the evidence it points to.
