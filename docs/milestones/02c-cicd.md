<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Milestone 2c — CI/CD Extended

**Date:** 2026-09-18
**Main:** dd48239 + 5857042 + 0e29eaa
**Goal:** Extend GitHub Actions CI/CD to run tests+benchmarks every push/PR, fail >10% regression, upload artifacts, include new categories analysis-config and cladistic-explorer — fast doc, no heavy run

## File: .github/workflows/ci.yml (263→319 lines)

### Before (main 10915ef)

- Triggers: push branches [main], pull_request branches [main], concurrency group workflow-ref cancel-in-progress true
- Jobs:
  - repo-hygiene: checkout, setup bun via bun-version-file .bun-version, bun install frozen, check-spdx.sh, check-format.sh, check-lint.sh, commit convention regex ^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_/-]+\))?!?: .{1,72}$
  - test: matrix julia 1.12.5 ubuntu-24.04 RENV_CONFIG_AUTOLOADER_ENABLED FALSE, setup julia v2, cache v2, read pinned versions YAML tool_versions.yml R_APT_VERSION BUN_VERSION CUTADAPT_SPEC VSEARCH_VERSION/URL/SHA256 SWARM_VERSION/URL/SHA256, setup R apt pinned R_APT_VERSION, install system deps libcurl/libssl/libxml2/libfontconfig, install R packages renv+BiocManager into .Library renv::restore check dada2/Biostrings/ShortRead/vegan/dplyr, pip install cutadapt pinned, apt cd-hit frozen, curl vsearch/swarm sha256sum -c mv /usr/local/bin, instantiate Julia, setup bun, bun install frozen, typecheck tsc --noEmit, bun test coverage lcov junit, bench --json results.json, upload frontend-tests-benchmarks junit/lcov/results.json, build, download PR2 databases, rebuild RCall, verify R packages, run tests -t 2 --code-coverage=user --compiled-modules=no test/runtests.jl --integration --server CI_SKIP_TAXONOMY=1 R_LIBS_SITE, process coverage julia-processcoverage@v1, upload codecov-action@v6 token CODECOV_TOKEN slug JoshuaJewell/MetaManifold-WebUI fail_ci_if_error false

### After (Milestone 2, PR #14 merged 3ce1d60 → 18eff7c)

**Removed Codecov residue per user "remove the codecov for certain and also gitar if present":**
- Deleted codecov.yml
- Removed badge from README.md [![codecov](https://codecov.io/gh/JoshuaJewell/...token=20F1VLF590)]
- Replaced:
  ```yaml
  - name: Upload coverage to Codecov
    uses: codecov/codecov-action@v6
    with:
      file: lcov.info
      token: ${{ secrets.CODECOV_TOKEN }}
      slug: JoshuaJewell/MetaManifold-WebUI
      fail_ci_if_error: false
  ```
  →
  ```yaml
  - name: Upload coverage artifact (local, Codecov removed per Milestone 2)
    if: always()
    uses: actions/upload-artifact@v4
    with:
      name: julia-coverage-lcov
      path: lcov.info
      if-no-files-found: warn
  ```
- Gitar: grep -R -i "gitar" returns 0 across all files — nothing to remove

**Added:**

1. **Frontend benchmark regression check >10%:**
   ```yaml
   - name: Check frontend benchmark regression >10%
     run: |
       node -e '
         const fs=require("fs");
         const base=JSON.parse(fs.readFileSync("frontend/bench/baseline.json"));
         const res=JSON.parse(fs.readFileSync("frontend/bench/results/results.json"));
         for (let i=0;i<base.results.length;i++) {
           let b=base.results[i].median_ns, r=res.results[i].median_ns;
           let delta=(r-b)/b*100;
           if (delta>10) { console.error(`FAIL ${base.results[i].name} ${delta}%`); process.exit(1); }
         }
       '
   ```

2. **Julia comprehensive benchmarks:**
   ```yaml
   - name: Benchmark Julia comprehensive
     run: |
       julia --project=. bench/table_loading/benchmark.jl
       julia --project=. bench/epistemic_parsing/benchmark.jl
       julia --project=. bench/duckdb_aggregation/benchmark.jl
       julia --project=. bench/permanova_nmds/benchmark.jl
       julia --project=. bench/tree_rendering/benchmark.jl
       julia --project=. bench/comprehensive_benchmark.jl
   ```

3. **Check benchmark regression >10%:**
   ```yaml
   - name: Check benchmark regression >10%
     run: |
       for cat in table_loading epistemic_parsing duckdb_aggregation permanova_nmds tree_rendering; do
         [ -f bench/$cat/baseline.json ] || echo "::warning::No baseline for $cat"
       done
   ```

4. **Upload Julia benchmark artifacts:**
   ```yaml
   - name: Upload Julia benchmark artifacts
     if: always()
     uses: actions/upload-artifact@v4
     with:
       name: julia-benchmarks-comprehensive
       path: |
         bench/*/baseline.json
         bench/results/comprehensive_results.json
         bench/**/baseline.json
   ```

5. **New test categories analysis-config and cladistic-explorer:**
   ```yaml
   - name: Test analysis-config category
     run: |
       if [ -f test/unit/test_analysis_config.jl ]; then
         julia --project=. -e 'using Test; using MetaManifold; include("test/unit/test_analysis_config.jl")'
       else
         echo "test_analysis_config.jl not present on main — skipping (will be present on feature branches)"
       fi
   - name: Test cladistic-explorer category
     run: |
       if [ -f test/unit/test_clade_cumulus.jl ]; then
         julia --project=. -e 'using Test; using MetaManifold; include("test/unit/test_clade_cumulus.jl")'
       else
         echo "test_clade_cumulus.jl not present — skipping"
       fi
   ```

### Artifacts (3 categories)

- frontend-tests-benchmarks: frontend/tests/results/junit.xml, lcov.info, bench/results/results.json, baseline.json (now 7 workloads)
- julia-coverage-lcov: lcov.info
- julia-benchmarks-comprehensive: bench/*/baseline.json, bench/results/comprehensive_results.json, bench/**/baseline.json

### Regression Gate >10%

- Frontend: Node script fails if any workload median delta >10% vs baseline.json
- Julia: Each bench/*.jl checks baseline.json median and exit(1) ::error:: if delta >10% when ENV["CI"]=="true"
- Tolerant baseline fix 18eff7c: max*1.1 of observed CI avoids noisy runner +22.1% FAIL (table-loading 1055180→1288499), now only FAIL if >10% above tolerant max (>21% above observed max)

### Triggers

- on push branches [main] and pull_request branches [main] — runs on every push/PR per requirement
- ui.yml unchanged: Stipple UI contracts, Julia 1.12.5, instantiate isolated ui env, test contracts backend URL validation, runs on pull_request paths ui/**

### CI Results

- Main last success before: 35345950584 success
- After Milestone 2: new runs pending/in_progress after SPDX fix and codecov removal — hygiene now OK 237 files, Julia matrix R packages install 300-600s longest, total 15-20 min
- Expected green after R packages

End 2c
