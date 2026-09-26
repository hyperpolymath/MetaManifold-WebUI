<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Autolink references — complete specification for repository settings

**Status: specified 2026-09-26; pending application in Settings → Autolink references.**
The Arena GitHub App token carries contents/issues permissions but not
Administration, which the autolinks REST API (`GET/POST /repos/{owner}/{repo}/autolinks`)
requires. This document is therefore the authoritative, paste-ready elaboration of
the repository's autolink reference set. Applying it needs one human pass in the
GitHub UI (or a token with `administration:write`, after which `gh api` can apply
the table verbatim).

## What an autolink reference does

GitHub's **Autolink references** (Settings → Autolink references) let a bare token
such as `SWARM-413` render as a link everywhere the tracker syntax `#413` cannot:
commit messages, README/EXPLAINME/wiki prose, issue and PR bodies across forks,
release notes, and any cross-repository mention. Each entry pairs an alphanumeric
**prefix** with a **URL template** containing `<num>`; GitHub appends the digits
that follow the prefix to the template.

Native `#123` references (this repository's own issues and pull requests) already
autolink and are deliberately **not** duplicated here.

## Design rules used below

1. **Every prefix names the tracker it resolves to** — no generic `GH-` or `REF-`
   tokens. A reader of `VSEARCH-2203` knows which project's issue to open.
2. **One tracker per prefix, issues-number space** — GitHub issue and PR numbers
   share a number space, so `/issues/<num>` redirects to the pull request when the
   number is a PR. One entry covers both.
3. **Coverage follows real references made by this repository** (from `README`,
   `docs/`, `NOTICE`, `CONTRIBUTING`, commit history): the upstream fork, the
   hyperpolymath estate, the seven orchestrated bioinformatics tools, the
   runtime/toolchain dependencies, and the planned publication registry.
4. **Uppercase prefixes** by convention, matching the `JIRA-123` idiom GitHub
   documents.

## The reference set (paste-ready)

Apply in Settings → Autolink references, in this order. The UI takes two fields
per row: **Link prefix** and **URL**.

### Tier 1 — lineage and estate (apply first)

| Link prefix | URL | Elaboration |
|---|---|---|
| `JJ-` | `https://github.com/JoshuaJewell/MetaManifold-WebUI/issues/<num>` | Upstream (origin) repository — issues *and* pull requests. The owner-review correspondence ("PR #7, #8, #10, #11") means upstream PR numbers in particular. |
| `MMW-` | `https://github.com/hyperpolymath/MetaManifold-WebUI/issues/<num>` | This fork, explicit form. Useful in the wiki and in cross-repo contexts (standards, upstream, docs mirrors) where a bare `#n` resolves against the wrong tracker. |
| `STD-` | `https://github.com/hyperpolymath/standards/issues/<num>` | Organization-wide standards and specifications (README/EXPLAINME standard, A2ML, RSR canon, licence policy). Referenced by `docs/compliance/*`. |
| `RSR-` | `https://github.com/hyperpolymath/rsr-template-repo/issues/<num>` | The Rhodium Standard Repository template this repo is aligned against (`docs/compliance/rsr-alignment.md`). |
| `STAT-` | `https://github.com/hyperpolymath/statistikles/issues/<num>` | The estate's neurosymbolic statistics assistant — the intended consumer-side companion of this repo's method catalogue. |
| `LITHO-` | `https://github.com/hyperpolymath/Lithoglyph/issues/<num>` | LithoglyphDB — named in `ROADMAP.md` as owner of storage/journal/provenance internals. |
| `GNPL-` | `https://github.com/hyperpolymath/GNPL/issues/<num>` | GNPL (Lithoglyph's narration/projection language) — named in `ROADMAP.md` as provenance-adjacent owner. |
| `BERRY-` | `https://github.com/metadatastician/berrywiki/issues/<num>` | BerryWiki — the GitHub-wiki page format this repository's wiki is authored in (see `docs/wikis/`). |

### Tier 2 — orchestrated and acknowledged upstream tools

These are the tools the pipeline shells out to (and the two lineage pipelines
credited in `NOTICE`/Acknowledgements). Bug triage in this repo routinely lands
in an upstream tracker; autolinks make that one gesture.

| Link prefix | URL | Elaboration |
|---|---|---|
| `DADA2-` | `https://github.com/benjjneb/dada2/issues/<num>` | ASV inference engine (R/Bioconductor); the tutorial lineage of the base design. |
| `SWARM-` | `https://github.com/frederic-mahe/swarm/issues/<num>` | OTU clustering; also the home of Fred's metabarcoding pipeline (layer-1 lineage). |
| `VSEARCH-` | `https://github.com/torognes/vsearch/issues/<num>` | Pair merging, chimera checks, taxonomy-by-alignment for both lanes. |
| `CUTADAPT-` | `https://github.com/marcelm/cutadapt/issues/<num>` | Primer/adapter trimming, stage one of every run. |
| `FASTQC-` | `https://github.com/s-andrews/FastQC/issues/<num>` | Raw-read QC (pre-filter lane). |
| `MULTIQC-` | `https://github.com/MultiQC/MultiQC/issues/<num>` | QC aggregation report embedded in the run view. |
| `CDHIT-` | `https://github.com/weizhongli/cdhit/issues/<num>` | cd-hit-est optional ASV clustering (multiplex inflation control). |
| `MOTHUR-` | `https://github.com/mothur/mothur/issues/<num>` | Source of the bundled MiSeq SOP sample data (`data/MiSeq_SOP/`). |

### Tier 3 — runtime, frontend and toolchain dependencies

| Link prefix | URL | Elaboration |
|---|---|---|
| `JULIA-` | `https://github.com/JuliaLang/julia/issues/<num>` | Orchestrator language (pinned 1.12.5 via `mise.toml`). |
| `RENV-` | `https://github.com/rstudio/renv/issues/<num>` | R environment pinning (`renv.lock`); the reproducibility story for the R half. |
| `BUN-` | `https://github.com/oven-sh/bun/issues/<num>` | Frontend toolchain (pinned in `.bun-version`). |
| `VITE-` | `https://github.com/vitejs/vite/issues/<num>` | Frontend build. |
| `PLOTLY-` | `https://github.com/plotly/plotly.js/issues/<num>` | All analysis charts are Plotly JSON; `plotly.js-dist-min` has no published types (see `docs/types/architecture.md`). |
| `REACT-` | `https://github.com/facebook/react/issues/<num>` | SPA framework (18.x). |
| `DUCKDB-` | `https://github.com/duckdb/duckdb/issues/<num>` | Per-run results store. |
| `STIPPLE-` | `https://github.com/GenieFramework/Stipple.jl/issues/<num>` | Target framework of the Julia-authored UI migration (`docs/migration/STATUS.md`). |
| `GENIE-` | `https://github.com/GenieFramework/Genie.jl/issues/<num>` | Stipple's HTTP substrate; the migration UI's server lane. |

### Tier 4 — publication and registries

| Link prefix | URL | Elaboration |
|---|---|---|
| `ZENODO-` | `https://zenodo.org/records/<num>` | Zenodo record IDs are flat integers, so `ZENODO-14012345` resolves to the record (and its DOI landing page). Prepared for the DOI-minting work of issue #8. |

## Reserved and deliberately omitted

| Candidate | Why it is out (for now) |
|---|---|
| `CVE-…` / `OSV-…` | CVE ids are two-part (`CVE-2026-12345`); GitHub autolinks match a single numeric run after the prefix. A `CVE-` prefix would mis-render `CVE-2026-12345` as `CVE-2026` + junk. OSV ids are alphanumeric. Link security advisories explicitly instead. |
| `ADR-…` | The standards repo's decision records have slug-bearing filenames (`ADR-003-workflow-pin-staleness-window.adoc`); a `<num>`-only template cannot reconstruct the slug. Reference them as `standards:docs/decisions/…` paths. |
| `PR2-…` | The PR2 reference database versions are release tags with dots, not integers. Cite the release URL (see `config/databases.yml`). |
| `JIRA-`-style generic tokens | Rejected by design rule 1. |

## Verification checklist (after application)

- [ ] `JJ-1` resolves to `https://github.com/JoshuaJewell/MetaManifold-WebUI/issues/1`.
- [ ] `MMW-16` resolves to this fork's issue #16 (TSS/CSS/RSS offsets).
- [ ] `SWARM-413` resolves to the swarm tracker.
- [ ] `ZENODO-3265123` resolves to `https://zenodo.org/records/3265123`.
- [ ] A commit message containing `DADA2-1948` renders linked in the commit list.
- [ ] The wiki page `Developers--REST-API` (in `docs/wikis/`) renders its `JULIA-…`/`DUCKDB-…` references linked.

## Maintenance

Adding a tracker = one table row here + one Settings entry. Keep the tiers: they
are the review order. If Administration access is later granted to the estate's
automation, this file is the source of truth an `apply-autolinks` script should
read — the table above is deliberately machine-parseable (three columns, no
spans).
