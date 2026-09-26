<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000002
parent: null
position: 50
kind: page
tags:
  - status
  - roadmap
  - overview
archived: false
-->

# Status and roadmap

**The board.** Everything MetaManifold claims to do is marked here as IN
PLACE, PARTIAL, COMING or BLOCKED (legend on [Home](Home)). Dates are
Europe/London. The repository tree is the final arbiter; where this page and
the code disagree, the code has moved and this page owes an update.

## Pipeline — raw reads to tables

| Capability | Status | Notes |
|---|---|---|
| cutadapt primer trimming (named primer pairs, IUPAC-validated) | **IN PLACE** | `src/pipeline/tools.jl`, `config/primers.yml`; UI editor under SYSTEM |
| DADA2 ASV lane: filter/trim, learn errors, denoise, merge, chimera cull, taxonomy | **IN PLACE** | `src/pipeline/dada2/`; R bridge pinned by `renv.lock` |
| SWARM OTU lane: merge, dereplicate, cluster, chimera check, vsearch taxonomy | **IN PLACE** | `src/pipeline/swarm.jl`, `src/pipeline/vsearch` stage |
| Optional cd-hit-est pre-clustering (multiplex inflation control) | **IN PLACE** | `cdhit:` config block |
| merge_taxa + named taxonomic filter sets | **IN PLACE** | `src/pipeline/merge_taxa.jl`, `config/composition.yml` library |
| Per-run DuckDB results store | **IN PLACE** | `src/core/duckdb_store.jl` |
| Stage freshness skipping (mtime for files, content hash for config) | **IN PLACE** | stale stages flagged with the exact changed keys |
| FastQC + MultiQC prefilter QC | **PARTIAL** | implemented and CI-exercised since #44; reports embed in the run view |
| Remote (SSH) offload of the taxonomy step | **PARTIAL** | works; authorisation is solely the operator's responsibility |
| DADA2 single-end / forward / reverse modes | **IN PLACE** | `file_patterns.mode` |

## Analysis and statistics

| Capability | Status | Notes |
|---|---|---|
| Alpha diversity (richness, Shannon, Simpson) + group comparisons | **IN PLACE** | significance reports its status; never silently degrades (#31's rule) |
| Taxonomic composition bars; organism composition categories | **IN PLACE** | category sets editable in the UI |
| Taxon overlap (Euler/UpSet), pipeline-stage read summaries | **IN PLACE** | |
| NMDS + PERMANOVA (vegan, locked R) | **IN PLACE** | permutation exchangeability is the standing caveat |
| Normalisation: none, rarefaction | **IN PLACE** | |
| TSS/CSS/RSS size-factor **offsets** (exact, not aliases) | **IN PLACE** | issues #16, #61, #62 — conditions in `docs/statistics/method-conditions/scaling-and-offsets.md` |
| Exact descriptive summaries (counts, rational proportions) | **IN PLACE** | catalogue item 1; `src/analysis/exact_summaries.jl` |
| Numeric policy: exact / approximate / rounded, explicit modes | **IN PLACE** | `src/analysis/numeric_policy.jl` |
| Parametric fits — NB-GLM, CLR/ILR-LM, logistic (ML with refusal states) | **PARTIAL** | implemented with R-reference tests; **independent statistical review (#1) outstanding** |
| Zero-depth sample healing before transforms | **IN PLACE** | #58 |
| Nonparametric tests (permutation/bootstrap) | **COMING** | catalogue item 3, approved scope only |
| Exact statistical tests (Fisher, exact NB, permutation PERMANOVA) | **COMING** | issue #3, catalogue item 4 |
| Multinomial / Dirichlet-Multinomial regression | **COMING** | issue #17 |
| Occupancy models, ZINB, hurdle | **COMING** | issue #18 |
| Constrained ordinations (RDA/CCA/CAP/dbRDA) | **COMING** | issue #19 |
| PhILR / SBP ILR bases, balance dendrograms | **COMING** | issue #20 |
| Advanced zero handling (glmGamPoi dispersion, Bayesian multiplicative) | **COMING** | issue #21 |
| ANCOM-BC, ALDEx2, Songbird-style methods | **COMING** | issue #5 |
| Symbolic formula engine | **BLOCKED** | issue #2 — waits on real-data validation of the numeric layer |

## Workbench and application

| Capability | Status | Notes |
|---|---|---|
| Config cascade (instance → study → group → run) + `run_config.yml` provenance | **IN PLACE** | UI editors at every level |
| Studies / groups / runs management, jobs panel, SSE live progress | **IN PLACE** | |
| Results explorer (filters, presets, column presets, OTU drill-down, xlsx export) | **IN PLACE** | |
| Functional annotation, consensus rank, contamination curation, FuncDB ledger | **IN PLACE** | composite confidence is explicitly curiosity-grade |
| Primers / databases / composition editors with validation and impact warnings | **IN PLACE** | |
| CladeCumulus (cumulative cladistic explorer) | **COMING** | issue #6 — data structures and validation scaffolded (`src/analysis/clade_cumulus.jl`) |
| Full Evidence Mode (epistemic editor, fibre visualiser) | **COMING** | issue #7 — epistemic core in place (`src/core/epistemic.jl`) |
| Zenodo DOI minting | **COMING** | issue #8 |
| Julia-authored Stipple/Vue UI | **PARTIAL** | first read-only slice landed; React remains default (`docs/migration/STATUS.md`) |
| Standalone offline release archives (Linux x64/ARM64, WSL2) | **COMING** | agreed requirement, no builder yet (`docs/migration/STATUS.md`) |
| Coordinated signed updater | **COMING** | same source |
| Multi-user / authenticated remote deployment | **COMING** | local single-user only until then — do not expose the server |

## Engineering estate

| Capability | Status | Notes |
|---|---|---|
| Pinned toolchain (mise exact pins + Guix peer lane; sha256 pipeline tools) | **IN PLACE** | R is a documented system exception via `renv.lock` |
| Strict TypeScript estate (0 errors; `unknown`-safe stubs) | **PARTIAL** | `skipLibCheck` exception + `alphaFig` narrowing tracked in `docs/compliance/fixme-index.md` |
| Julia + frontend test suites, type-level assertions | **IN PLACE** | DOM-lane for Plotly-chain modules **COMING** (decision queued) |
| Benchmarks with baselines (informational lane) | **IN PLACE** | promotion to non-gating regression alert after a stability window |
| CI: hygiene, pinned tools, commit gate, Dependabot auto-merge-on-green | **IN PLACE** | |
| Coverage gate | **COMING** | deliberate: gates on a recorded baseline, not an arbitrary number |
| OpenSSF Best Practices / Scorecard badges | **COMING** | enrolment first, badges on the day (never before) |
| Independent statistical review of the analysis layer | **COMING** | issue #1's acceptance gate; the reason PARTIAL marks exist above |

## Near-term order of work (as tracked)

1. Independent statistical review gate (#1) — unlocks the rest of the
   catalogue honestly.
2. Exact tests (#3) and the milestone-3 deferred suite (#17–21) in their
   approved dependency order (`docs/issues/milestone3/`).
3. Stipple UI parity and the standalone-release workstream
   (`docs/migration/STATUS.md` workstreams A and B).
4. CladeCumulus + Evidence Mode (#6–7), Zenodo (#8).
5. Symbolic engine (#2) only after the numeric layer is validated — the
   BLOCKED sign is policy, not neglect.

## Reading the history

- Closed milestone issues mean *the milestone closed*, not "every deferred
  idea shipped" — deferred designs are preserved in
  `docs/milestones/02-deferred-issues.md` and `docs/issues/milestone3/`.
- Issues #1 and #2 are the two that must never be closed prematurely (the
  owner-review record makes this explicit).
