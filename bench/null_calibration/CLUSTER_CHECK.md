# Dataset-clustered uncertainty check — 30 October 2026

This is an **additional inferential sensitivity check**, not a replacement of
the saved #193 benchmark, and not a change to the production differential
abundance method. Original results: [REPORT.md](REPORT.md).

The existing `summarise.R` reports Wilson 95% intervals for pooled taxon
rejection counts. Taxa share estimated TSS/RLE offsets (and some alternative
methods share a fitted dispersion trend), so taxon-level p-values are not
guaranteed independent. Wilson intervals and pooled KS *p-values* require
independence assumptions that are not fully justified by the simulation.

This check treats each independently generated **dataset** (`sim`) as one
cluster. Let `n_i` be the valid null tests in dataset `i`, `k_i` be its
rejections, `m` be the number of independent datasets, and
`p = sum(k_i)/sum(n_i)`. The cluster-robust ratio standard error is

`SE(p) = sqrt[m/(m-1) * sum((k_i - p*n_i)^2)] / sum(n_i)`

with `p ± 1.959964*SE` clipped to [0,1]. This is a **large-sample**
95% interval, not an exact finite-sample guarantee, and it assumes
independence *between* simulated datasets. It keeps the original pooled
rejection rate and valid-test denominator unchanged. Failures are excluded
from the rate, as in the original report; no assumption about the missing
seven planned n=4 positions is introduced.

## Reproduce with Python 3 standard library only

Retrieve the `null-calibration-raw` ZIP from
[GitHub Actions run 40091522843](https://github.com/hyperpolymath/MetaManifold-WebUI/actions/runs/40091522843)
while the artifact is retained. The ZIP used for this analysis had SHA-256\n`0cb93b8bac363125428b70cdc9d27fde21e04c75d317024dc4ff0804a2127869`\n(5,884,846 bytes), containing two raw files of 240,000 and 239,958 rows.\nRun from the repository root:

```sh
python3 -m unittest discover -s bench/null_calibration -p 'test_cluster_check.py'
python3 bench/null_calibration/cluster_check.py path/to/null-calibration-raw.zip > cluster-check.csv
```

The Python script also accepts uncompressed `pvalues_*.csv` files. It refuses
duplicate test/simulation/taxon rows, malformed valid p-values and fewer than
30 clusters by default. It needs no R runtime, compiled extension, or network
connection, and it does not fit or alter any scientific model.

## Native R 4.5.0 run #40091522843: sensitivity result

| n/group | Test | Rejection rate | Clustered 95% interval |
|---:|---|---:|---:|
| 4 | production Wald ML | 0.139651 | 0.136168–0.143134 |
| 4 | glmGamPoi QL | 0.052451 | 0.050241–0.054660 |
| 4 | edgeR QL | 0.068740 | 0.066180–0.071300 |
| 12 | production Wald ML | 0.074949 | 0.072212–0.077686 |
| 12 | glmGamPoi QL | 0.049850 | 0.047613–0.052087 |
| 12 | edgeR QL | 0.071175 | 0.068532–0.073818 |

Full machine-readable output: [results/native_cluster_check_run_40091522843.csv](results/native_cluster_check_run_40091522843.csv).
These are normal-approximation cluster intervals derived **from the actual
archived 480k per-taxon records**, not newly generated simulation results.

**Interpretation:** The large Wald inflation is robust to the clustering
sensitivity check in both measured cells. The glmGamPoi n=4 interval
barely excludes 0.05 under this particular unadjusted interval, and the
n=12 interval includes it. Neither establishes a production-default choice:
the native comparator study was null-only, with no power/BH trade-off
measured for glmGamPoi; multiple comparisons and new design settings
also complicate marginal significance claims. Do not call the n=4
narrow interval a universally established miscalibration.

The saved baseline and native report have different code versions and
generators. This check applies **only to the archived native run's raw data**
and must not be represented as re-analysis of all 16 original WebR cells.
