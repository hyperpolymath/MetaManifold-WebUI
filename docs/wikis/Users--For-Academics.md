<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000016
parent: 0198ba50-0000-7000-8000-000000000010
position: 60
kind: page
tags:
  - users
  - academics
  - reproducibility
archived: false
-->

# For academics

**Status: IN PLACE** as a working method, with the review caveat below. This
page is for readers who will publish, teach, or peer-review work produced
with MetaManifold: what to cite, what to disclose, and what the software will
not let you overclaim.

## The reproducibility record is already written for you

Every run materialises its complete configuration to
`projects/{study}/{run}/run_config.yml` — the merged truth of the cascade
(instance → study → group → run). For a methods section you need three
artefacts, and two are automatic:

1. **`run_config.yml`** — every parameter the pipeline used (attach as
   supplementary material).
2. **The toolchain pins** — `mise.toml` (Julia/Bun/Node/just exact
   versions), `renv.lock` (exact R package versions, restored byte-locked),
   `config/defaults/tool_versions.yml` (sha256-pinned binaries for cutadapt,
   FastQC, MultiQC, vsearch, cd-hit-est, swarm).
3. **Your taxonomy reference releases** — `config/databases.yml` records the
   URIs; record the release versions in your own lab book too (the software
   warns on mismatched releases between the DADA2 and vsearch formats of one
   database precisely because consensus comparison requires one release).

`docs/reproducibility.md` is the toolchain source of truth; honest gaps
(e.g. the Guix lane carrying functional equivalents rather than binary
identity) are documented there rather than smoothed over.

## Citing

- `CITATION.cff` at the repository root is the citable record (with ORCID
  and references) — most reference managers ingest it directly.
- **Origin design:** always credit Joshua Jewell's MetaManifold design; this
  fork extends it. The lineage is stated in `NOTICE` and drawn visually in
  [Deep Dives — Design Progression](Deep-Dives--Design-Progression).
- **The science you are running** is the upstream tools' as well: DADA2
  (Callahan et al.), swarm, vsearch, cutadapt — cite their papers; the
  software orchestrates, it does not replace their methods.
- **COMING:** Zenodo DOI minting (#8) so a completed study can be released
  with a citable, archived record from the workbench. Until then, archive the
  `projects/` artefacts yourself.

## Method disclosure — how to word it

MetaManifold's statistical layer distinguishes three kinds of number, and
your paper should too (the distinctions are load-bearing, see
[Deep Dives — Exact Arithmetic](Deep-Dives--Exact-Arithmetic)):

- **Exact** — integer counts and rational proportions (descriptive layer).
- **Approximate** — every fitted or floating quantity, including
  high-precision ones. Higher precision is not exactness.
- **Rounded** — a display rendering of an approximation.

For inference, report *which* model (`nb_glm`, `clr_lm`, `ilr_lm`,
`logistic`), *which* normalisation story (none/rarefaction for display;
TSS/CSS/RSS **offsets** for depth modelling — never "normalised to relative
abundances" for these fits, because that is not what happens), and BH
correction (mandatory whenever multiple tests are reported).

> **Disclose refusals.** When the software returns an unsuccessful state
> (non-convergence, non-identifiable design, boundary pathology, violated
> precondition), report the feature as *not tested* — not by dropping it
> silently and not by switching to a method that will produce a number. The
> refusal is the result.

## Small-n and rare-taxon work — the honest limit

**Academics (particularly clinical and low-biomass):** the asymptotic tests
available today degrade with tiny n and sparse features. The exact layer
that is designed for this — Fisher's exact, exact negative binomial,
permutation PERMANOVA (#3) — is **COMING, not present**. Until it lands, the
supported response to "2/3 cases vs 0/20 controls" is a descriptive summary
(exact counts, exact proportions) plus the words "no valid inferential test
was computed", which the method catalogue explicitly endorses as the correct
default when valid inference information is missing.

## The review caveat, stated once

The inference layer (fits, offsets) is implemented with strong tests — known
answers, an independent R reference comparison, negative controls for every
refusal path — but has **not** passed issue #1's independent statistical
review. For high-stakes claims, either wait for the review or have a
statistician read `docs/statistics/method-conditions/` against your design
before you trust a p-value. The software will compute exactly what the
conditions say; whether the model suits your study design remains your
judgement (and the conditions list the assumption most likely to be wrong).

## Teaching

The bundled `data/MiSeq_SOP/` dataset (mothur's MiSeq SOP) runs the full
path on known data — good for practicals. The refusal behaviour is also
pedagogically useful: students can watch a method decline rather than
fabricate. CladeCumulus (#6, **COMING**) is aimed at teaching cladistic
reading of composition.
