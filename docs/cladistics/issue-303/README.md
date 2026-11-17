<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Issue 303 experiments: exact Phred arithmetic and the lazy zoomable tree

Fork only. Nothing here is proposed upstream. These are the measurements behind the
second-opinion work that [issue 303](https://github.com/hyperpolymath/MetaManifold-WebUI/issues/303)
asks for before any algorithm change. They are experiments, not a method and not a
complexity claim. Run on 2026-11-16 and 2026-11-17 with Julia 1.12.7 on four threads.

Agents wrote the scripts and this page. The person answering for them is
Jonathan D. A. Jewell (The Open University).

## What was asked

1. Does Phred-scored uncertainty force the exact-arithmetic work to move from the rationals
   to the reals?
2. Can tree building go from cubic towards linear by treating coarse views as "thumbnails"
   and zooming in only where needed?

## What was found, in one paragraph

Phred arithmetic can be exact without the reals, and on real reads it changes no filter
decision. Asking for distances only when needed recovers an exactly tree-like input from
about n log n distances instead of n². On real 240-base amplicon reads, however, the full
neighbour-joining tree is not a stable object: a tree built on 768 of 1,024 sequences agrees
with the 1,024-sequence tree on only 78% of that tree's well-supported branches. Lazy views
cannot be validated against a target that disagrees with itself, and no thumbnail summary
tested reached 60%. An earlier reading of experiment 4, that zoomed-in views keep over 90%
of well-supported branches, did not survive at 1,024 sequences (66%). Placing an amplicon-length
fragment on a reference tree built from full-length sequences does work: clade verdicts from
bootstrapped placements were right for 1,105 of 1,106 entailed and 57,116 of 57,128 refuted
verdicts, and pin a read to a clade of median size 18 among 399 references. With the
application's own placement step (RAxML EPA) the picture is sharper and less safe: 2,375 of
2,388 entailed verdicts were right, with no error among 1,515 verdicts on clades of 50 or more
references and 7 errors among 62 on clades of two or three. On a larger sample the smallest
confident clade was wrong for 32 of 448 queries (7.1%), falling to 4 of 448 (0.9%) when the
clade had to hold at least 64 of 399 references. About two thirds of those errors were
judged against a branch the reference tree does not itself support; where it is firm, 6 of
155 queries were wrong.

## Data

Experiments 4 to 6 use the forward reads of the MiSeq_SOP dataset, the same study the
integration test uses. The archive is not committed.

```bash
curl -L -o miseqsopdata.zip https://mothur.s3.us-east-2.amazonaws.com/wiki/miseqsopdata.zip
```

```bash
sha256sum miseqsopdata.zip
```

Expected digest: `728f7544824f8ca0223618b18bb60fce6a5dc20ae3d476267dbd5cf5594a35d4`
(downloaded 2026-11-17). Unzip it and pass the `MiSeq_SOP` directory to the scripts.

Experiment 7 uses the mothur SILVA bacterial reference alignment, also not committed.

```bash
curl -L -o silva.bacteria.zip https://mothur.s3.us-east-2.amazonaws.com/wiki/silva.bacteria.zip
```

Expected digest: `cd614303eaade6212a86bbb667be6be4c05f8c1c4f323c6d47035c4c8370039d`
(downloaded 2026-11-17). Unzip it and pass `silva.bacteria/silva.bacteria.fasta` to the script.

For experiments 4 to 6, reads are truncated to 240 bases, dropped if their expected errors exceed 2 or they contain
`N`, then dereplicated. They are **not** DADA2 output. Where a script says "crude denoise" it
drops every sequence within one edit of a more abundant one, and every sequence seen once.

## Experiments

"Agreement" is always: of the branches of the larger tree, cut down to the leaves of a view,
what share also appear in the tree built on the view alone. "Supported" means the branch is at
least three substitutions long. There is no known true tree for real reads, so real-data
experiments measure agreement, never accuracy.

### 1. Exact Phred expected errors (`phred_exact.jl`)

Every term `10^(-Q/10)` is a rational times a power of θ = `10^(-1/10)`. θ is a root of
`10x¹⁰ − 1`, which is irreducible, so an expected-error sum is one element of ℚ(θ): ten
rational coefficients. Comparison with a rational threshold is exact by bisection on θ.

| Check | Result |
| --- | --- |
| Exact sign against 512-bit arithmetic, 60,000 comparisons on random reads | 0 disagreements |
| Twenty bases at Q10 (sum exactly 2), threshold 2, double precision | reports 2.0000000000000004 > 2: wrong |
| 2,000 reads constructed to sum to exactly 2 | double precision wrong on all 2,000 |
| Random reads, double precision against exact | 0 disagreements |

### 2. Distances on demand, exact tree-like input (`zoom_tree.jl`)

Leaves are inserted one at a time; each is placed by asking at most three distances per level
of a centroid search. Input is an additive tree metric with integer edge lengths.

| Leaves | Distances asked | Share of the full matrix | Asked / (n log₂ n) |
| --- | --- | --- | --- |
| 1,024 | 10,210 to 15,199 | 1.9% to 2.9% | 1.0 to 1.5 |
| 4,096 | 53,608 to 79,971 | 0.6% to 1.0% | 1.1 to 1.6 |
| 16,384 | 266,642 to 394,964 | 0.2% to 0.3% | 1.2 to 1.7 |

The lower figure is a random-split tree, the higher a caterpillar. Every reconstruction matched
the true tree in topology and edge lengths, and canonical neighbour joining agreed on 160 small
cases. n log n is the known lower bound for this query model, so this is not O(n). The
prototype's running time is quadratic in bookkeeping; only the distance count is measured.

### 3. Lazy views, simulated noisy sequences (`zoom_noisy.jl`)

512 leaves, Jukes-Cantor evolution on random trees, views of 64 leaves, 5 trees per row.

| Sites | View | Agreement, all branches |
| --- | --- | --- |
| 250 | zoomed-in neighbourhood | 93.8% |
| 250 | thumbnail (spread-out leaves) | 86.2% |
| 250 | random subset | 92.5% |
| 1,000 | zoomed-in / thumbnail | 99.3% / 97.4% |
| 5,000 | all views | 99.7% or better |

On exact tree-like distances every figure is 100%. The simulated data sat 9 to 175 times
outside the Atteson radius even where neighbour joining recovered every branch, so that
radius does not explain when lazy views agree.

### 4. Lazy views, real reads (`zoom_real.jl`, `zoom_real_1024.jl`)

Part A, the Phred filter on 152,360 real reads: double precision and the exact method agree
on every read. No read sums exactly to the threshold; the closest is 2.2e-6 away. For 98.1% of
reads the double-precision sum depends on the order of addition. The exact method (integer
counts per quality value, exact comparison) took 6.2 times as long as double precision.

Part B, views of 64 leaves, 40 views per row:

| Sequences | View | All branches | Supported branches (middle 95% of views) |
| --- | --- | --- | --- |
| 512, error variants kept | zoomed-in | 60.7% | 91.2% (71.4 to 100) |
| 512, error variants kept | random subset | 60.8% | 81.4% (70.8 to 95.8) |
| 512, error variants kept | thumbnail | 43.1% | 50.9% (39.3 to 61.3) |
| 384, crude denoise | zoomed-in | 53.6% | 94.3% (77.7 to 100) |
| 384, crude denoise | random subset | 55.4% | 82.1% (71.1 to 95.8) |
| 384, crude denoise | thumbnail | 50.4% | 69.8% (56.6 to 89.0) |
| 1,024, crude denoise | zoomed-in | 35.3% | 65.8% (0 to 100) |
| 1,024, crude denoise | random subset | 43.3% | 60.2% (48.1 to 80.7) |

Agreement with leaf labels shuffled is 0% throughout. The 1,024 row is why the zoomed-in
figures above it should not be quoted alone.

### 5. Can the thumbnail be fixed by a better summary? (`thumb_real.jl`)

1,024 sequences, 64 regions around random representatives, 30 draws. Target: the full tree cut
down to the representatives. Share of supported branches reproduced:

| Summary of each region | Supported branches | Pairwise alignments |
| --- | --- | --- |
| one representative | 55.9% | 2,016 |
| mean over 4 members, corrected | 44.6% | 28,441 |
| mean over 8 members, corrected | 46.8% | 89,253 |
| mean over all members, corrected | 46.5% | 523,776 (all) |
| 5-mer counts of the representative | 55.4% | none |
| mean 5-mer counts of the region | 51.0% | none |

Spread-out representatives and 32 regions give the same picture; no summary exceeds 56%.
Alignment-free 5-mer distances match aligned distances for this purpose at no alignment cost.

### 6. Is the target stable? (`ceiling_real.jl`)

The tree on all 1,024 sequences compared with a tree built on a random subset of them, both cut
down to the same 64 leaves, 30 draws per row.

| Tree built on | All branches | Supported branches (middle 95%) |
| --- | --- | --- |
| 64 of 1,024 | 43.1% | 59.6% (44.0 to 73.7) |
| 128 | 43.8% | 59.6% (37.7 to 74.9) |
| 256 | 47.6% | 65.9% (47.7 to 81.3) |
| 512 | 51.7% | 70.4% (55.1 to 89.2) |
| 768 | 62.1% | 78.4% (59.3 to 90.4) |

### 7. Evidence verdicts on placements (`placement_evidence.jl`)

Experiment 6 says a stable overview has to come from outside the amplicon data. This tests
that route with a ground truth. 400 real full-length 16S sequences from the mothur SILVA
bacterial reference alignment give a reference tree. Each of 150 sequences in turn is pruned
from the tree; where it hung is the truth. Its amplicon-length fragment (the first 240 bases
of the V4 window) is placed back by weighted least squares against the tree's path distances,
and the fragment's columns are bootstrapped 100 times. For every clade, the share of
replicates placing the sequence inside it is the placement mass, and the verdict for "this
sequence belongs to this clade" is entailed at mass 1, refuted at mass 0, unresolved between.

| | Amplicon fragment | Whole sequence (positive control) | A different sequence placed (negative control) |
| --- | --- | --- | --- |
| Placed on exactly the true edge | 48.0% | 77.3% | 0.0% |
| Within two edges of it | 80.7% | 94.0% | 0.0% |
| Entailed verdicts that are right | 1,105 of 1,106 (99.91%) | 1,411 of 1,412 (99.93%) | 219 of 1,155 (18.96%) |
| Refuted verdicts that are right | 57,116 of 57,128 (99.98%) | 57,731 of 57,735 (99.99%) | 55,604 of 56,974 (97.60%) |
| Clades that truly hold the sequence: entailed / unresolved / wrongly refuted | 66.5% / 32.8% / 0.7% | 84.9% / 14.8% / 0.2% | 13.2% / 4.3% / 82.5% |
| Smallest entailed clade, median size of 399 | 18 | 7 | 26 |
| Smallest entailed clade holds the truth | 99.2% of queries | 99.3% | 6.6% |

Placement mass is close to calibrated for the amplicon fragment: clades given mass in
(0, 0.05] hold the truth 3.3% of the time, (0.05, 0.25] 12.7%, (0.25, 0.5] 38.5%,
(0.5, 0.75] 77.5%, (0.75, 0.95] 88.8% and (0.95, 1] 99.8%.

With the looser rule (entailed at mass 0.95 or more, refuted at 0.05 or less) the amplicon
fragment gives 1,295 of 1,297 entailed verdicts right (99.85%), a median smallest clade of 10,
and 1.6% of true clades wrongly refuted.

What this shows: an amplicon read rarely lands on exactly the right edge, but the clade it is
confidently placed in is right about 999 times in 1,000, and that clade is small (a median of
18 of 399 references). Below that depth the verdict is honestly unresolved. The negative
control shows the score can fail. What it does not show is in the limits below.

The counting rule that turns per-read verdicts into a per-sample verdict for a clade, with
separate bounds for wrongly counted and missed reads, is proved in
`metadatastician/MetaManifold-Evidence` (`agda/src/MetaManifold/Evidence/TwoSided.agda`,
not yet merged there). It also proves two zoom laws, each under a premise on the bounds. An
entailed verdict survives zooming out to an enclosing clade if the same bound on wrongly
counted reads holds for the larger clade. A refuted verdict survives zooming in to a
contained clade if that clade's bound on missed reads is no larger. An earlier version of
this page stated both without their premises; containment alone is not enough for either.

### 8. The application's own placement step (`epa/`)

Experiment 7 placed by least squares. This repeats it with the command the application runs
in its `place` step: `raxmlHPC-PTHREADS-SSE3 -f v -m GTRCATI -G 0.2` (RAxML 8.2.12). 200
full-length sequences from the same SILVA alignment give a maximum-likelihood reference tree
(IQ-TREE 2.0.7, GTR+G4). Each of the 200 in turn is pruned from the tree and its 240-base V4
fragment is placed back. For every clade of the pruned tree, the mass is the sum of the
likelihood weight ratios of the placements inside it, as RAxML reports them. The verdict is
entailed at mass 0.99 or more, refuted at 0.01 or less, unresolved between.

| | Amplicon fragment | Whole sequence (positive control) | A different sequence placed (negative control) |
| --- | --- | --- | --- |
| Placed on exactly the true edge | 91 of 200 (45.5%) | 188 of 200 (94.0%) | 0 of 200 |
| Within two edges of it | 76.5% | 99.5% | 1.0% |
| Entailed verdicts that are right | 2,375 of 2,388 (99.46%) | 3,065 of 3,065 | 1,507 of 3,176 (47.45%) |
| Refuted verdicts that are right | 35,988 of 36,016 (99.92%) | 36,208 of 36,211 (99.99%) | 34,392 of 35,952 (95.66%) |
| Clades that truly hold the sequence: entailed / unresolved / wrongly refuted | 75.2% / 23.9% / 0.9% | 97.0% / 2.9% / 0.1% | 47.7% / 2.9% / 49.4% |
| Smallest entailed clade, median size of 199 | 4 | 4 | 3 |
| Smallest entailed clade holds the truth | 139 of 146 queries (95.2%) | 193 of 193 | 9 of 189 (4.8%) |
| Queries with no entailed clade | 54 | 7 | 11 |

In this negative control the other sequence stays in the tree, so its fragment is placed
beside it; experiment 7 left it out. The two negative columns are not comparable.

The errors of the amplicon fragment depend on how small the clade is:

| Clade size (of 199 references) | Entailed verdicts | Wrong |
| --- | --- | --- |
| 2 to 3 | 62 | 7 |
| 4 to 7 | 132 | 1 |
| 8 to 15 | 228 | 1 |
| 16 to 49 | 451 | 4 |
| 50 to 199 | 1,515 | 0 |

Verdicts on nested clades of one query are not independent, so the per-query count is the
honest one. Reporting the smallest entailed clade, 7 of 146 queries get a wrong clade.
Reporting the smallest entailed clade of at least 4, 8 or 16 references, 4, 3 or 2 of the
146 do, at median sizes 6.5, 13 and 23.

RAxML reports few placements per query: a median of 3, at most 7, and a single one for 60 of
the 200. Four of the seven wrong queries had a single placement with weight 0.99 or more. The
mass is therefore lumpy. Clades given mass in (0, 0.05] hold the truth for 9 of 52,
(0.05, 0.25] 22 of 96, (0.25, 0.5] 24 of 46, (0.5, 0.75] 53 of 98, (0.75, 0.95] 280 of 324
and (0.95, 1] 2,745 of 2,773.

With the looser rule (entailed at 0.95 or more, refuted at 0.05 or less) 2,745 of 2,773
entailed verdicts are right (98.99%), and the smallest entailed clade is wrong for 17 of 172
queries.

Three self-checks passed. An independent calculation of the truth from path distances on the
unpruned tree matched in all 10 tests (9 distinct queries). In all 600 runs the 395 edge
numbers of the placement file map to 395 distinct branches of the pruned tree. Clade mass
never decreased
from a clade to the clade containing it (39,200 pairs per column). `08_by_depth.jl`
recomputes the tables from the per-clade output separately from `06_tables.jl`; the two
agree.

What this shows: with the application's placement step, "present in this clade" was right
in every case seen for clades of a quarter of the tree or more, and wrong about one time in
nine for clades of two or three references. At that depth the verdict is confidently wrong,
not unresolved. Experiment 9 repeats this on a larger sample and finds errors on large clades
too. What it does not show is in the limits below.

### 9. Error by clade depth (`epa-depth/`)

The same test as experiment 8 on a larger sample, to put a number on how the error depends
on clade size. Two independent draws of 400 references (13 sequences are in both), a
maximum-likelihood tree for each, and 300 amplicon queries per draw: 600 queries. As a
control, the whole sequence of 60 queries was placed: 60 of 60 landed on the exact edge and
none of their 1,134 entailed verdicts was wrong.

For the amplicon fragment, 9,555 of 9,613 entailed verdicts were right. The 58 wrong ones by
clade size:

| Clade size (of 399 references) | Entailed verdicts | Wrong | Queries with a wrong verdict |
| --- | --- | --- | --- |
| 2 to 3 | 215 | 15 | 13 |
| 4 to 7 | 417 | 12 | 11 |
| 8 to 15 | 507 | 11 | 9 |
| 16 to 31 | 748 | 7 | 6 |
| 32 to 63 | 999 | 6 | 2 |
| 64 to 127 | 431 | 2 | 1 |
| 128 to 399 | 6,296 | 5 | 3 |

The five errors in the last row are on clades holding 357 to 372 of the 399 references. The
branch there cuts off a small group, and the sequence truly sits in that small group. Binned
by the smaller side of the branch instead, the wrong count falls from 15 of 444 at two or
three references to 2 of 1,271 at 64 to 127, and 0 of 1,119 at 128 or more.

One result per query is the honest unit. The rule "report the smallest entailed clade with
at least k references" gave:

| k | Queries given a clade (of 600) | Median clade size | Wrong | Rate (exact 95% interval) |
| --- | --- | --- | --- | --- |
| 2 | 448 | 4 | 32 | 7.1% (4.9 to 9.9) |
| 4 | 448 | 7 | 25 | 5.6% (3.6 to 8.1) |
| 8 | 448 | 14 | 17 | 3.8% (2.2 to 6.0) |
| 16 | 448 | 26 | 11 | 2.5% (1.2 to 4.4) |
| 32 | 448 | 46.5 | 6 | 1.3% (0.5 to 2.9) |
| 64 | 448 | 173 | 4 | 0.9% (0.2 to 2.3) |

The other 152 queries had no entailed clade. The two draws agree within their intervals:
19 of 230 and 13 of 218 at k = 2. Of the 32 queries wrong at k = 2, 18 had a single reported
placement and 18 had a best weight of 0.99 or more. With the looser rule (0.95) the rates
are higher: 61 of 540 at k = 2 and 10 of 540 at k = 64.

The intervals are Clopper-Pearson and treat queries as independent. The queries of one draw
share one reference tree, so the intervals cover the sampling of queries on these two trees,
not the variation between trees.

Self-checks passed: the control above; an independent truth calculation matched for 10
queries in each draw; all 793 edge numbers of every placement file map to distinct branches
of the pruned tree; clade mass never decreased from a clade to the clade containing it; and
the new table code reproduces experiment 8's counts from experiment 8's output.
`epa-depth/08_crosscheck.jl` recomputes the tables separately from `06_tables.jl`; the two
agree.

What this shows: the error of a "present in this clade" verdict from an amplicon fragment
falls as the clade grows and does not reach zero. Requiring 64 references in the clade
brought it under 1% of queries, at the price of a median clade of 173 of 399. The whole
sequence, placed the same way, was never wrong in 60 queries. The truth was itself built
from the whole sequence, so that control shows the machinery is sound; it does not show the
reference tree is right at the finest depth.

### 10. Placement error, or an uncertain reference tree? (`epa-depth/10_support.jl`)

Experiment 9 judges each verdict against the reference tree built with the query's whole
sequence. That tree is itself an estimate. The tree of the first draw carries
ultrafast-bootstrap support on its branches: a median of 100, with 112 of its 397 internal
branches below 95. For each reported clade, one branch of that tree backs the truth. If the
truth says the query is inside the clade, it is the branch that holds the clade with the
query. If the truth says it is outside, it is the branch that holds the clade without it. The
support of that branch is the reference tree's own confidence in the truth for that verdict.
The thresholds 95 and 70 were fixed before the tables were computed.

First draw, 230 queries given a clade, wrong verdicts by the support of the truth branch:

| Smallest entailed clade of at least | Support 95 or more (exact 95% interval) | Support below 95 |
| --- | --- | --- |
| 2 references | 6 of 155 (3.9%, 1.4 to 8.2) | 13 of 75 (17.3%, 9.6 to 27.8) |
| 8 | 2 of 107 (1.9%, 0.2 to 6.6) | 8 of 123 (6.5%, 2.8 to 12.4) |
| 32 | 1 of 69 (1.4%, 0.0 to 7.8) | 3 of 161 (1.9%, 0.4 to 5.3) |

With no minimum size, 13 of the 19 wrong verdicts were judged against a branch the reference
tree does not itself support at 95. The two errors on very large clades from this draw (357
and 367 references) were against branches with support 62 and 65. The other 6 were against
well-supported branches, 5 of them with support 100. Those are placement errors by the
reference tree's own standard.

What this shows: at the finest depth about two thirds of the measured error sits where the
reference tree is itself unsure, and about one third is error against a well-supported
branch. It splits experiment 9's error; it does not reduce it. In the first case the truth
may be what is wrong, and in the second the placement is. Where the reference tree is firm,
the smallest confident clade was wrong for 6 of 155 queries.

## Reading of the results

- **Evidence on placements.** Experiments 7 and 8 are the positive real-data results. Verdicts
  by clade are sound at the rates above for coarse clades, and they give the "thumbnail then
  zoom" idea a form that holds at the coarse end: the verdict is decided at a coarse clade.
  How it fails as the clade shrinks depends on where the mass comes from. With bootstrapped
  least squares (experiment 7) it became undecided. With the likelihood weights of the
  application's placement step (experiment 8) it became wrong for 7 of 62 verdicts on the
  smallest clades. Experiment 9 puts numbers on it: a minimum clade size trades error for
  resolution (7.1% of queries wrong with no minimum, 0.9% with a minimum of 64 references).
  A rule for the application needs that minimum or a better-calibrated mass. Neither has
  been chosen, and no rule has been tested inside the application. Experiment 10 adds that
  the reference tree matters as much as the placement: most fine-depth errors fall on
  branches the reference tree does not support, so showing a verdict only on supported
  branches of the reference is a third option, also untested.
- **Counting reads does not average this error away.** Each query in experiments 7 and 8 is
  one sequence. Reads from the same organism share that sequence, so if it is misplaced they
  are all misplaced together. The bound on wrongly counted reads that the counting rule
  takes as input cannot be read off the number of reads; it has to come from the number of
  distinct sequences and a per-depth error rate. Experiment 9 gives that rate for error-free
  fragments on two trees; it has not been measured on real reads.
- **Exactness.** The rationals do not need replacing by the reals for Phred: one algebraic
  number is enough. On this dataset exact arithmetic gives the same decisions as double
  precision. What it adds is order-independence and a provable comparison, not a different
  answer.
- **Linear time.** On tree-like input the distance count falls from n² to about n log n, which
  is optimal for distance queries. Nothing here supports O(n) for de novo tree building, and no
  use for the Veblen hierarchy in the algorithm was found.
- **Lazy views on amplicon reads.** Experiment 6 is the limiting result. At 240 bases the
  neighbour-joining tree changes, including in branches it reports as well supported, when
  sequences are added. Agreement with that tree is therefore the wrong contract, and experiment
  5's failure is not a failure of the summaries. A stable overview has to come from outside the
  amplicon data, which is what a reference tree with placement provides.

## Limits

- One dataset, one marker region, one read length; dereplicated reads, not denoised variants.
- Neighbour joining only, with Jukes-Cantor distances in double precision and first-minimum tie
  breaking. Other distance corrections, tie policies and tree methods were not tried.
- "Supported" is a branch-length threshold, not a bootstrap or posterior support.
- Samples are small (30 to 40 views per row) and the ranges are wide.
- Experiments 2 and 3 use simulated input. Experiment 2 measures distance counts, not time.
- Experiment 7: the truth is where the sequence sat in a neighbour-joining tree built from
  full-length distances, so it is defined by the same family of method that places it. The
  queries are fragments of reference-quality sequences with no sequencing error. Placement is
  distance-based least squares, not the likelihood placement (EPA) the application runs. One
  marker, 400 references, 150 queries, 100 bootstrap replicates. The one wrong entailed
  verdict in 1,106 means "entailed" is a measured rate, not a proof. Verdicts for nested clades of
  one query are not independent: counted per query, the smallest entailed clade was wrong for
  1 of 130 queries, and 20 further queries had no entailed clade at all.
- Experiment 8: the truth is where the full-length sequence sits in a maximum-likelihood tree
  that was not bootstrapped, so some errors on the smallest clades may be the reference tree's
  own uncertainty; the two were not separated. The reference tree used a fixed model (GTR+G4)
  with IQ-TREE 2.0.7, where the application selects a model, bootstraps and pins IQ-TREE 3.1.4.
  The application's alignment and trimming steps (MAFFT, trimAl) were skipped: queries sit in
  the columns of the SILVA alignment. Queries are error-free fragments of reference sequences.
  200 references and 200 queries, one draw. Experiment 9 shares every limit of experiment 8
  except size: 400 references, two draws, 600 queries. The second draw's tree was built
  without bootstrap after the bootstrapped run exceeded 25 minutes; the bootstrap supports of
  the first tree are analysed in experiment 10. Experiment 10 uses that one tree and 230
  queries. The support of one branch is a lower bound on the tree's confidence that a query
  lies outside a clade, because the branch can fail in a bootstrap replicate for reasons
  that do not involve the query. Experiments 7 and 8 differ in the number of
  references, the tree method, the source of the mass and the thresholds, so the difference
  between them is not the effect of the placement method alone. A cheaper agent ran the
  experiment; the tables were recomputed separately from its per-clade output.
- Not done: any comparison with RapidNJ, SwiftNJ or FastTree, any test with real reads, the
  application's placement step with its speed heuristic turned off, and any change to the
  application.

## Running

```bash
julia docs/cladistics/issue-303/phred_exact.jl
```

```bash
julia docs/cladistics/issue-303/zoom_tree.jl
```

```bash
julia -O2 docs/cladistics/issue-303/zoom_noisy.jl
```

```bash
julia -O2 -t 4 docs/cladistics/issue-303/zoom_real.jl /path/to/MiSeq_SOP
```

```bash
julia -O2 -t 4 docs/cladistics/issue-303/zoom_real_1024.jl /path/to/MiSeq_SOP
```

```bash
julia -O2 -t 4 docs/cladistics/issue-303/thumb_real.jl /path/to/MiSeq_SOP
```

```bash
julia -O2 -t 4 docs/cladistics/issue-303/ceiling_real.jl /path/to/MiSeq_SOP
```

```bash
julia -O2 -t 4 docs/cladistics/issue-303/placement_evidence.jl /path/to/silva.bacteria.fasta
```

Experiment 8 needs `raxmlHPC-PTHREADS-SSE3` and `iqtree2` on the path. `$WORK` is a directory
of your choice, absolute or relative, and may contain spaces; the drivers resolve it to an
absolute path and stop with a non-zero status if a stage fails. Set it once in the shell, copy
`epa/` to `$WORK/scripts`, then run the steps in order:

```bash
WORK=/path/to/work
```

```bash
sh "$WORK/scripts/01_run.sh" "$WORK" /path/to/silva.bacteria.fasta
```

```bash
sh "$WORK/scripts/02_tree.sh" "$WORK"
```

```bash
julia "$WORK/scripts/03_prep.jl" "$WORK" 200 7
```

```bash
(set -e; for k in amp pos neg; do sh "$WORK/scripts/05_run_epa.sh" "$WORK" $k; julia "$WORK/scripts/04_score.jl" "$WORK" $k; done)
```

```bash
julia "$WORK/scripts/06_tables.jl" "$WORK" amp pos neg
```

```bash
julia "$WORK/scripts/08_by_depth.jl" "$WORK"
```

The check that selection stops when a row loses a V4 base to column filtering:

```bash
julia docs/cladistics/issue-303/epa/test_select.jl
```

The drivers take optional trailing size arguments for a quick trial; without them they run the
published sizes. `01_run.sh` takes the number of references (default 200), `02_tree.sh` the
thread count (default 4), and `03_prep.jl` the number of queries. For experiment 9,
`run_trees.sh` takes the references per draw (default 400), the bootstrap timeout in seconds
(default 1500) and the threads (default 4), and `run_rest.sh` takes the queries per draw
(default 300) and the whole-sequence controls (default 60).

Experiment 9: copy `epa/` and then `epa-depth/` over it to `$WORK/scripts`, then:

```bash
sh "$WORK/scripts/run_trees.sh" "$WORK" /path/to/silva.bacteria.fasta
```

```bash
sh "$WORK/scripts/run_rest.sh" "$WORK"
```

```bash
mkdir -p "$WORK/raw" && (set -e; for t in "A amp" "A pos" "B amp"; do set -- $t; julia "$WORK/scripts/04_score.jl" "$WORK/$1" $1 $2; done)
```

```bash
julia "$WORK/scripts/06_tables.jl" new "$WORK/raw"
```

```bash
julia "$WORK/scripts/08_crosscheck.jl" "$WORK/raw"
```

Experiment 10, on the first draw:

```bash
julia "$WORK/scripts/10_support.jl" "$WORK/A"
```

The scripts use only Julia's standard library and fixed random seeds. `zoom_real.jl` carries its
own copy of the shared code because it is the script as it was run; the later scripts include
`lib_tree.jl`.
