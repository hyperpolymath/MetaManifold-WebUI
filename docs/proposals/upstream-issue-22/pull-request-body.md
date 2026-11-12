<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

<!-- The body for the upstream pull request that carries issue #22's ruling.
     Filled from .github/pull_request_template.md of JoshuaJewell/MetaManifold-WebUI
     at 89be534. Paste it when the pull request is opened. -->

## Change and reason

Adds multinomial (MN) and Dirichlet-multinomial (DM) regression to differential
abundance, the way issue #22 ruled: "MN/DM regression would come in as (2),
MGLM through RCall, in line with CONTRIBUTING." It is one commit on top of
`89be534`.

- **`src/analysis/differential.jl`**: two new values of
  `analysis.differential.method`, `multinomial` and `dirichlet_multinomial`.
  Each fits one `MGLM::MGLMreg.fit` model (`dist = "MN"` or `"DM"`) of the
  composition of the taxa that pass `min_prevalence`, conditioned on each
  sample's read total. So there is no size factor and no zero replacement.
  Every estimate is the change in a taxon's log ratio to a reference taxon,
  with a Wald z-test and Benjamini-Hochberg adjustment over the fitted taxa.
  For DM, MGLM gives every taxon its own coefficients, so the contrast is the
  difference of two group coefficients. Its standard error takes their
  covariance from the inverse of MGLM's observed information.
- **New setting `analysis.differential.mn_reference_taxon`**: the reference
  taxon. Empty (the default) uses the fitted taxon with the most reads. The
  reference row has status `reference` and no test. The setting is refused for
  `nb_glm` and `clr_welch`.
- **Refusals, not substitutes.** A taxon with no reads in every sample of one
  group (complete separation) is `failed` with its reason and left out of the
  composition. DM needs 2 samples per group. At most 1000 taxa enter one fit.
  A fit that errors, reaches MGLM's iteration cap, warns that it did not
  converge or is not at a maximum, or has an information matrix that is not
  positive definite fails every taxon with that reason. Nothing falls back to
  another model.
- **DM with no overdispersion.** When a group's counts show no overdispersion,
  its Dirichlet concentration has no finite estimate. MGLM then stops while the
  concentration is still growing. If MGLM still gives standard errors, the rows
  are marked `boundary`, as `nb_glm` does at its theta bound, and keep their
  statistics, because a log-ratio contrast does not depend on that
  concentration. If MGLM refuses the fit as a saddle point, that refusal
  stands and the message names the flat group. Only when both groups are flat
  are the estimates the multinomial's, and only then does the message point
  to `multinomial`. With one group overdispersed, the multinomial would
  understate that group's variance, and the message says so.
- **R state.** `MGLMreg.fit` sets `options(warn = -1)` while it iterates and
  restores it only on a normal return. The wrapper restores the caller's
  setting whatever happens. MGLM's internal steps raise one `non-integer x =`
  warning per value; each kind is listed once in `diagnostics.mglm.warnings`.
- **Wiring.** `MGLMUnavailable` is a 503 at the route. MGLM is in `renv.lock`,
  `install.jl`, `REQUIRED_R_PACKAGES` and both CI package checks.
  `config/defaults/pipeline.yml`, the config editor, the results panel, the CSV
  settings line, `docs/guide/web-interface.md` and `README.md` describe the two
  methods.

## Validation

All commands ran on Ubuntu 24.04 (x86-64) with Julia 1.12.5, R 4.5.0 (apt
`4.5.0-3.2404.0`, as pinned), the R library restored from this branch's
`renv.lock` with `renv::restore()`, MGLM 0.2.3, and bun 1.4.4. CI pins bun
1.3.10; I did not run the frontend with 1.3.10.

- `CI=true RENV_CONFIG_AUTOLOADER_ENABLED=FALSE julia --project=. -t 2 test/runtests.jl --server`:
  3031 passed, 6 failed, 11 broken. `Differential abundance` passed 511 of
  511. The 6 failures are all in `Provenance` / `live probes of what is
  actually installed`: cutadapt, fastqc, multiqc, vsearch, swarm and cd-hit
  are not installed on that machine. They are unrelated to this change, and
  CI installs those tools.
- `cd frontend && bun install --frozen-lockfile --ignore-scripts && bun run build && bun run test`:
  build passes (`tsc` and `vite build`); 67 pass, 0 fail.
- What the new tests check, in `test/unit/test_differential.jl`:
  - The multinomial against its closed form. With only a group term, each
    group's fitted composition is its pooled proportions. So the estimate is a
    difference of pooled log ratios, and its variance is the sum of four
    reciprocal pooled counts. Estimates agree to 1e-8 and standard errors to a
    relative 1e-8, for the default and an explicit reference.
  - The Dirichlet-multinomial against `stats::optim` (BFGS) on a likelihood
    written out in the test from the DM density, with the covariance from
    `stats::optimHess`. Estimates agree within 2e-3 and standard errors within
    a relative 2e-3. MGLM's log-likelihood is at least as high as the
    independent one.
  - The boundary on two fixed tables. With both groups flat, the estimates
    equal the closed form to 1e-4, and the standard errors are no smaller
    and at most 1% larger. With one group flat, the rows are `boundary`, the
    note does not call them multinomial, the estimates differ from the
    closed form by more than 0.03, and the standard errors are more than 3
    times the multinomial ones.
  - Each refusal named above, the 503 path when MGLM
    cannot be loaded, the route, the config checks, and that R's `warn` option
    is unchanged after a fit.
  - In CI the MGLM-dependent tests fail rather than skip when MGLM is missing,
    as the glmGamPoi tests do.
- Not run: `reuse lint` (no new files; every changed file keeps its header),
  `--integration`, and the frontend with bun 1.3.10.

## Scope

Left out on purpose:

- Penalised fits. MGLM's sparse regression (`MGLMsparsereg`) has no valid Wald
  standard errors, so it is not offered.
- Designs beyond two conditions, as for the existing methods.
- MGLM's generalised Dirichlet-multinomial and negative multinomial.

**Lockfile change, and why it is needed.** `renv.lock` gains one entry, MGLM
0.2.3 from CRAN (34 lines). Nothing else in the file changes. MGLM is pure R
(`NeedsCompilation: no`) and imports only `methods`, `stats`, `parallel` and
`stats4`. Its licence is GPL (>= 2), the same as zCompositions, which is
already pinned. `Manifest.toml` and `bun.lock` are untouched.

## Contribution checks

- [x] I followed [CONTRIBUTING.md](https://github.com/JoshuaJewell/MetaManifold-WebUI/blob/main/CONTRIBUTING.md).
- [x] This branch starts at current upstream main and contains no merges from fork main.
- [ ] Every commit is signed and shows as Verified. *(Signed with an SSH key; tick only when GitHub shows Verified.)*
- [ ] CI has run and passes. *(Tick when the pull request's CI run is green.)*
- [x] Existing licensing, citation and acknowledgement text is unchanged.
