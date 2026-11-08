<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

<!-- Paste this into the body of upstream #70, replacing the untouched
     repository template. Written for the branch after the re-signing and
     linearisation steps in ../runbook.md. -->

## Change and reason

Adds native (Julia) differential-abundance estimators alongside the existing
R-backed ones — the work tracked as issue #23. It does not claim to close that
issue.

- **`src/analysis/differential.jl`** — two new values of
  `analysis.differential.method`:
  - `aldex2`: Dirichlet posterior instances from `CompositionalDA`, keeping that
    package's expected within-instance BH values. Applying BH again to its
    expected p-values would silently implement a different method, so the
    multiple-testing family is left as the package computes it. The reported
    effect is a log2 CLR difference, not a fold change.
  - `ancombc`: the original two-group sampling-bias model. Structural-zero
    decisions are reported as such (`status = "structural_zero"`, with a note
    saying whether the absence is in one condition or both) rather than being
    given a p-value and a fold change they cannot support. The effect is a
    bias-corrected log2 fold change, with conservative Wald standard errors.
  - `DifferentialConfig` gains `mc_samples` (integer 2–4096, default 128) and
    `seed` (integer 0–`typemax(Int32)`, default 1), both validated in the
    constructor; count matrices whose values do not fit the platform's `Int`
    range are refused rather than truncated; a sample with no reads is still
    left out of the fit and named in `diagnostics.samples_without_reads`; a
    matrix with fewer than two retained taxa is refused.
  - `compositional_da_available()` reports whether the optional package could be
    loaded, so a caller can branch on the same condition the refusal uses.
- **`src/server/routes/analysis.jl`, `src/server/routes/config.jl`** — a
  per-request `method` override, spelled and case-folded exactly like the config
  key (`"ALDEX2"` and `" aldex2 "` resolve to `aldex2`; a non-string is a 400
  `invalid_config`), plus the two new keys validated through
  `_config_value_error` so a bad value is a 400, not a 500.
- **`config/defaults/pipeline.yml`** — `mc_samples` and `seed` documented with
  their defaults and their scope (ALDEx2 only; unused by `nb_glm` and
  `clr_welch`).
- **`frontend/`** — the two methods in `api/types.ts`, offered by
  `DifferentialPanel`, carried through `PipelineStages`, with the effect-label
  and CSV behaviour covered by `differentialTable.test.ts` and
  `differentialCsv.fuzz.test.ts`.
- **`test/`** — `test/unit/test_differential_native.jl` (adapter parity against
  the package's own calls, ANCOM-BC units and structural decisions, and a
  256-case configuration fuzz), plus route, boundary and CSV cases in the
  existing files, and the new file wired into `test/runtests.jl`.
- **`docs/guide/web-interface.md`** — the two methods, `mc_samples`, `seed` and
  the dependency caveat, which the guide did not describe.

**Dependency status, which decides what CI can run.** The estimators need
`CompositionalDA`, which is **not in the General registry yet**. A `[deps]`
entry with no resolvable `Manifest.toml` entry makes `Pkg.instantiate()` fail
for every checkout — that is exactly what the first CI run of this branch hit —
so `Project.toml` deliberately does not declare it. The module imports it
opportunistically, the two methods refuse with an `ArgumentError` naming the
package when it is absent, and the adapter tests skip loudly rather than fail.
`Project.toml` records what has to arrive together when it is registered.

## Validation

- **CI** — [run 42436605157](https://github.com/JoshuaJewell/MetaManifold-WebUI/actions/runs/42436605157):
  `Julia tests` **pass** (20m55s, every step including `Instantiate Julia project`,
  `Run tests`, `Process coverage` and the Codecov upload), `Agda proofs` pass
  (37s), `REUSE compliance` pass (10s), `codecov/patch` pass.
- **Per-testset counts** for the two files this change touches, from a job that
  installs Julia 1.12.5 and R and runs
  `julia --project=. test/runtests.jl test_differential test_differential_native`:
  **1013 passed, 0 failed, 18 skipped**.
  - `Native configuration boundary fuzz` — 790
  - `Native input boundaries do not depend on the package` — 5
  - `Native methods refuse by name when the package is absent` — 8
  - `Route: native method override and input refusal` — 16
  - `Native compositional DA adapter`, `ANCOM-BC adapter preserves units and
    structural decisions` — skipped: they need `CompositionalDA` installed
- **Frontend, locally** — `bun install --frozen-lockfile`, `bun run build`,
  `bun test src`: 68 pass, 1 skip, 0 fail (bun 1.4.4). CI's `Build frontend` and
  `Frontend unit tests` steps passed in the run above.
- **Versions** — Julia 1.12.5 (the pin in `Manifest.toml` and in CI); R as
  pinned by `renv.lock` in CI; bun 1.4.4 locally.
- **Not run** — the adapter parity tests against a real `CompositionalDA`
  install, because the package is not installable from a registry. Everything
  else in the suite ran in CI.

## Scope

Left out on purpose: making the native methods runnable in CI. That needs
either `CompositionalDA` registered in the General registry or a `[sources]` git
dependency, and in both cases the dependency, its `[compat]` bound and the
regenerated `Manifest.toml` must land in one change. Until then `aldex2` and
`ancombc` are wired, documented, refused by name when unavailable, and tested
for that refusal.

No lockfile changes: `Manifest.toml`, `renv.lock` and `bun.lock` are untouched,
and no generated or vendored files are added.

## Contribution checks

- [x] I followed [CONTRIBUTING.md](https://github.com/JoshuaJewell/MetaManifold-WebUI/blob/main/CONTRIBUTING.md).
- [x] This branch starts at current upstream main and contains no merges from fork main; history is linear, with no merge commits of any kind.
- [x] Every commit is signed and shows as Verified.
- [x] CI has run and passes.
- [x] Existing licensing, citation and acknowledgement text is unchanged. New and changed files carry SPDX headers for their path; `reuse lint` passes.
