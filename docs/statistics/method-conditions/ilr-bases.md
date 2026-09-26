<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Method conditions — ILR bases: phylogenetic (PhILR), SBP, balance dendrogram

**Status: published 2026-09-26, before the implementation in `src/analysis/ilr_basis.jl`.**
Where this document and that file disagree, the document is right and the file is the bug.

**Why it exists now.** Issue #20 asked for three ILR bases that the configuration already
*named* but refused at run time ("deferred, see GitHub issue #20"). The owner directed on
2026-09-25 that deferred items be implemented; this document lifts the deferral for these
three bases only and fixes what "implemented" is allowed to mean. The Helmert `default`
basis is unchanged, byte for byte.

**Formal backing.** The exact-arithmetic properties below are machine-checked in Agda
(`proofs/agda`, plan in `docs/formal/verification-plan.md`). Each is cited by theorem name;
the Julia test that checks the floating-point code against it carries the same name.

## What an ILR basis is

An isometric log-ratio basis for `D` parts is a set of `D − 1` *balances*. Every basis used
here is given by a rooted, strictly bifurcating tree over the parts: each internal node `n`
splits the parts below it into a numerator group `N₊` (first child) and a denominator group
`N₋` (second child). With part weights `p` (all 1 unless stated) and `r = Σ_{N₊} p`,
`s = Σ_{N₋} p`, the balance of a sample `x` is

```
b_n(x) = sqrt(r·s / (r + s)) · ( mean_p(log(x/p) over N₊) − mean_p(log(x/p) over N₋) )
```

where `mean_p` is the `p`-weighted mean. For uniform weights this is Egozcue et al. (2003)
and Egozcue & Pawlowsky-Glahn (2005); for general `p` it is the weighted ILR of Silverman
et al. (2017, PhILR), identical to R `philr`'s `clrp(x, p) %*% diag(p) %*% V` with
`V = buildilrBasep(sbp, p)`.

Proved properties (exact arithmetic, any commutative ring, `ILR.*` modules):

| Property | Agda theorem | Consequence |
|---|---|---|
| `D` parts ⇒ exactly `D − 1` balances; preorder numbering is a bijection | `internal-count`, `fromFin-toFin`, `toFin-fromFin` | balance count and ids are well defined |
| each balance's contrast is `p`-centred | `contrast-sum-zero` | the balance does not depend on the CLR centring used |
| distinct contrasts are `p`-orthogonal; squared norm `r·s·(r+s)` | `contrast-orthogonal`, `contrast-norm` | with the constant above the basis is orthonormal (`basis-unit`, `basis-orthogonal`) |
| contrast = function of the SBP row and the masses `r`, `s` | `contrast-from-code`, `plus-mass-from-code` | computing from a tree and from its SBP give the same numbers |
| injective on centred vectors (positive weights) | `balance-injective`, `balance-injective-positive` | no information is lost relative to CLR |
| not injective for signed weights | `kernel-needs-hypothesis` | non-positive part weights are refused |
| multiplying a sample by any positive factor leaves every balance unchanged | `balance-scale-invariant` | counts, proportions and library-size-scaled counts give identical balances |
| the comb tree with uniform weights is the Helmert default | `comb-is-helmert`, `comb-masses` | the new engine reproduces the old basis (tested to 1e-12) |

The only analytic facts used — `log` turns products into sums and `1/sqrt(r·s·(r+s))`
exists — are named hypotheses (`LogHom`, `Normaliser`), not postulates.

## Engine (shared by all three bases)

- Each basis is reduced to a validated tree; balances are then computed **on the fly** from
  clade sums in one post-order pass per sample: `O(D)` time and memory per sample, `O(D·n)`
  in total. No dense `D × (D − 1)` matrix is ever built (for 10 000 taxa a dense basis is
  ~800 MB; the engine needs a few hundred kB).
- Input to the engine is the zero-handled, filtered count table (taxa × samples). It must be
  strictly positive; zero handling is issue #21's and precedes this step.
- Output rows are balances, named by balance id (below); the downstream model reports one
  test per balance and Benjamini–Hochberg correction across balances is mandatory as for
  every other response. The DANGER banner rules are unchanged.
- `checks["ilr"]` records, per balance: id, numerator child, denominator child (a taxon or
  another balance id — together these *are* the SBP, in `O(D)` space), `r`, `s`, and the
  normalising constant.

## Basis 1 — `phylogenetic` (PhILR; Silverman et al. 2017)

**Input.** `advanced.ilr_phylo_tree_path`: a Newick file. Tip labels are matched to taxon
ids exactly (quoted labels allowed; no case folding, no underscore/space rewriting).

**Refused, with the reason named:**

- a file that does not parse as Newick, or has duplicate tip labels;
- an **unrooted** tree — a basal trifurcation, which is how FastTree, IQ-TREE and RAxML
  write unrooted trees. MetaManifold does not root trees: the root decides every balance,
  and choosing one (midpoint, outgroup) is a scientific decision to make in a phylogenetics
  tool and record there;
- any other **multifurcation** (polytomy) that survives pruning to the retained taxa.
  Resolving one arbitrarily (as `ape::multi2di` does randomly) would invent balances that
  no data supports. A polytomy of which at most two branches still hold retained taxa is an
  ordinary split once pruned, and is accepted. The basal check above is made *before*
  pruning: pruning one basal branch of an unrooted tree would otherwise silently invent a
  root;
- retained taxa missing from the tree (up to ten are named).

**Pruning.** Tree tips that are not retained taxa (absent from the table, or removed by
prevalence/abundance filtering) are pruned and the resulting unary nodes collapsed, summing
branch lengths — what `ape::keep.tip` does. The number of pruned tips is recorded. The
basis is built **after** filtering, on the retained taxa only.

**Balance ids and order.** Balances are emitted in preorder of the pruned tree (root first,
children in Newick order), which is `philr`'s column order (ape node numbering) for a tree
that needs no pruning. Ids are the internal node labels when every internal node has a
unique, non-numeric label; otherwise `n1 … n(D−1)` in preorder. Numeric labels are treated
as support values, not names. Which rule applied is recorded.

**Part weights** (`advanced.ilr_part_weights`), exactly `philr`'s `part.weights`, computed
on the zero-handled retained table: `uniform` (default), `gm_counts` (geometric mean of
each taxon across samples), `anorm` (Aitchison norm of each taxon's profile across samples),
`enorm` (Euclidean norm of each taxon's closed profile), `anorm_x_gm_counts`,
`enorm_x_gm_counts`. Data-derived weights use the data twice; this is recorded.

**Balance weights** (`advanced.ilr_balance_weights`), exactly `philr`'s `ilr.weights`:
`uniform` (default), `blw` (sum of the two child edge lengths), `blw_sqrt`,
`mean_descendants` (sum over the two children of edge length plus mean distance to
descendant tips). They need branch lengths (refused if any is missing). As in `philr`,
zero-length tip edges are replaced by the tree's smallest non-zero edge length, with a
recorded warning. A balance weight multiplies a balance by a constant, so it changes effect
sizes but **not** per-balance test statistics; it does make the coordinates non-isometric,
which is recorded.

**Reference.** `philr` (Bioconductor) is not in `renv.lock` and is not added. Agreement is
established against an independent Julia port of `philr` 1.x
(`test/fixtures/ilr/ilr_reference.jl`, ported from the package source line by line,
including its own known-answer test, and using Base Julia only). The port follows philr's own
route — the dense D × (D−1) basis, `clrp %*% diag(p) %*% V` — which the engine never forms,
so agreement is not a restatement of the engine. It recomputes the committed expectations
from the committed inputs on every test run: three datasets, to 1e-10 — tighter than the
issue's 1e-6. An R cross-check runs when `philr` is installed and is skipped, visibly,
otherwise.

## Basis 2 — `sequential_binary_partition` (Egozcue & Pawlowsky-Glahn 2005)

**Input.** `advanced.ilr_sbp_matrix_path`: a CSV with one row per taxon and one column per
balance. The first column holds taxon ids; each other column is a balance whose header is
its id; entries are `1` (numerator), `-1` (denominator) or `0` (not involved). `+1`, `1.0`
and `-1.0` are accepted as spellings of the same values; nothing else is.

**Validity** is Egozcue & Pawlowsky-Glahn's definition, decided by reconstructing the tree:

- `D ≥ 2` rows, exactly `D − 1` balance columns, unique taxon ids and unique non-empty
  balance ids;
- every column has at least one `1` and at least one `−1`;
- exactly one column involves every taxon (the first partition);
- every other column's involved set is exactly one side of an earlier split, and every
  group of two or more taxa produced by a split is split by exactly one column.

A matrix passes if and only if it is the SBP of a rooted binary tree (the proof side's
`code`, with `code-has-plus`, `code-has-minus`, `code-nested-inl/-inr`). Each failure names
the offending column and set.

**Taxa.** The SBP must be over exactly the retained taxa. A retained taxon missing from the
SBP is refused. An SBP taxon that is not retained is also refused, because removing a taxon
always removes a balance that isolates it: a hypothesis the user wrote down would silently
disappear. The message says which taxa, and whether filtering removed them (lower
`min_prevalence`/`min_abundance`, or delete the rows and re-balance the SBP).

**Order and ids.** Balances keep the SBP's column order and header names.

**Reference.** Balances are checked against the closed form above and against
`compositions::ilr(x, gsi.buildilrBase(W))` semantics (uniform weights), reproduced in the
Julia reference (`test/fixtures/ilr/ilr_reference.jl`); the round trip tree → SBP → tree is
the identity.

**p-hacking guard.** Trying SBPs until one "works" is a forking-paths problem. Every run
records the SHA-256 of the SBP file. `advanced.ilr_sbp_history` carries the SHA-256s of
SBPs tried earlier in the same project (the UI appends to it); the run counts the distinct
SBPs including the current one, records the count, and when it exceeds **3** the
configuration is DANGER-flagged and the banner says why. The count is disclosed, not
refused: pre-registration is the remedy, and the record makes the history visible.

## Basis 3 — `balance_dendrogram` (Pawlowsky-Glahn, Egozcue & Tolosana-Delgado 2015)

**Input.** `advanced.ilr_balance_dendrogram_method` ∈ `ward`, `complete`, `average`.

**Definition.** Parts are clustered on the **variation matrix**
`τᵢⱼ = Var(log(xᵢ/xⱼ))` (sample variance across samples, denominator `n − 1`) of the
zero-handled retained table, by R's `hclust` algorithm (Murtagh's nearest-neighbour-list
method, ported from R's `hclust.f` including its tie-breaking), with `ward` meaning R's
`ward.D2`. This is exactly `robCompositions::clustCoDa_qmode(x, method)` with the classical
variation (`variation(x, method = "Pairwise")`); robCompositions' default *robust* variation
is not reproduced (it needs `robustbase`, which is not in `renv.lock`). The merge tree is
converted to an SBP as `compositions::gsi.merge2signary` does: the second cluster of each
merge is the numerator, the first the denominator.

**Ids and order.** Balance `m<k>` is the `k`-th merge (so ids match R's `hclust()$merge`
rows); balances are emitted in preorder (root = last merge first).

**Conditions.** At least 2 samples (a variance needs two). The variation matrix is stored
condensed (`D(D−1)/2` doubles); above 1 GB (≈ 16 000 taxa) a warning is recorded, above
2 GB the run is refused rather than risk the host. The dendrogram uses no metadata, but it
is still derived from the same data that is then tested; this is recorded in the checks.

**Reference.** Merge heights and splits are checked against the generic agglomerative
algorithm in `test/fixtures/ilr/ilr_reference.jl` — the global minimum over all active pairs
at every step, with the Lance–Williams updates of R's `ward.D2`/`complete`/`average` — which
is a different algorithm from the nearest-neighbour list of R's `hclust.f` that the engine
ports; the two must agree on tie-free data, and the reference refuses data with a tied
minimum. The tie-breaking rule is checked against hand-computed examples.

## Configuration contract

| Field | Where | Rule |
|---|---|---|
| `normalization.ilr_basis` | ILR only | `default` \| `phylogenetic` \| `sequential_binary_partition` \| `balance_dendrogram` |
| `advanced.ilr_phylo_tree_path` | required iff `phylogenetic` | refused otherwise |
| `advanced.ilr_sbp_matrix_path` | required iff `sequential_binary_partition` | refused otherwise |
| `advanced.ilr_balance_dendrogram_method` | required iff `balance_dendrogram` | `ward` \| `complete` \| `average` |
| `advanced.ilr_part_weights` | non-default bases | `uniform` for `default` (its loop is unchanged) |
| `advanced.ilr_balance_weights` | `phylogenetic` only | needs branch lengths |
| `advanced.ilr_sbp_history` | SBP only | SHA-256 hex strings; > 3 distinct SBPs ⇒ DANGER |

All fields are written to JSON, Nickel and DEED, and enter the configuration hash whenever
any of them differs from its default. When all are at their defaults the canonical form
hashed is exactly the one used before these fields existed, so no configuration hashed
earlier changes its hash. Whether a tree or SBP *file* exists is checked when the run
reads it, not when the configuration is built: a configuration is written on one machine
and may be run on another. A relative path resolves against the working directory of the
process that runs the analysis (the server's, for the web UI), not against the location of
the configuration file; the refusal message prints that directory. Prefer absolute paths,
or paths relative to the directory the server is started from. Either way the run records
the file's SHA-256, so the provenance identifies the file by content, not by name. The schemas enforce the field-presence rules in the table. The run's provenance
records the basis, the SHA-256 of the tree or SBP file, the dendrogram method, both weight
choices, the SBP attempt count, pruned tips and the balance-id rule.

## Performance

**Complexity.** Phylogenetic and SBP balances are clade sums in one post-order pass: `O(D)`
time and memory per sample. The SBP reader streams the CSV twice (validate, then fill an
`Int8` matrix), so a 10 000-taxon SBP — 10⁸ cells, as the issue's taxa × balances format
requires — costs ~100 MB for the matrix, not a table of strings. The balance dendrogram
needs the condensed variation matrix (`8·D(D−1)/2` bytes, ≈ 0.37 GiB at 10 000 taxa) and
`hclust`'s `O(D²)` time; the limits above apply.

*Finding, not changed here:* the default Helmert loop in `Execution.prepare_analysis_table`
takes `mean(log_col[1:i])` of a fresh slice for every balance, which is `O(D²)` time and
transient allocation per sample (≈ 400 MB per sample at 10 000 taxa). #20 keeps it
byte-identical on purpose; the comb tree (`comb-is-helmert`) reproduces it in `O(D)` and
could replace it in a separate, hash-neutral change.

**Scaling benchmark** (`bench/ilr_bases/benchmark.jl`, run in CI; `just bench-ilr`). CLR,
default ILR and the three bases (dendrogram with all three linkages) at 100, 1 000 and
10 000 taxa, 20 samples, on a deterministic table. It reports wall time, bytes allocated and
peak-RSS growth per workload, and emits a warning for any workload over **5 minutes** or
over **1 GiB** allocated or of peak-RSS growth. It is informational, like the repository's
other Julia benchmarks: timings recorded on one host say nothing about another.

**Regression gate** (`bench/ilr_bases/regression_gate.jl`, pull requests; `just
bench-ilr-gate`). The CLR (5 000 taxa × 60 samples) and default ILR (1 500 × 40)
paths through `prepare_analysis_table` are measured for the PR's *base* commit and its
*head* on the same runner, interleaved base, head, base, head. CI fails if head allocates
more than 10 % more bytes (deterministic for a fixed Julia and input) or if its minimum
time over 7 repetitions per round is more than 10 % slower. Comparing with a committed
baseline instead would measure the runner, not the change.

## References

- Egozcue, J. J., Pawlowsky-Glahn, V., Mateu-Figueras, G. & Barceló-Vidal, C. (2003).
  Isometric logratio transformations for compositional data analysis. *Mathematical
  Geology* 35, 279–300.
- Egozcue, J. J. & Pawlowsky-Glahn, V. (2005). Groups of parts and their balances in
  compositional data analysis. *Mathematical Geology* 37, 795–828.
- Pawlowsky-Glahn, V., Egozcue, J. J. & Tolosana-Delgado, R. (2015). *Modeling and
  Analysis of Compositional Data*. Wiley.
- Silverman, J. D., Washburne, A. D., Mukherjee, S. & David, L. A. (2017). A phylogenetic
  transform enhances analysis of compositional microbiota data. *eLife* 6, e21887.
- Filzmoser, P., Hron, K. & Templ, M. (2018). *Applied Compositional Data Analysis*.
  Springer (robCompositions `clustCoDa_qmode`).
- Murtagh, F. (1985). *Multidimensional Clustering Algorithms*. Physica-Verlag (the
  algorithm in R's `hclust.f`).
