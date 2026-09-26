<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Formal verification plan — compositional transforms (issues #20, #21)

**Status: adopted 2026-09-26.** This document fixes *which* prover is used, *what* is
proved, *what is deliberately not proved*, and *how* the proofs are tied to the Julia code
that the statistics actually run. It is written before the ILR-basis implementation
(issue #20) lands, so that the implementation is built against it rather than the other
way round.

## 1. Decision: Agda

| Candidate | Fit | Decision |
|-----------|-----|----------|
| **Agda 2.6.4.3 + stdlib 2.1** | Same pin as the estate's existing proof repositories (`epistemic-types`, `residual-evidence-types`: Debian 13 `agda-bin 2.6.4.3-1+b2`, `agda-stdlib 2.1-4`); constructive; `--safe --without-K`; generic over `CommutativeRing` so one proof covers ℤ, ℚ and any exact model. | **Chosen.** |
| Lean 4 + Mathlib | Best real-analysis library (`Real.log`, `Real.sqrt`, inner-product spaces). | Not chosen *now*. Adopted only if a genuine rationale appears (see §7) and then only as a labelled mirror of an Agda statement, never as a second source of truth. |
| Isabelle/HOL | Strong automation; nothing in the estate uses it. | Not chosen: a third proof culture with no shared definitions. |

The deciding consideration is **coherence**: issue #21 (zero handling) is being done in
Agda, and the objects it reasons about — compositions, closure, log-ratios, the
geometric mean — are the same objects the ILR bases act on. Two provers would mean two
definitions of "composition" that nobody checks agree.

### Guardrails (enforced in CI, mirroring the estate repositories)

- Every module starts with `{-# OPTIONS --safe --without-K #-}`; the library file sets the
  same flags so a file that forgets the pragma is still checked safely.
- No `postulate`, no `{-# TERMINATING #-}`, no `{-# NON_TERMINATING #-}`, no
  `{-# NO_POSITIVITY_CHECK #-}`, no `{-# NO_UNIVERSE_CHECK #-}`, no holes (`?`, `{! !}`),
  no `trustMe`. `--safe` already rejects most of these; the grep guard makes the policy
  visible and catches the ones `--safe` permits.
- Assumptions that cannot be proved (transcendental functions, floating point) are
  **record parameters with names**, never postulates, so every theorem that depends on
  one says so in its type.
- Negative controls: `proofs/agda/reject/` holds files that must **fail** to type-check
  (e.g. claiming non-degeneracy without its hypothesis). CI checks they still fail. A
  proof suite that cannot fail has not been shown to check anything.

## 2. Layering — what is proved at which level of abstraction

The Julia code computes in `Float64` with `log` and `sqrt`. No prover in reach verifies
that. The honest arrangement is four layers with explicit seams:

| Layer | Content | Status |
|-------|---------|--------|
| **L0 combinatorics** | Rooted binary trees; `D` leaves ⇒ `D − 1` internal nodes; preorder enumeration of nodes is a bijection with `Fin (D − 1)`; the sequential binary partition (SBP) code of a tree; every SBP row has a non-empty `+` and `−` part. | Proved (ℕ, `Fin`). |
| **L1 exact algebra** | Balance contrasts over an arbitrary commutative ring, with arbitrary part weights (philr's `p`): each contrast is weighted-sum-zero; distinct contrasts are orthogonal under the weighted inner product; the norm of each contrast is `r·s·(r+s)`; the balance map is linear; under a stated cancellation hypothesis it has trivial kernel; it ignores constant shifts (= scale invariance after `log`). | Proved generically; instantiated at ℤ. |
| **L2 transcendental seam** | `log` turns products into sums (`LogHom` record); the normalisation `sqrt(rs/(r+s))` is a positive scalar per balance and so preserves orthogonality and kernel. | Assumed via named records; the consequences (perturbation ↦ translation, powering ↦ scaling) are proved *relative to* the record. |
| **L3 floating point** | The Julia implementation (`src/analysis/ilr_basis.jl`). | Not proved. Each L1 theorem has a named Julia property test at tolerance (§5), and cross-implementation fixtures against an independent port of R `philr`. |

The exact-vs-approximate distinction in `docs/statistics/numeric-contracts.md` is the
same line as L1/L3: an L1 theorem is a statement about exact arithmetic; the matching
L3 test is the claim that `Float64` stays within the stated tolerance of it.

### Why unnormalised contrasts in L1

The normalised philr/Egozcue contrast has entries `±c/n±` with `c = sqrt(n₊n₋/(n₊+n₋))`:
neither the division nor the square root exists in a general ring. Every structural
property (orthogonality, sum-zero, kernel, invariance) is invariant under multiplying
each contrast by a non-zero scalar, so L1 proves them for the **integer-valued**
contrast `(Σw₋)·𝟙₊ − (Σw₊)·𝟙₋` and records the scalar separately. Over a field of
characteristic 0 the normalised basis is this one scaled by `1/sqrt(r·s·(r+s))`, which is
where the Julia constant comes from (Key identity: `norm² = r·s·(r+s)`, proved).

## 3. Module map

```
proofs/agda/
  metamanifold-proofs.agda-lib      depend: standard-library; flags --safe --without-K
  MetaManifold/All.agda             imports everything (the CI entry point)
  MetaManifold/Composition/
    Tree.agda                       binary trees, leaves/internal counts, tip vectors
    Node.agda                       internal-node positions; preorder bijection with Fin
    Sum.agda                        weighted sums / inner product over a CommutativeRing
  MetaManifold/ILR/
    SBP.agda                        sign codes; each balance has a + and a − part
    Contrast.agda                   contrasts; sum-zero; orthogonality; norm identity
    Kernel.agda                     trivial kernel under a named cancellation hypothesis
    Invariance.agda                 linearity; shift (scale) invariance; LogHom seam
    Comb.agda                       the comb tree reproduces the Helmert default
    Integer.agda                    ℤ instance; uniform weights discharge the hypothesis;
                                    a counterexample showing the hypothesis is needed
  reject/                           files that MUST fail to type-check
scripts/check-proofs.sh             guard + type-check + expected-rejection check
```

### Shared foundation for issue #21

`MetaManifold.Composition.*` is deliberately prover-level *shared* vocabulary, not ILR
code. #21's modules (multiplicative replacement with δ, Bayesian-multiplicative) should
live under `MetaManifold.ZeroReplacement.*` and reuse `Composition.Sum` (weighted sums,
closure-as-sum) rather than redefining them. At the time of writing no #21 Agda file
exists on any branch of this repository; when one appears the first task is to reconcile
it with this namespace (merge definitions, keep one), and this section must be updated.
Natural #21 statements that compose with the ILR results:

- multiplicative replacement preserves the ratios of non-zero parts (so every ILR balance
  whose parts are all non-zero is unchanged by replacement) — this is the formal content
  of "replacement touches only the zero cells", and it composes directly with the
  shift-invariance theorem here;
- replacement output is strictly positive, which is the precondition of the L2 `log`.

## 4. Mapping the proof objects to the implementation

| Proof object | Julia | Notes |
|---|---|---|
| `Tree` (`leaf`, `node l r`) | `ILRBasis.PhyloTree` after validation | Julia refuses multifurcations and unrooted (trifurcating-root) trees instead of resolving them: the proof object *is* bifurcating, and silently resolving a polytomy would invent a hypothesis. |
| `code` (SBP of a tree) | `sbp_from_tree` | Row = balance, `+` = first child, `−` = second child (philr's `phylo2sbp` convention). |
| SBP validity | `validate_sbp` | Julia checks the Egozcue & Pawlowsky-Glahn (2005) conditions by reconstructing the tree; a matrix that reconstructs is exactly one in the image of `code`. |
| `contrast` / weights `w` | `balance_coefficients`, `part_weights` | Unnormalised in Agda, normalised in Julia by `1/sqrt(rs(r+s))`. |
| preorder `toFin` | balance order | Julia emits balances in preorder (root first), the same order as philr's node numbering. |
| `Comb` theorem | `helmert_balance_matrix` equivalence test | The comb tree's root contrast is Helmert's *last* balance, i.e. the order is reversed; the test maps indices explicitly. |

## 5. Theorem ↔ test traceability

Every L1 theorem has a Julia property test with the same name in its description
(`test/unit/test_ilr_basis.jl`). If a theorem is added, a test is added.

| Agda theorem | Julia test (tolerance) |
|---|---|
| `internal-count` | "D taxa give D-1 balances" (exact) |
| `code-has-plus`, `code-has-minus` | "every SBP row has a + and a - part" (exact) |
| `contrast-sum-zero` | "balances of a constant composition are zero" (1e-12) |
| `contrast-orthogonal` | "basis columns are orthonormal under part weights" (1e-12) |
| `contrast-norm` | "normalisation constant equals sqrt(rs/(r+s))" (1e-12) |
| `balance-kernel` | "distinct CLR vectors give distinct balances" (sampled; 1e-9) |
| `balance-shift-invariant` | "scaling a sample leaves balances unchanged" (1e-12) |
| `balance-linear` | "perturbation adds balance vectors" (1e-12) |
| `comb-is-helmert` | "comb tree reproduces the Helmert default" (1e-12) |
| `nondegeneracy-needs-hypothesis` (counterexample) | "signed part weights are refused" (exact) |

## 6. Residue — stated, not hidden

Not proved, by design, and listed so no one mistakes the suite's scope:

1. Properties of IEEE-754 `log`, `sqrt`, summation order (L3; covered by tolerance tests).
2. That `D − 1` orthogonal non-zero contrasts **span** the sum-zero hyperplane. Over a
   field this is dimension counting (`D − 1` independent vectors in a `D − 1`-dimensional
   space); stdlib 2.1 has no linear-algebra dimension theory, and building one to restate
   a textbook fact is poor value. The kernel theorem (injectivity) is the half the
   statistics depends on: no two distinct CLR vectors share balances.
3. Correctness of the Newick/CSV parsers (tested; parsers are not in scope for proof).
4. Hierarchical clustering optimality (the dendrogram basis is *defined* by the Lance–
   Williams recurrence; tests pin it to scipy and to hand-computed cases).
5. Statistical validity of any downstream test. Proofs here are about the transform.

## 7. When Lean would be justified

Recorded so the question is answered by criteria rather than taste. A Lean mirror is
justified if a *required* statement needs real analysis that Agda's stdlib cannot
express without building a real-number library, for example:

- concavity/uniqueness of the negative-binomial likelihood maximiser (#21 glmGamPoi);
- convergence or error bounds of an iterative estimator;
- measure-theoretic properties of a Bayesian-multiplicative posterior.

In that case: the Agda statement remains canonical where one exists; the Lean file says
which Agda theorem it mirrors; and CI builds both. Nothing in #20 meets the criterion.

## 8. CI

Job `proofs` in `.github/workflows/ci.yml`: Debian 13 container, `apt-get install
agda-bin=2.6.4.3-1+b2 agda-stdlib=2.1-4` (the estate pin), then
`scripts/check-proofs.sh`, which (a) runs the guard grep, (b) type-checks
`MetaManifold/All.agda`, (c) asserts every file in `reject/` fails. Locally the same
script runs with `AGDA=... AGDA_STDLIB=...` overrides.
