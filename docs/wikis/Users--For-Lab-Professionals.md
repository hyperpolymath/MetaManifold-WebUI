<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000017
parent: 0198ba50-0000-7000-8000-000000000010
position: 70
kind: page
tags:
  - users
  - lab
  - operations
archived: false
-->

# For lab professionals

**Status: IN PLACE** as a routine production tool (single-user, local
machine). This page is for people running samples as a service: validated
routine paths, QC gates before results leave the lab, and the curation
records auditors ask for.

## The routine loop

1. **Receive** FASTQs → drop them into `data/{Study}/{run}/` with Illumina
   naming. Group runs by batch/site/cohort in intermediate directories.
2. **Configure once per assay.** Set primer pairs and database at study
   level (or in `config/pipeline.yml` for the whole machine); everything else
   inherits. The [Configuration Reference](Users--Configuration-Reference)
   has the keys; the SYSTEM pages (Primers, Databases, Compositions) edit
   them with validation.
3. **Launch and watch the jobs panel.** Per-stage status and live progress;
   stages can be re-run individually after a fix.
4. **Gate on QC** (below), curate, export.

## QC gates before results leave the lab

| Gate | Where | What "pass" looks like |
|---|---|---|
| Raw-read quality | QC view (FastQC + MultiQC) | per-base quality sane; adapter content low after trimming |
| Trimming retention | `pipeline_stats.csv`, stage summary | cutadapt retention matches assay expectations (primer mismatch shows here first) |
| Denoising/merging retention | stage summary | no cliff between denoise → merge for the amplicon length |
| Chimera rate | DADA2 diagnostics | consistent with batch history, not spiking |
| Taxonomy hit rate | taxonomy stage outputs | assignable fraction stable vs previous runs on the same assay |
| Classification agreement | annotation view consensus rank | disagreement between DADA2 and vsearch labels investigated before reporting |
| Contamination | annotation view, contamination tagging | flagged taxa summarised per rank; affected-read count in the QC record |

The per-stage read accounting is the retention curve of your assay; keep a
running record per batch and the outliers name themselves.

## Curation records that survive

- **Contamination flags** (yes / no / unassigned) attach to rank+taxon and
  apply to every matching row, with a live affected-read summary — export the
  summary into the batch QC record.
- **Manual BLAST overrides** are per-sequence and explicit.
- **FuncDB ledger** entries are append-only and persist across re-annotation;
  user edits survive regeneration. That persistence is the audit trail:
  what was decided, when, by whom, survives the next analyst's re-run.

## Primers and databases — the lab-owned layer

Assays live in `primers.yml` (sequences validated against the IUPAC base set
as you type; whole-document validation before write). Reference databases
live in `databases.yml` (URIs + optional local paths; download on first use;
SSH `remote_path` when the taxonomy host already has the file).

- Renaming/removing a primer pair or a database that studies still reference
  is **permitted but reported** — the save names every affected study,
  including those inheriting a database without naming it. Read the report;
  it is the difference between a rename and an outage.
- **Keep the two formats of one database on the same reference release.**
  The dual-classifier consensus is string equality of labels; mixed releases
  turn agreements into disagreements. The editor warns on version-token
  mismatch (filename heuristic only).

## Throughput notes

- Multi-run studies (groups) compare across runs: alpha-diversity boxplots
  with significance, taxon overlap (Euler/UpSet), NMDS, PERMANOVA.
- Saved table-filter presets (`config/presets/`) standardise the view per
  assay; `.xlsx` export feeds LIMS-side reporting.
- For heavy runs, the memory-intensive `assignTaxonomy()` can be offloaded to
  a server via SSH (`dada2.remote:`). **You** are responsible for
  authorisation to that host — the disclaimer in
  `config/defaults/pipeline.yml` is deliberate.

## Deployment posture — read before putting this on a server

**IN PLACE:** local single-user operation. The current server is **not**
multiuser-ready and must not be exposed as if it were. On a shared lab
machine, bind to localhost (default) and treat `data/` + `projects/` as the
backup unit. Operator-grade deployment guidance:
[Operator Track](Maintainers--Operator-Track).

**COMING:** authenticated remote/multiuser deployment, standalone offline
archives for managed installs, and a coordinated signed updater
(`docs/migration/STATUS.md`). None exist today; plan for the source install.

## Statistics your service reports vs research claims

Routine service work mostly needs the descriptive layer (exact counts and
proportions), composition views and QC — all **IN PLACE** and honest under
review. When a client asks for differential-abundance claims, check
[Analysis and Statistics Today](Users--Analysis-and-Statistics-Today): the
fits exist, the review caveat applies, and the exact small-n layer (#3) is
still **COMING**. "We cannot make that claim validly yet" is a defensible
service answer; a fabricated p-value is not.
