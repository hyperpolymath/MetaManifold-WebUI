# Dataset-clustered uncertainty check — 30 October 2026

This is an **inferential sensitivity check**, not a change to the production
differential-abundance method. The existing
[null calibration report](REPORT.md) contains Wilson intervals pooling taxon
p-values, which may share estimated TSS/RLE offsets and dispersion trends.
Independent simulated datasets, rather than individual taxa, are the units
for this check.

For independent datasets i = 1..m, let n_i be valid null tests and k_i
their rejections. The pooled rate is p = sum(k_i) / sum(n_i), with
cluster standard error

`SE(p) = sqrt[m/(m-1) * sum((k_i - p*n_i)^2)] / sum(n_i)`

and a 95% **large-sample** normal interval p ± 1.959964 * SE, clipped to
[0,1]. This assumes independence between simulated datasets; it is not
an exact finite-sample guarantee. Failed fits are excluded from the rate
denominator, while their null datasets remain in the set of clusters.

## Implementation and policy

The check is written in **base R** using MetaManifold's existing pinned R
toolchain. No Python, extra R packages, external JSON/YAML processor, new
scientific algorithm or runtime dependency is introduced.

```sh
Rscript --vanilla bench/null_calibration/test_cluster_check.R
Rscript --vanilla bench/null_calibration/cluster_check.R \
  path/to/null-calibration-raw.zip > cluster-check.csv
# Alternatively provide pvalues_*.csv files directly:
Rscript --vanilla bench/null_calibration/cluster_check.R \
  --alpha=0.05 --min-clusters=30 path/to/pvalues_null_original_tss_n4_t40.csv
```

The test script contains valid/invalid fixtures for correlated and unequal
cluster sizes, missing taxon identifiers, duplicate keys, non-finite truth,
invalid p-values, all-nonnull methods, missing tests and custom alpha.
The CLI records `alpha` explicitly. It must refuse bad data; a
header-only result is not a successful evaluation.

## Source artifact and evidence

The source comparator data are from
[GitHub Actions run 40091522843](https://github.com/hyperpolymath/MetaManifold-WebUI/actions/runs/40091522843)
using native **R 4.5.0**. Original downloaded ZIP SHA-256:
`0cb93b8bac363125428b70cdc9d27fde21e04c75d317024dc4ff0804a2127869`,
5,884,846 bytes, with 240,000 and 239,958 raw rows.

The accompanying
[archived comparison CSV](results/native_cluster_check_run_40091522843.csv)
preserves 12 previously computed comparator rates and clustered intervals
from the original raw artifact. **The base-R replacement has not yet been run
against that same ZIP in the current editing environment**; numeric parity
must be checked before this PR is merge-ready. Do not infer validation
from a clean synthetic unit test alone.

| n/group | Method | Pooled null rejection | Clustered 95% interval |
|---:|---|---:|---:|
| 4 | Wald ML | 0.139651 | 0.136168–0.143134 |
| 4 | glmGamPoi QL | 0.052451 | 0.050241–0.054660 |
| 4 | edgeR QL | 0.068740 | 0.066180–0.071300 |
| 12 | Wald ML | 0.074949 | 0.072212–0.077686 |
| 12 | glmGamPoi QL | 0.049850 | 0.047613–0.052087 |
| 12 | edgeR QL | 0.071175 | 0.068532–0.073818 |

The prominent Wald inflation persists under the original clustering
re-analysis. This is a null-only comparator study under particular simulation
conditions: it does **not** measure alternative power or BH-FDR, and does
**not** justify switching the production default.

## Follow-up checks

- [ ] Execute the R fixture suite on the pinned R runtime in CI.
- [ ] Re-run R against the original digest-pinned ZIP; compare the output to
      the archived CSV within predeclared numeric tolerances.
- [ ] Confirm all PR comments, Sonar findings and signed-commit rules pass.
- [ ] Keep use of KYAML and I-JSON/JCS aligned with the canonical
      `metadatastician/kyq` and `hyperpolymath/ijson-jcs` projects when the
      relevant real CLI capabilities exist. This CSV-only tool does not
      implement or replace either format standard.
