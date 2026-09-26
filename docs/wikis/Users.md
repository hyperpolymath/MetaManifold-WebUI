<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000010
parent: null
position: 10
kind: page
tags:
  - users
  - overview
archived: false
-->

# Users

This section is for people who **run analyses** with MetaManifold: from raw
paired-end FASTQs to filtered, taxonomy-annotated tables and interactive
figures. You do not need to be a programmer. You do need sequencing data.

Two audiences share this section, and they want different things from the
same software:

- **Academics** — you are answering a research question and will publish.
  You care about reproducibility, method disclosure, exactness of what is
  claimed, and citing the software. Your home is
  [For Academics](Users--For-Academics), but read the install and
  first-study pages first like everyone else.
- **Lab professionals** — you are running samples as a service: routine
  panels, QC gates before results leave the lab, primer and database
  management, contamination curation. Your home is
  [For Lab Professionals](Users--For-Lab-Professionals).

Where guidance differs, pages carry **Academics:** and **Lab professionals:**
callouts. Where it does not, they just tell you how the thing works.

## Learning path

1. [Install and First Run](Users--Install-and-First-Run) — prerequisites,
   `install.sh`, starting the server. (~20 minutes including downloads.)
2. [Your First Study](Users--Your-First-Study) — put FASTQs where they
   belong, launch a run, find your tables. (~15 minutes plus compute time.)
3. [Exploring Results](Users--Exploring-Results) — QC, the results explorer,
   annotation and composition views.
4. [Analysis and Statistics Today](Users--Analysis-and-Statistics-Today) —
   what each analysis computes, and what it refuses to compute.
5. Your track: [For Academics](Users--For-Academics) or
   [For Lab Professionals](Users--For-Lab-Professionals).
6. [Configuration Reference](Users--Configuration-Reference) — the full YAML
   reference, when you need the exact key.
7. [Troubleshooting](Users--Troubleshooting) — when something refuses.

## What is here now vs what is coming

**IN PLACE today:** the full pipeline (both ASV and OTU lanes), the browser
workbench (config editors, runs and jobs, QC, results explorer, annotation
and curation, composition), and the analysis surface: alpha diversity with
honest significance statuses, composition bars, organism categories, taxon
overlap, NMDS and PERMANOVA, exact descriptive summaries, ML fits
(NB-GLM / CLR-ILR linear models / logistic) with refusal states, and exact
TSS/CSS/RSS offsets.

**COMING (tracked, not yet available to you):** exact statistical tests (#3),
compositional differential-abundance methods (#5), occupancy models (#17),
constrained ordinations (#18→#19), PhILR/SBP balances (#20), advanced zero
handling (#21), CladeCumulus (#6), Full Evidence Mode (#7), Zenodo DOI
minting (#8), standalone offline installers and the coordinated updater
(`docs/migration/STATUS.md`). The full board:
[Status and Roadmap](Status-and-Roadmap).

**A promise the software keeps:** when it cannot compute something validly,
it says so and returns an unsuccessful state — never a plausible-looking
number. Refusals are a feature. See
[Analysis and Statistics Today](Users--Analysis-and-Statistics-Today).
