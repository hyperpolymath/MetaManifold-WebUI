<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000013
parent: 0198ba50-0000-7000-8000-000000000010
position: 30
kind: page
tags:
  - users
  - reference
  - configuration
archived: false
-->

# Configuration reference

**Status: IN PLACE** — this is the complete key-by-key reference for
pipeline configuration. (This page replaces the configuration chapters the
origin README used to carry, so the README can stay readable.)

## The cascade

Settings cascade: each level overrides the one above it; any key you omit is
inherited from the nearest ancestor. The fully merged result is written to
`projects/{name}/{run}/run_config.yml` at runtime — **that file is the single
place to see exactly what a run used.**

| File | Purpose |
|---|---|
| `config/defaults/` | canonical defaults for every setting; do not edit |
| `config/composition.yml` | composition library: named taxonomic filters + category sets |
| `config/presets/` | saved table-view filter presets (written from the Tables view) |
| `config/databases.yml` | database URIs and optional local paths (Databases page under SYSTEM) |
| `config/primers.yml` | primer sequences and pair definitions (Primers page under SYSTEM) |
| `config/tools.yml` | tool binary paths (cutadapt, FastQC, MultiQC, vsearch, cd-hit-est) |
| `config/pipeline.yml` | machine-level overrides (lowest user-editable precedence) |
| `data/{name}/pipeline.yml` | study-level overrides |
| `data/{name}/{group}/pipeline.yml` | group-level overrides (intermediate directories) |
| `data/{name}/{run}/pipeline.yml` | run-level overrides (highest precedence) |
| `projects/{name}/{run}/run_config.yml` | generated merged config (provenance); do not edit |

Each `pipeline.yml` stub carries a comment block explaining its level's role.
Write only the keys you want to change.

## Databases (`config/databases.yml`)

The one place database URIs are managed (also editable from the Databases
page):

```yaml
databases:
  dir: "./databases"
  pr2:
    dada2:
      uri: "https://..."       # DADA2-format FASTA (downloaded on first use)
      local: ~                 # set to a local path to skip download
    vsearch:
      uri: "https://..."       # vsearch-format FASTA
      local: ~
```

Per database: the `dada2` and `vsearch` source URIs, `local:` override,
`remote_path` (dada2 only, file already on the remote taxonomy host), the
ordered taxonomy `levels`, the `vsearch_format` parser selector (`pr2` =
pipe-separated; anything else parses generically), and `corrections`.
Adding/removing whole databases is supported. Removing or renaming one (or
changing `levels`) is allowed but the save **reports which studies it
affects** — including studies that inherit the database without naming it.

> Both formats of one database must come from the same reference release: the
> dual-classifier consensus compares labels by string equality, so mixed
> releases score real agreements as disagreements. The editor warns on
> version-token mismatches (a filename heuristic — cannot warn when URIs
> carry no version).

## Primers (`config/primers.yml`)

```yaml
Forward:
  PrimerF: "CCAGCASCYGCGGTAATTCC"

Reverse:
  Primer1R: "ACTTTCGTTCTTGATYRA"
  Primer2R: "DCTKTCGTYCTTGATYRA"

Pairs:
  - PrimerPair1: [PrimerF, Primer1R]
  - PrimerPair2: [PrimerF, Primer2R]
```

Shared primers are deduplicated in the cutadapt invocation (cutadapt
complains about duplicates — if you need duplicates, define the same sequence
under a second name). The Primers page validates each sequence against the
IUPAC base set as you type and validates the whole document before writing:
a pair naming a missing primer is rejected and the file is left untouched.
Removing/renaming a pair that studies still reference is permitted but the
save reports every dangling reference. Renaming a primer carries its pairs.

## cutadapt

```yaml
cutadapt:
  primer_pairs: [PrimerPair1, PrimerPair2]  # names from primers.yml
  min_length: 200           # -m: discard shorter reads after trimming
  discard_untrimmed: true   # --discard-untrimmed
  cores: 0                  # -j: 0 = auto
  quality_cutoff: ~         # -q 3' trim; null disables
  error_rate: ~             # -e adapter mismatch rate; null = cutadapt default
  overlap: ~                # -O min adapter overlap; null = default
  optional_args: ""         # passed verbatim
```

## DADA2

```yaml
dada2:
  file_patterns:
    mode: "paired"               # paired | forward | reverse

  filter_trim:                   # DADA2 filterAndTrim()
    trunc_q: 2
    trunc_len: [220, 220]        # [forward, reverse]
    max_ee: [3, 3]
    min_len: 175
    max_n: 0
    match_ids: true
    rm_phix: true

  dada:                          # learnErrors() and dada()
    seed: 123
    nbases: 200000000
    max_consist: 15
    pool_method: "pseudo"        # none | pseudo | true

  merge:                         # mergePairs(), paired mode only
    min_overlap: 20
    max_mismatch: 0
    trim_overhang: true

  asv:                           # length filtering + chimera removal
    band_size_min: 200           # null skips length filtering
    band_size_max: 430
    denovo_method: "consensus"   # consensus | pooled | per-sample

  taxonomy:                      # assignTaxonomy()
    database: pr2                # key into databases.yml
    multithread: 4
    min_boot: 0                  # 0-100 bootstrap floor
    remote:                      # optional SSH offload of assignTaxonomy()
      host: ~                    # user@hostname — authorisation is YOURS to ensure
      identity_file: ~
      rscript: "Rscript"
      staging_dir: "/absolute/path/on/server"

  output:
    seq_table_prefix: "seqtab_nochim"
    fasta_prefix: "asvs"
    taxa_prefix: "taxonomy"
```

Rank names come from `databases.yml` (`levels:`), not from here.

## vsearch, cd-hit-est, swarm

```yaml
vsearch:
  identity: 0.75        # --id
  query_cov: 0.8        # --query_cov
  maxaccepts: ~
  maxrejects: ~
  strand: ~             # "plus" | "both"
  optional_args: ""

cdhit:                  # optional pre-clustering (multiplex inflation control)
  identity: 1           # -c
  threads: 0            # -T: 0 = all
  optional_args: ""

swarm:                  # the OTU lane
  differences: 1        # -d
  threads: 0
  chimera_check: true   # vsearch --uchime_denovo first
  min_abundance: 2      # --minsize
  fastq_minovlen: 20
  identity: 0.97        # mapping reads back to OTU seeds
  optional_args: ""
```

The `vsearch:` block configures taxonomy alignment for **both** lanes.

## merge_taxa and the filter library

```yaml
merge_taxa:
  filters:
    - "protist_filter.yml"   # -> merged/protist_filter.csv
```

`merged.csv` (unfiltered) is always written; each `filters` entry produces
one more CSV. Entries name filters from the `filters:` library of
`config/composition.yml`. A filter file:

```yaml
databases: [pr2]          # omit to apply regardless of active database
mappings:                 # optional column remapping before filtering
  - source_column: Division
    target_column: Supergroup
    values: { Rhizaria: Rhizaria, Alveolata: Alveolata }
filters:
  - column: Domain
    pattern: "Bacteria|Archaea"
    regex: true           # false (default) = substring
    action: exclude       # exclude (default) | keep
remove_empty: [Domain]    # drop rows blank/"NA" in these columns
```

The bundled library (PR2-shaped): `bacteria_archaea`, `environmental_protozoa`,
`fungi`, `helminths`, `parasitic_protozoa`, `plants_invertebrates`, `protist`,
`vertebrates`. Category sets (protozoa, helminths, fungi, host, …) reference
these filters by name and back the Composition view.

## analysis and annotation defaults

```yaml
analysis:
  exclude_categories:
    - {set: contamination, category: Contaminant, apply_to: [diversity, taxa, venn]}
  normalisation: none            # none | rarefaction | rss
  normalisation_depth: 0         # 0 = auto (min positive library size)
  alpha:
    show_points: true
    annotate_significance: false
    pairwise_brackets: false
    paired_samples: false
    significance_test: "kruskal_wallis"
  nmds:
    max_stress: 0.2              # warn above this stress

annotation:
  max_rank: "species"
```

Per-chart choices (rank, relative/absolute) are interactive UI state, not
config keys. **Note the `normalisation` key above is the chart-facing
normalisation** (none/rarefaction/relative sum scaling for display); the
statistical layer's TSS/CSS/RSS **offsets** are a separate, analysis-config
concern — see [Analysis and Statistics Today](Users--Analysis-and-Statistics-Today)
and [Deep Dives — Compositional Statistics](Deep-Dives--Compositional-Statistics).

## Coming in configuration

- **COMING:** analysis-config keys for the deferred methods (exact tests,
  multinomial/DM, occupancy, constrained ordination, PhILR/SBP, advanced zero
  handling) — the schemas will grow with issues #3 and #17–21. New keys will
  be refused until their method conditions are published, by the same rule
  that governed the current set.
