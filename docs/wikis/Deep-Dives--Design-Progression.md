<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000041
parent: 0198ba50-0000-7000-8000-000000000040
position: 10
kind: page
tags:
  - theory
  - history
  - architecture
archived: false
-->

# Design progression

**The three-layer lineage in full**, with the receipts. The README shows the
same progression in brief; this page is the extended cut.

## Layer 1 — the base design: R and Python around DADA2

Two established open-source traditions, used *raw*, before any MetaManifold
code exists:

**The DADA2 tutorial lineage (R).** Callahan et al.'s exact-sample variant
pipeline as it is run from scripts: `filterAndTrim` (quality trim + trunc),
`learnErrors` (error rate learning), `dada` (the OME-picking-free denoiser),
`mergePairs`, `makeSequenceTable`, `removeBimeraDenovo`, `assignTaxonomy`
against a reference FASTA. In this repository that R lineage still exists,
almost verbatim, as `src/pipeline/dada2/dada2_functions.r` — the Julia side
wraps it, it does not reimplement it.

**Fred's metabarcoding pipeline lineage (shell/Python + swarm/vsearch).**
Mahé's swarm pipeline: cutadapt primer trimming, vsearch pair merging,
dereplication, `swarm -d 1` single-linkage clustering, `--uchime_denovo`
chimera culling, vsearch global-alignment taxonomy, then table merge and
taxonomic filtering. Again: `src/pipeline/swarm.jl` and the vsearch stage
are orchestrators around the same tools.

**Acknowledgements are load-bearing here.** The DADA2 tutorial is CC BY 4.0;
Fred's pipeline is credited in `NOTICE`. Layer 1 is *upstream science* — the
fork's own standing rule is that it tracks application changes and does not
fork the science.

What layer 1 lacks: shared provenance (tables stitched by hand), single-lane
operation (you chose ASVs *or* OTUs per script), and any contract about what
the numbers claimed.

## Layer 2 — JoshuaJewell's MetaManifold augmentation

The origin design (Joshua Benjamin Jewell, Department of Parasitology,
Charles University) makes three moves:

1. **Orchestration.** A Julia engine runs *both* lanes per run — ASV and OTU
   from one launch — with cutadapt in front, cd-hit-est optional for
   multiplex inflation, `merge_taxa` behind. Each stage is a typed result
   (`TrimmedReads` → `ASVResult`/`OTUResult` → `TaxonomyHits` →
   `MergedTables`) with mtime/hash freshness so re-runs are minimal.
2. **State.** Per-run DuckDB (`merged/results.duckdb`) as the queryable
   results store; `projects/{study}/{run}/` as the complete output tree;
   `run_config.yml` as merged-configuration provenance.
3. **A workbench.** Oxygen.jl REST + SSE and a React SPA: the config cascade
   editable at every level (instance → study → group → run), run and job
   control with live progress, embedded QC (FastQC/MultiQC + DADA2
   diagnostics), the results explorer (filters, presets, OTU drill-down,
   xlsx), functional annotation (dual-classifier consensus, contamination
   curation, FuncDB ledger), composition views (biological categories).

The pipeline diagram in the README's layer-2 section *is* this design. It is
still the shipping architecture.

What layer 2 left open: statistics that were wired to placeholders; numbers
whose precision claims were unchecked; a large frontend with no type estate;
and no engineering harness to keep either honest.

## Layer 3 — the hyperpolymath steps (2026-09)

A discipline of honesty and typing wrapped around layer 2, delivered as a
patch series (Milestone 2 → AnalysisConfig v1 → the statistics layer):

```
  discipline              what it forbids                          where
  ─────────────────────   ─────────────────────────────────────    ─────────────────────────
  typed estate            `any`, `@ts-ignore`, ambient sprawl      frontend/src/types, tsconfig
  engineering gates       untestable claims, unpinned tools        test/, bench/, ci, Justfile
  numeric policy          precision-laundering (float as exact)    numeric_policy.jl
  exact summaries         inference dressed as description         exact_summaries.jl
  real estimation         placeholder-as-result (hash-based p)     estimation.jl + guard test
  offsets                 silent substitution (TSS→relative …)     scaling.jl
  epistemic receipts      bare numbers without warrants            epistemic.jl
  refusal-first           guessing when a method cannot run        everywhere above
```

The progression is not "rewrite in another stack" — each step *tightens a
claim* the earlier layers were making loosely. Layer 2 said "here is a
p-value"; layer 3 asks "what type of claim is that p-value, and what
warrants it?" — and where the answer is "none", the software now returns a
named refusal instead.

**In place vs coming (layer 3):** the table above is shipped (guard tests
included). The forward path — exact tests, the compositional/occupancy/
ordination suite, PhILR/SBP, advanced zeros, CladeCumulus, Evidence Mode,
Zenodo, and the formally blocked symbolic engine — is
[Advanced Functionality](Deep-Dives--Advanced-Functionality) and the
[Status and Roadmap](Status-and-Roadmap) board.

## The nested picture

```
┌─ Layer 3 · verified statistics, typed estate, engineering gates ─────────────┐
│ ┌─ Layer 2 · Julia orchestrator + WebUI: both lanes, DuckDB, config cascade ┐│
│ │ ┌─ Layer 1 · base design: raw DADA2 (R) + swarm/vsearch (shell) pipelines ┐│
│ │ │      raw FASTQs → denoise or cluster → taxonomy → count tables          ││
│ │ └─────────────────────────────────────────────────────────────────────────┘│
│ └───────────────────────────────────────────────────────────────────────────┘│
└───────────────────────────────────────────────────────────────────────────────┘
```

Each layer's code is still legible in the tree — that is what "stacked
honestly" means: you can read layer 1's R, layer 2's orchestrator, and
layer 3's contracts without a archaeology dig.
