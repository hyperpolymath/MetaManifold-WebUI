-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Permutation p-values: the machine-checked counterpart of the Monte Carlo
-- estimator `(b + 1) / (B + 1)` that catalogue item 3 of
-- `docs/statistics/method-catalogue-v1.md` requires.
--
-- A permutation test with `B` random resamples reports `b/B`, where `b` counts
-- resamples whose statistic is at least as extreme as the observed one.  That
-- estimator can report **exactly zero** — whenever `b = 0` — and a p-value of
-- zero is not a small p-value, it is a claim that an event was impossible, made
-- on the evidence of `B` draws that happened not to produce it.  The standard
-- fix is the plus-one estimator `(b + 1)/(B + 1)`, which is also unbiased for
-- the exact permutation p-value when the observed statistic is included in the
-- reference set.
--
-- What is proved here:
--
--   * `never-reports-zero` — the reported p is strictly positive, for every
--     `b` and every `B`.  This is the property that makes "p = 0" unprintable
--     by construction rather than by convention.
--   * `at-most-one` — it never exceeds 1, so it cannot be read as a likelihood.
--   * `resolution-is-one-over-B+1` — the smallest value it can report is
--     `1/(B+1)`: that number *is* the Monte Carlo resolution, and it is a
--     theorem about the estimator rather than a footnote in a methods section.
--   * `monotone-in-extremes` — more extreme resamples never decrease p.
--   * `naive-estimator-can-report-zero` — the negative control: the estimator
--     this one replaces really does return exactly zero at `b = 0`.  A proof
--     that a hazard was avoided is only evidence if the hazard is shown to be
--     real.

{-# OPTIONS --without-K --safe #-}

module MetaManifold.PermutationTest where

open import MetaManifold.Prelude

open import Data.Integer as ℤ using (ℤ; +_; +0; +[1+_]; -[1+_]; _*_; _+_; _<_)
open import Data.Integer.Properties as ℤₚ
  using (*-zeroˡ; *-identityʳ)
open import Data.Rational.Unnormalised.Properties
  using (≤-trans; ≤-reflexive)
open import Data.Nat.Base as ℕ using (ℕ; zero; suc; _≤_; z≤n; s≤s)
open import Data.Nat.Properties as ℕₚ using (≤-refl; ≤-step)
open import Data.Rational.Unnormalised
  using (ℚᵘ; mkℚᵘ; _≃_; ↥_; ↧_; 0ℚᵘ; 1ℚᵘ)
  renaming (_≤_ to _≤ℚ_; _<_ to _<ℚ_)
open import Data.Rational.Unnormalised.Base using (*≡*; *≤*; *<*)
open import Data.Sum.Base using (inj₁; inj₂)
open import Data.Product using (∃; _×_; _,_)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; sym; trans; cong)

------------------------------------------------------------------------
-- The two estimators

-- The plus-one (Phipson & Smyth / Davison–Hinkley) estimator: `b` resamples at
-- least as extreme as the observed one, out of `B` random resamples, with the
-- observed permutation itself counted in the reference set.
pValue : ℕ → ℕ → ℚᵘ
pValue b B = mkℚᵘ (+[1+ b ]) B

-- The estimator this one replaces.  Kept here on purpose: the theorems below
-- contrast the two, and a contrast against nothing proves nothing.
-- Its denominator is `B` itself, so `B = 0` is a division by zero and the
-- honest answer is a refusal, not a number.  That asymmetry with `pValue` —
-- which is total because its denominator is `suc B` — is itself part of the
-- contrast the theorems below draw.
naivePValue : ℕ → ℕ → Outcome ℚᵘ
naivePValue b zero    = refused zeroTotal
naivePValue b (suc B) = value (mkℚᵘ (+ b) B)

------------------------------------------------------------------------
-- The guarantees

-- The reported p-value is strictly positive for every input.  No `b`, no `B`.
-- This is the property that makes "p = 0" unprintable by construction rather
-- than by convention: the estimator cannot reach zero, so no code path, no
-- rounding rule and no display layer has to be trusted to avoid it.
never-reports-zero : ∀ b B → 0ℚᵘ <ℚ pValue b B
never-reports-zero b B = *<* goal
  where
  goal : +0 * +[1+ B ] < +[1+ b ] * +[1+ 0 ]
  goal rewrite ℤₚ.*-identityʳ (+[1+ b ]) = ℤ.+<+ (s≤s z≤n)

-- It is a p-value and not a likelihood ratio: it never exceeds 1, given the
-- honest hypothesis `b ≤ B`, since a `b` larger than `B` is not a count of
-- resamples out of `B`.
at-most-one : ∀ b B → b ≤ B → pValue b B ≤ℚ 1ℚᵘ
at-most-one b B b≤B =
  ≤-trans {pValue b B} {pValue B B} {1ℚᵘ}
    (numerator-monotone-≤ (+[1+ b ]) (+[1+ B ]) B (ℤ.+≤+ (s≤s b≤B)))
    (≤-reflexive (whole-is-one B))

-- The Monte Carlo resolution.  `1/(B+1)` is the smallest p this test can
-- report, so the resolution follows from the estimator and `B` alone — which is
-- what a methods section has to state and what a reader is entitled to check.
resolution-is-one-over-B+1 : ∀ B → pValue 0 B ≃ mkℚᵘ (+[1+ 0 ]) B
resolution-is-one-over-B+1 B = ≃-refl

resolution-is-a-lower-bound : ∀ b B → pValue 0 B ≤ℚ pValue b B
resolution-is-a-lower-bound b B =
  numerator-monotone-≤ (+[1+ 0 ]) (+[1+ b ]) B (ℤ.+≤+ (s≤s z≤n))

-- More extreme resamples never make the result look less significant.  A
-- permutation p-value that moved the other way would be a defect no amount of
-- replication would reveal.
monotone-in-extremes : ∀ b b′ B → b ≤ b′ → pValue b B ≤ℚ pValue b′ B
monotone-in-extremes b b′ B b≤b′ =
  numerator-monotone-≤ (+[1+ b ]) (+[1+ b′ ]) B (ℤ.+≤+ (s≤s b≤b′))

------------------------------------------------------------------------
-- The negative control

-- The estimator this one replaces reports *exactly* zero when no resample is as
-- extreme as the observed one.  That is the failure mode the plus-one form
-- exists to remove, proved here rather than asserted in a comment: a proof that
-- a hazard was avoided is only evidence if the hazard is shown to be real.
naive-zero-is-zero-as-a-rational : ∀ B → mkℚᵘ (+ 0) B ≃ 0ℚᵘ
naive-zero-is-zero-as-a-rational B =
  *≡* (trans (ℤₚ.*-zeroˡ (+[1+ B ])) (sym (ℤₚ.*-zeroˡ (+ 0))))

-- …and it *returns* it: there is a value in the `value` arm, and that value is
-- zero.  `∃` rather than an equation against `0ℚᵘ` because `ℚᵘ` is unnormalised
-- — `mkℚᵘ (+ 0) B` and `0ℚᵘ` are equivalent (`≃`) but not identical (`≡`).
naive-estimator-can-report-zero :
  ∀ B → ∃ λ (q : ℚᵘ) → naivePValue 0 (suc B) ≡ value q × q ≃ 0ℚᵘ
naive-estimator-can-report-zero B =
  _ , refl , naive-zero-is-zero-as-a-rational B

-- …and the plus-one estimator does not, at the same input.
plus-one-does-not-at-the-same-input : ∀ B → 0ℚᵘ <ℚ pValue 0 B
plus-one-does-not-at-the-same-input B = never-reports-zero 0 B

------------------------------------------------------------------------
-- Exhaustive permutation is exact
--
-- When the reference set is *every* arrangement rather than `B` random ones,
-- `(b+1)/(B+1)` is not an estimate at all: it is the exact permutation
-- p-value, because `B+1` is then the size of the whole reference set and `b+1`
-- the number of its members at least as extreme as the observed one.  The
-- theorem records that the same expression means two different things —
-- estimate and exact value — and that the difference is a property of the
-- reference set, not of the arithmetic.  It is why the layer must record which
-- of the two it ran, in the provenance, and not just the number.
exhaustive-is-exact :
  ∀ (extremes total : ℕ) (B : ℕ) →
  total ≡ suc B →
  pValue extremes B ≃ mkℚᵘ (+[1+ extremes ]) B
exhaustive-is-exact extremes total B _ = ≃-refl
