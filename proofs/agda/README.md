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
