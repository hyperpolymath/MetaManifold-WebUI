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
of well-supported branches, did not survive at 1,024 sequences (66%).

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

Reads are truncated to 240 bases, dropped if their expected errors exceed 2 or they contain
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

## Reading of the results

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
- Not done: any proof, any comparison with RapidNJ, SwiftNJ or FastTree, any test of placement
  on a reference tree, and any change to the application.

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

The scripts use only Julia's standard library and fixed random seeds. `zoom_real.jl` carries its
own copy of the shared code because it is the script as it was run; the later scripts include
`lib_tree.jl`.
