<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000014
parent: 0198ba50-0000-7000-8000-000000000010
position: 40
kind: page
tags:
  - users
  - guide
  - ui
archived: false
-->

# Exploring results

**Status: IN PLACE** — these views are the daily working surface of the
application. (Screenshots are **COMING** to this page; the origin README
referenced UI captures that were never committed to the repository. The
descriptions below are complete without them.)

A run's page is the working surface: run-level configuration, per-stage
launch controls (full pipeline or any single stage, DADA2 substages
included), and per-stage status. Long jobs report progress over a live
server-sent event stream; the jobs panel watches or cancels them.

## QC

Raw-read QC (FastQC aggregated by MultiQC) and the DADA2 quality,
denoising, merging and taxonomy diagnostics are embedded in the UI, each
with its relevant configuration alongside and a re-run control. This is the
first place to look when retention numbers surprise you.

## Results explorer

The run's merged taxonomy-and-count table, and derived tables, browsed
interactively:

- per-column filters — text search, numeric range, include/exclude lists —
  and a global text filter;
- sorting, configurable pagination, column visibility with taxonomy-source
  presets (VSEARCH-only, DADA2-only, all) and a switch for the per-sample
  count columns;
- sequences carry BLAST links; OTU rows expand to their constituent
  sequences;
- filters save as named presets (`config/presets/`) and reapply; tables
  export to Excel (`.xlsx`) or save back into the run.

**Lab professionals:** column presets + saved filters give you standard
views per assay — build the view once, share the preset. The OTU
drill-down is how you audit what a cluster contains before reporting it.

## Annotation

The annotation view applies a functional database (`funcdb`) to the merged
table, independently per classifier (VSEARCH and DADA2). For each sequence:
functional metadata (function, associated organism and material,
environment, pathogen status, notes) down to a configurable maximum rank; a
**consensus rank** (finest rank where the classifiers agree); and a composite
confidence score (DADA2 bootstrap at that rank × vsearch percent identity) —
which is deliberately labelled curiosity-grade, not a calibrated probability.

Curation, in place:

- **Contamination tagging** — yes / no / unassigned per taxon at a rank, with
  a live summary of affected reads.
- **Manual BLAST assignment** — override one sequence inline.
- **FuncDB ledger** — new functional entries, prefilled from the selected row,
  append to a ledger available to later annotation runs. Your edits survive
  re-annotation.

**Lab professionals:** contamination tagging is your decontamination audit
trail — flags apply to every row sharing the rank and taxon, and the
affected-read summary is the number to put in the QC record.

## Composition

Per-sample or pooled stacked bars of ASV/OTU counts by biological category
(protozoa, helminths, fungi, host, plants, invertebrates — the `default`
set in `config/composition.yml`; sets and their named filters are editable
from the Compositions page under SYSTEM). A category summary precedes the
chart; a quality filter caps unresolved taxonomic placeholders.

## Cross-run comparison

Across runs within a study: alpha-diversity comparison boxplots with
significance testing, taxon overlap as proportional Euler or UpSet plots,
NMDS ordination and PERMANOVA, and pipeline-stage read summaries — see
[Analysis and Statistics Today](Users--Analysis-and-Statistics-Today) for
what the statistics behind those charts claim.

## Coming to this area

- **COMING:** CladeCumulus (#6) — a cumulative cladistic explorer with
  epistemic colour coding (scaffolded in `src/analysis/clade_cumulus.jl`);
  Full Evidence Mode (#7) — epistemic editor and fibre visualiser.
- **COMING:** Euler/UpSet visualisations and chart-editor parity in the
  Stipple UI migration (`docs/migration/STATUS.md` names these as the major
  parity risks).
