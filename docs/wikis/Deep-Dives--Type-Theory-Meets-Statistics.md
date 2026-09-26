<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000042
parent: 0198ba50-0000-7000-8000-000000000040
position: 20
kind: page
tags:
  - theory
  - types
  - statistics
archived: false
-->

# Type theory meets statistics

**Status: IN PLACE as discipline and code shape.** This is the central
argument of layer 3: most statistical misconduct in pipelines is a *type
error* — a claim of one kind wearing the representation of another. The
fix is to make kinds of claim into kinds of value.

## The identification

Start from three observations a statistician and a type theorist would state
differently but agree on:

1. **A p-value and a count are not the same kind of thing.** A count is a
   fact about a sample (finite, exactable). A p-value is the tail mass of a
   reference distribution *under a model* — approximate by construction,
   meaningful only where the model's preconditions hold.
2. **"The fit did not converge" is a result.** It is information about the
   data/design combination. Pipelines that render it as `NA`, `0`, or a
   plausible-looking estimate have converted information into misinformation
   — a coercion between kinds that should not exist.
3. **Precision is not exactness.** A 4096-bit float is still an
   approximation of a real number. Treating `BigFloat` output as "exact" is
   a category error, not a rounding improvement.

In type-theoretic terms: these are **distinct types of claim**, and the
representations must not be silently coercible. The numeric policy
([Exact Arithmetic](Deep-Dives--Exact-Arithmetic)) makes (3) a runtime
discipline; the unsuccessful-state machinery
([Maximum Likelihood](Deep-Dives--Maximum-Likelihood)) makes (2) a return
type; the offset/transform distinction
([Compositional Statistics](Deep-Dives--Compositional-Statistics)) makes
(1)-adjacent confusions unrepresentable.

## The vocabulary, and where it comes from

The estate's epistemic layer is grounded in formal type theory — the Agda
lineages that `src/core/epistemic.jl` shadows executably (see
[Epistemic Status](Deep-Dives--Epistemic-Status) for the full mapping).
The terms that matter for statistics:

- **Σ-types (dependent pairs).** `EchoFiber` — Σ(x:A), (f x ≡ y) — is a
  value *together with evidence of how it arose*. A statistical result here
  is shaped the same way: a number plus its computation trace (method,
  policy mode, refusals avoided). The `avec_fibre` column ("with fibre") is
  this idea on the wire: a result carries the fibre of its derivation.
- **Identity types.** `f x ≡ y` is not boolean equality; it is *evidence
  that two things are the same*, which can be inspected. "This table equals
  what the config promised" is checked as evidence (freshness hashes,
  `run_config.yml`), not trusted.
- **Modalities and warrants (without soundness).** A `Warrant` is a
  *reason to believe* — κ-modality framed — explicitly **without** a
  soundness proof. This is exactly the epistemology of a p-value or a
  convergence check: grounds for a claim, not the claim's truth. The
  type theory refuses to let software pretend otherwise, and so does the
  statistics: BH-adjusted p-values are warrants for ranking features, not
  certificates of biological difference.
- **Admissible worlds.** `present_in_every_admissible_world` quantifies over
  candidate interpretations — a modal notion. Statistically this is
  robustness: a feature that "holds in every admissible world" survives the
  analysis choices that are genuinely open (zero policy, normalisation
  story). CladeCumulus colours by it, deliberately.

## Where TypeScript carries the same load

The frontend estate is not where Σ-types live, but it enforces the same
"no silent coercion" rule at the wire boundary:

- `unknown` + narrowing instead of `any` — a value from outside the type
  boundary must *earn* its type, with evidence (runtime checks), exactly
  like a warrant.
- `exactOptionalPropertyTypes` — "absent" and "present-but-undefined" are
  distinct, the same distinction that makes a refusal different from an
  empty result. This one option choice is why #31's rule ("unknown, never
  silently not-significant") is implementable in the UI without special
  cases.
- Category D/E closure — third-party types are audited like dependencies;
  the two `FIXME(types)` stubs are *declared* coercions (documented debt),
  not discovered ones.

## The payoff, concretely

| Statistical honesty rule | Type-theoretic shape | Enforced by |
|---|---|---|
| Never a placeholder as a result | no coercion `Stub → Estimate` | guard test (estimation suite) |
| Refusal is a result | sum type `Estimate ⊎ UnsuccessfulState` | `estimation.jl` returns, UI renders states |
| Floats never claim exactness | no coercion `Approximate → Exact` | `numeric_policy.jl` (`assert_mode`), boundary tests |
| Offsets ≠ transforms | distinct types, no implicit map | `scaling.jl` + conditions doc |
| Significance never silently degrades | `Unknown ⊎ NotSignificant ⊎ Significant` | analysis status plumbing |
| BH cannot be quietly disabled | the dangerous configuration is a *loud* type (DANGER banner + log) | AnalysisConfig validation |

None of this requires a dependently-typed host language — Julia and
TypeScript reach the same discipline by *convention made mechanical*
(validation at boundaries, sum-typed returns, guard tests). The Agda
lineages matter as the conceptual ground: the shadows in `epistemic.jl` are
executable glossary entries, keeping the vocabulary honest.

## Where it goes next

The advanced suite ([Advanced Functionality](Deep-Dives--Advanced-Functionality))
pushes the same identification further: exact tests are "results whose tail
mass is computed, not approximated"; multinomial regression is "effects
that live on the simplex, typed as such"; occupancy models are "absence as
a latent variable, not a zero". The symbolic engine (#2, blocked) is where
the identity types become load-bearing — proof-carrying formula
manipulation rather than string rewriting — which is precisely why it waits
for the numeric layer to earn its review (#1).
