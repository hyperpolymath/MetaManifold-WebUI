<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000001
parent: null
position: 0
kind: page
tags:
  - overview
archived: false
-->

# MetaManifold

Amplicon metabarcoding from raw paired-end Illumina reads to filtered,
taxonomy-annotated ASV/OTU tables — one Julia engine, one browser workbench,
and statistics that say what they cannot claim.

This wiki is the long-form documentation for
[MetaManifold-WebUI](https://github.com/hyperpolymath/MetaManifold-WebUI)
(origin design by Joshua Jewell; maintained and extended on the
hyperpolymath fork). It is written in the
[berrywiki](https://github.com/metadatastician/berrywiki) page format: plain
Markdown with hidden tree metadata, so it survives with nothing but `git` and
a browser.

## Three doors — pick the one that is yours

| If you are… | Start here | What you get |
|---|---|---|
| **A user** — running analyses (academic or lab professional) | [Users](Users) | Install, your first study, the configuration reference, the analysis surface — with separate tracks for [academics](Users--For-Academics) (reproducibility, citing, exactness) and [lab professionals](Users--For-Lab-Professionals) (routine throughput, QC, curation). |
| **A platform maintainer** — running the platform or the repository | [Maintainers](Maintainers) | [Operator track](Maintainers--Operator-Track) (deployment, databases, toolchains, upgrades) and [steward track](Maintainers--Steward-Track) (CI gates, reviews, upstream relations, estate compliance). |
| **A developer** — changing the code | [Developers](Developers) | Architecture tour, the type system, statistics internals, extension points, tests and the REST surface. |

Beyond the three doors, two cross-cutting sections:

- **[Deep Dives](Deep-Dives)** — the mathematics and engineering receipts that
  the README and [EXPLAINME](https://github.com/hyperpolymath/MetaManifold-WebUI/blob/main/EXPLAINME.adoc)
  deliberately keep short: the three-layer design progression, type theory
  meets statistics, exact arithmetic, maximum likelihood and refusals,
  compositional statistics and offsets, epistemic status, and the advanced
  functionality that is coming.
- **[Status and Roadmap](Status-and-Roadmap)** — the single board that marks,
  for every area, what is **here now** and what is **coming**.

## Status legend — used on every page

Every section that could be mistaken for a promise carries one of four
markers. They are used strictly:

- **IN PLACE** — implemented and verifiable in the tree today.
- **PARTIAL** — usable now, with the limits named on the spot.
- **COMING** — specified and tracked (issue numbers given), *not*
  implemented. Never listed as a feature of the present.
- **BLOCKED** — deliberately halted pending a named condition.

If a claim has no marker, it is a description of what the software does today.
When in doubt, the [Status and Roadmap](Status-and-Roadmap) board is
authoritative, and the repository tree is the final arbiter.

## Orientation in ninety seconds

MetaManifold is three designs stacked on each other (full story in
[Deep Dives — Design Progression](Deep-Dives--Design-Progression)):

1. **The base design (R/Python):** raw DADA2 (R) for ASVs and the
   swarm/vsearch shell tradition for OTUs — the science, used as published.
2. **The MetaManifold augmentation (JoshuaJewell):** a Julia orchestrator that
   runs both lanes per run and a web workbench (config cascade, QC, results,
   annotation, composition) over a per-run DuckDB store.
3. **The hyperpolymath steps (this fork):** honest statistics (real
   maximum-likelihood fits or explicit refusals; exact counts and rationals;
   exact TSS/CSS/RSS offsets), a typed frontend estate, and CI/tests/
   benchmarks that keep every claim checkable.

## Conventions

- **Academics vs lab professionals.** Where the two audiences need different
  guidance, pages carry **Academics:** and **Lab professionals:** callouts;
  where the guidance is shared, nothing is split.
- **Issue references** use `#n` for
  [this repository's tracker](https://github.com/hyperpolymath/MetaManifold-WebUI/issues).
  Upstream references are named in full (e.g. JoshuaJewell/MetaManifold-WebUI).
- **Source of truth.** These pages are sourced from `docs/wikis/` in the
  repository and published here; see `docs/wikis/README.md` for the sync
  convention.
