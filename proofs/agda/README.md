<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Agda proofs

Machine-checked statements about MetaManifold's compositional transforms.
Scope, layering, the theorem-to-test map and what is deliberately **not**
proved: [`docs/formal/verification-plan.md`](../../docs/formal/verification-plan.md);
for the evidence library (issue #7):
[`docs/formal/evidence-verification.md`](../../docs/formal/evidence-verification.md).

```sh
just proofs            # or: scripts/check-proofs.sh
# with a non-system toolchain:
AGDA=/path/to/agda AGDA_STDLIB_LIB=/path/to/standard-library.agda-lib scripts/check-proofs.sh
```

The `Evidence.*` modules are deliberately **stdlib-free** (only `Agda.Builtin.*`), so they
check under any Agda ≥ 2.6.4.3 even where the stdlib is unavailable; the rest of the
suite uses the stdlib. Golden vectors pinning the signed model across implementations:
[`proofs/vectors/evidence_vectors.json`](../vectors/evidence_vectors.json).

Toolchain: Agda 2.6.4.3, agda-stdlib 2.1 (the estate pin). Every module is
`--safe --without-K`; there are no postulates. Assumptions that cannot be proved
in exact arithmetic (`log` turns products into sums; `1/sqrt` exists) are record
arguments (`LogHom`, `Normaliser`) so each theorem that relies on one says so in
its type.

| Module | Content |
|---|---|
| `Composition.Tree` | rooted binary trees, tip vectors, D tips ⇒ D−1 internal nodes, comb tree |
| `Composition.Node` | balance positions; preorder numbering is a bijection with `Fin (D−1)` |
| `Composition.Sum` | weighted sums / inner product over any commutative ring (shared with #21) |
| `ILR.SBP` | SBP rows of a tree; non-empty ± parts; nesting (Egozcue & Pawlowsky-Glahn 2005) |
| `ILR.Contrast` | contrasts from masses and SBP row; centred; orthogonal; norm² = r·s·(r+s) |
| `ILR.Kernel` | trivial kernel / injectivity on centred vectors, under `Cancellable` |
| `ILR.Invariance` | linearity; constant-shift and sample-scale invariance (via `LogHom`) |
| `ILR.Orthonormal` | normalised basis orthonormal (via `Normaliser`) |
| `ILR.Comb` | comb tree under uniform weights = MetaManifold's Helmert default |
| `ILR.Integer` | ℤ instance; positive weights ⇒ `Cancellable`; counterexample for signed weights; philr known answer |
| `Evidence.Residual` | abstract evidence semantics: `Candidate` fibres, `Case`, `Holds`, `Identified`; actual-world honesty; no-free-weakening countermodel (issue #7) |
| `Evidence.Echo` | fibre semantics for artefacts: `Echo` = preimage fibre, `AvecFibre`, `sans-fibre`, total-space factorisation |
| `Evidence.Warrant` | warrant tokens: `Warrant`/`Epi`/`SoundWarrant`; `epi-does-not-give` (a token is not truth) |
| `Evidence.Signed` | the signed finite model (`signed-integer-v1`) as offsets on ℕ; enumeration proved sound + complete |
| `Evidence.Decision` | presence/identification verdicts computed **and** proved correct; the five reference presets as computed, proved terms |
| `reject/` | must **fail** to type-check, each for the reason in its `-- EXPECT:` line |


## The three issue-#21 modules

`ZeroReplacement.agda`, `NoRigidReplacement.agda` and `DispersionShrinkage.agda` are the laws
of the zero-replacement operators and the dispersion shrinkage step added by issue #21. They
are **flat modules, checked standalone**, and are deliberately not yet part of the
`MetaManifold/` suite above: folding them in needs a module namespace, the suite's
`{-# OPTIONS --safe --without-K #-}` header, an `All.agda` entry and a run of the guard, and
that work should be done with Agda in hand rather than blind. Until then:

```sh
# either a library-file setup naming agda-stdlib 2.1.1 …
agda --safe proofs/agda/ZeroReplacement.agda
# … or an explicit include path
agda --no-libraries -i /path/to/agda-stdlib-2.1.1/src -i proofs/agda --safe \
     proofs/agda/DispersionShrinkage.agda
```

`1/2` is not in scope from `Data.Rational` (it needs `Data.Rational.Literals`), which is why
these modules write `0ℚ` and `1ℚ` rather than numeric literals.

| Module | Proves |
| --- | --- |
| `ZeroReplacement.agda` | the sample total is preserved; every observed part is scaled by one common factor, so the ratios among observed parts are unchanged; an inserted value is positive and below its detection limit |
| `NoRigidReplacement.agda` | no rule determined by the observed data can be faithful — two worlds with the same observation and different masked values are one fibre, so any rule is wrong in one of them. This is the theorem behind the provenance's *all replacement is biased* |
| `DispersionShrinkage.agda` | the shrunken estimate lies between the prior and the sample estimate, moves toward whichever it is nearer, is exact when the prior *is* the sample estimate, and the quasi-likelihood numerator moves with the dispersion |

**Not proved, deliberately**: the estimator that produces the inputs (Cox-Reid loop, spline
trend, Nelder-Mead), that the Julia code is the term the proofs are about (there is no
extraction here; the link is the runtime invariants and
`test/unit/test_zero_replacement.jl` and
`test/unit/test_dispersion.jl`), the pseudocount ratio defect as a general statement (needs a
cancellation lemma the pinned stdlib does not expose for propositional equality; the unit
tests show it on values instead), and anything about `log` at zero (stdlib has no logarithm
on `ℚ`). **Falsification**: change the operator's scale factor from `1 − Δ` to `1 − 2Δ` and
`total-preserving` stops type-checking; claim unbiased recovery and `no-faithful-rule`
contradicts the claim; shrink past the prior and `shrinkage-not-above-prior` fails.
