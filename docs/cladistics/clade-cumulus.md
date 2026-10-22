<!--
SPDX-License-Identifier: MPL-2.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# CladeCumulus Phylogenetic & Epistemic Integration

CladeCumulus unifies phylogenetic branch structure, taxonomic hierarchy, read
abundance aggregation, and multi-world epistemic warrant across the backend,
formal Agda proof suite, and React UI.

## Architecture Overview

1. **Formal Proof Core (`proofs/agda/MetaManifold/CladeCumulus.agda`)**
   - Checked under `--safe --without-K` with zero postulates or unsafe pragmas.
   - Proves world admissibility laws (`every⇒some`, `every⇒not-absent`, non-vacuous empty fibres), drag-and-drop move soundness (`validateMove-sound`), bottom-up cumulative read conservation (`cumulative-conserves-tips`), parent-child monotonicity (`child≤parent`), Faith's PD subset monotonicity (`faithPD-mono`) and upper bound (`faithPD-bounded`), and Unweighted UniFrac shared-vs-union branch bounds (`sharedPD≤unionPD`, `unifracNumerator≤Denominator`).

2. **Epistemic Warrant & Receipts (`src/core/epistemic.jl`)**
   - `WorldCandidate`, `Case`, `present_in_every_admissible_world`, `present_in_some_admissible_world`, `absent_in_every_admissible_world`.
   - Canonical accessible palette: `#2e7d32` (`present_in_every`), `#f9a825` (`present_in_some`), `#9e9e9e` (`absent`), `#c62828` (`sans_fibre`).
   - Residual uncertainty cloud diameter: `log(1 + residual_count) * 10 + 5`.
   - Tamper-evident canonical SHA-256 `Receipt` over study, run, source digests, binary SHA-256 tool records, parameters, and scientific caveats.

3. **Amplicon Sequence Phylogeny (`src/pipeline/phylogeny/amplicon_tree.jl`)**
   - Supports `FastTree` (`2.2.0`, `-nt -gtr -gamma`), `IQ-TREE` (`3.1.4`), and pure-Julia Jukes–Cantor Saitou–Nei Neighbor-Joining (`:nj`) with column bootstrap support.
   - Protects large studies via deterministic `select_asv_subset` (`max_asvs`, default `500`), safe token remapping for headers containing semicolons (`ASV_1;size=142`), and explicit short-amplicon approximation warnings.

4. **Dual-Hierarchy Cladistics & Phylogenetic Diversity (`src/analysis/clade_cumulus.jl` & `src/analysis/diversity.jl`)**
   - Supports `:phylogenetic`, `:taxonomic`, and `:combined` modes, surfacing non-monophyletic / dispersed taxa and discordant clades.
   - Strict raw `.jplace` evidence reader (`parse_jplace`) without defaulting missing `like_weight_ratio` values to `1.0`.
   - Exact `faith_pd`, `clade_faith_pd`, `unweighted_unifrac`, and `weighted_unifrac` (`normalized = false | true`), verified against `scikit-bio` reference outputs.

5. **Non-Destructive Server Routes & Evidence Mode UI (`src/server/routes/clade_cumulus.jl`, `frontend/src/components/EvidenceModeToggle.tsx`, `frontend/src/components/CladeCumulusPanel.tsx`)**
   - Gated behind an explicit `CladeCumulus Evidence Mode` switch on the Study `Trees` tab so standard workflows are never altered silently.
   - Counterfactual clade reassignments are validated against `present_in_every_admissible_world` and stored only as optional sidecars under `projects/{study}/trees/.clade_cumulus/`, leaving canonical run DuckDB tables untouched.
