<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Method conditions — exact descriptive summaries

**Catalogue item 1** of [`method-catalogue-v1.md`](../method-catalogue-v1.md), approved
2026-09-22. **Published before implementation**, as the catalogue requires: the
implementation is held to this document, so it is written to be checked against rather
than admired.

## What this method is

Counts and proportions per sample — and per group when a grouping is supplied — carried at
**exact precision**: counts as exact integers, proportions as exact rationals.

**No inference is claimed.** No p-value, no interval, no model, no comparison. A user who
needs a claim about a difference between groups needs a different method with a different
document; this one describes.

### Response types accepted

- **Counts** (non-negative integers), exactly — including counts beyond 2^53−1, which no
  float can carry (measured in the boundary audit, #52).
- **Proportions / relative abundances**, computed internally as exact rationals of the
  counts. A proportion supplied as a text fraction (`"2/3"`, `"4/6"`) is exact; a
  proportion supplied as a float or decimal is accepted only as **an approximation, and is
  labelled as one** wherever it is used or shown.

### Zeros and all-zero samples — stated, not implied

- A zero count is a value, not missing data. It stays a zero.
- **An all-zero sample has a total of zero, so its proportions are undefined.** The summary
  returns an explicit *undefined* state and names the sample. It never returns `NaN`,
  never `0/0`, never `0` — reporting 0 as a zero-total sample's relative abundance is a lie
  told with a straight face.
- An all-zero table is summarised as zeros with zero totals, not rejected: "everything is
  zero" is a real observation about the data.

### Study design

- **Supported: none required.** This method summarises what is present; it does not require
  pairing, blocking, repeated measures or covariates, and it does not invent them.
- **If a grouping is supplied**: per-group summaries are produced, and **no comparison is
  made and no significance is reported**. That sentence also appears in the user-facing
  text, because a per-group table is the shape most often misread as a test.
- Missing design information never changes what is computed here, and there is no default
  that silently infers a design.

### Overdispersion and depth

- **Overdispersion is not modelled and not needed**: no distribution is assumed, so there
  is nothing for it to be wrong about.
- **Depth is always reported alongside proportions.** For compositional data a proportion
  without its denominator is uninterpretable, so every proportional row carries its total.

### Uncertainty

- **None is claimed** — no interval, no effect size, no test. The project rule that BH
  correction is mandatory wherever several tests are reported therefore does not apply
  here, because **no test is performed**. Stated so that its absence is a decision on the
  record rather than an omission somebody has to guess at.

### Diagnostics and warnings surfaced to the user

- Zero-total samples, each named.
- Approximate inputs, named with the precision they actually carry.
- Any resource limit reached (below), and any refusal — as an explicit unsuccessful state.
- In accessible language, and beside the numbers rather than in a log nobody reads.

### Computational limits

- Exact rational arithmetic grows, so numerator and denominator sizes are bounded by the
  policy's budget (`exact_rational_sum`, `ResourceLimitError`). On reaching a limit the
  summary **says so**; it never silently downgrades to floating point. A silent downgrade
  from exact to approximate is the exact failure this layer exists to prevent.
- **Storage and display are separate.** Exact values are stored exactly. Display may render
  a rounded decimal, and that rendering is marked as a rendering — it is never what gets
  stored.

## Evidence required with the implementation

1. **Known-answer tests** — expected values derived by hand rather than by the code under
   test: small tables whose exact answer is obvious (counts 4 and 6 → `2/3`), plus the
   audit's boundary counts (2^53+1, and a value beyond `Int64`).
2. **Independent reference** — the same summaries computed by an independent
   implementation (Python `fractions` and/or R) and compared value by value. If the runner
   lacks the partner, the check **skips loudly by name**, so "no independent reference ran"
   is visible rather than implied.
3. **Negative controls** — a zero-total sample must produce the undefined state and *not*
   zero; a float claiming exactness must be refused; a denominator-budget overrun must
   raise rather than round.
4. **Unchanged behaviour when the layer is not selected** — at the `:ordinary` default,
   nothing in the existing pipeline changes; these summaries are additional and opt-in.

## What this method refuses to do

- Report a proportion for a zero-total sample.
- Present an approximate value as exact, or an exact value as approximate.
- Compare groups, or attach significance to a descriptive table.
- Round for storage.
