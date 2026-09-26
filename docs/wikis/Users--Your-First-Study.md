<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000012
parent: 0198ba50-0000-7000-8000-000000000010
position: 20
kind: page
tags:
  - users
  - guide
  - pipeline
archived: false
-->

# Your first study

**Status: IN PLACE** — the whole path from FASTQs to merged tables is the
oldest part of the software and the most exercised.

## 1. Lay out your data

Paired-end Illumina files, standard naming, under `data/`:

```
data/MyProject/run_A/
    SampleName_S1_L001_R1_001.fastq.gz
    SampleName_S1_L001_R2_001.fastq.gz
    SampleName_S2_L001_R1_001.fastq.gz
    SampleName_S2_L001_R2_001.fastq.gz
    ...
```

- Any directory containing `.fastq.gz` files is a **run** (a leaf).
- Directories between the study and the run are **groups** — use them for
  multi-run studies (cohorts, sequencing batches, sites).
- A matching project directory is created under `projects/` for outputs.

Not sure yet? The repository ships `data/MiSeq_SOP/` (the mothur MiSeq SOP
dataset, two runs) — run it first to see the whole path on known data.

## 2. Create the study and launch

Open `http://localhost:8080`:

1. Create the study `MyProject` (the UI shows the runs it found on disk).
2. Optionally set study-level configuration (e.g. which primer pairs cutadapt
   should use) — leave everything else at defaults for the first run. The
   full key-by-key reference is
   [Configuration Reference](Users--Configuration-Reference).
3. Launch the pipeline. The jobs panel and the live event stream show
   progress; any individual stage (including DADA2 substages) can be
   launched alone.

## 3. What happens, in order

```
FASTQs → cutadapt (primers) → [QC: FastQC/MultiQC]
       → DADA2 lane: filter/trim, error learning, denoise, merge,
         length filter, chimera removal, taxonomy, (cd-hit-est), vsearch
       → SWARM lane: merge pairs, dereplicate, cluster, chimera check,
         vsearch taxonomy
       → merge_taxa: join tables, apply named taxonomic filters
       → DuckDB results store (per run)
```

Both lanes run side by side: you get ASVs (DADA2) **and** OTUs (SWARM) from
the same run. Stages skip themselves when their outputs are already current;
changing a setting flags exactly the stages that would regenerate, and names
the keys you changed.

**Lab professionals:** the per-stage read accounting (`pipeline_stats.csv`
and the stage summary view) is your QC gate — the retention curve across
stages is where library problems show up first. See
[For Lab Professionals](Users--For-Lab-Professionals).

**Academics:** the merged configuration used for the run is written to
`projects/{study}/{run}/run_config.yml` — that file *is* your provenance
record for methods sections. See [For Academics](Users--For-Academics).

## 4. Collect your outputs

Everything for a run lives under `projects/{study}/{run}/`:

| Path | Contents |
|---|---|
| `cutadapt/` | trimmed FASTQ pairs + logs |
| `QC/` | per-file FastQC reports, `multiqc_report.html`, logs |
| `dada2/Tables/` | `seqtab_nochim.csv` (ASV counts), `asvs.fasta`/`asvs.csv`, `taxonomy.csv`, `taxonomy_bootstraps.csv`, `taxonomy_combined.csv`, `tax_counts.csv`, `asv_counts.csv`, `pipeline_stats.csv` |
| `dada2/Figures/`, `Checkpoints/`, `Logs/` | quality/error PDFs, RData stage checkpoints, per-stage R logs |
| `cdhit/` | clustered ASVs + cluster membership (when enabled) |
| `swarm/` | `otus.fasta`, `otus.count_table.csv`, logs |
| `vsearch/` | `taxonomy.tsv` top-hit assignments |
| `merged/` | `merged.csv` (all taxa), one filtered CSV per configured filter, `results.duckdb` |

CSVs travel into R, Python, or spreadsheets directly; the DuckDB file is what
the workbench queries.

## What is coming on this path

- **COMING:** nothing about the path itself — it is stable. What will change
  is delivery: standalone archives so "install" becomes "unzip and launch"
  (`docs/migration/STATUS.md`), and Zenodo DOI minting (#8) so a completed
  study can be published with a citable record straight from the workbench.
