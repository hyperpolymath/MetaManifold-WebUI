------------------------------------------------------------------------
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- The stated laws of the dispersion shrinkage step, machine-checked.
--
-- `overdispersion_shrinkage` in glmGamPoi — and `Dispersion.estimate_dispersions` in this
-- repository — forms, for every feature,
--
--     var_post = (df0 * var0 + df * s2) / (df0 + df)
--
-- with `s2` the raw (or quasi-likelihood) dispersion estimate, `df` its degrees of freedom,
-- and `(var0, df0)` the inverse-chisquare prior fitted by maximum likelihood. The same step
-- forms the quasi-likelihood dispersion `ql = (1 + m * disp) / (1 + m * trend)` with `m` the
-- feature mean.
--
-- What is proved here is the part of those two lines a user relies on when reading the
-- numbers: the shrunken estimate stays between the prior and the sample estimate and is a
-- shrinking correction toward the prior (exact when the prior is the sample estimate), and the
-- quasi-likelihood numerator moves in the direction of `disp` relative to the trend.
--
-- Stated cross-multiplied, and that is deliberate. `(df0 * var0 + df * s2) / (df0 + df) ≤ s2`
-- and `df0 * var0 + df * s2 ≤ (df0 + df) * s2` are equivalent when `0 < df0 + df`, which
-- `denominator-positive` proves from the weights. The development keeps the statement in the
-- cross-multiplied form so that it does not depend on reciprocals; the quotient form the code
-- writes follows by multiplying the proved inequality by the positive reciprocal.
--
-- What is deliberately NOT here: the estimator that *produces* `s2`, `df`, `var0`, `df0` — the
-- Cox-Reid adjusted maximum-likelihood loop, the log-determinant term, the dnorm-weighted
-- median trend, the natural spline in the abundance trend, and the Nelder-Mead fit of the
-- inverse-chisquare hyper-parameters. Those are computational, their properties are numerical,
-- and the honest place for them is the residue list in proofs/agda/README.md together with the
-- parity tests that compare the port against the reference on data. Proving here that the
-- shrinkage has the shape it claims is not a claim that the estimate is the right one.
--
-- Checked with Agda 2.7.0.1 and agda-stdlib 2.1.1, `--safe`, no postulates.
------------------------------------------------------------------------

{-# OPTIONS --cubical-compatible --safe #-}

module DispersionShrinkage where

open import Data.Rational.Base using (ℚ; 0ℚ; 1ℚ; _+_; _*_; _≤_; _<_; positive; nonNegative)
open import Data.Rational.Properties using
  ( *-distribʳ-+; *-monoˡ-≤-nonNeg; *-comm; *-assoc
  ; +-assoc; +-comm; +-identityˡ; +-identityʳ; +-mono-≤; +-monoˡ-<
  ; ≤-refl; ≤-trans; <-≤-trans; <⇒≤
  )
open import Relation.Binary.PropositionalEquality using
  (_≡_; refl; sym; trans; cong; subst; module ≡-Reasoning)

------------------------------------------------------------------------
-- The two weights
------------------------------------------------------------------------

-- The numerator of the shrunken estimate, as the code computes it.
numerator : ℚ → ℚ → ℚ → ℚ → ℚ
numerator df0 df var0 s2 = df0 * var0 + df * s2

--- The denominator: the two weights.
denominator : ℚ → ℚ → ℚ
denominator df0 df = df0 + df

denominator-nonNegative : ∀ df0 df → 0ℚ ≤ df0 → 0ℚ ≤ df → 0ℚ ≤ denominator df0 df
denominator-nonNegative df0 df 0≤df0 0≤df =
  subst (λ z → z ≤ denominator df0 df) (sym (+-identityʳ 0ℚ))
        (+-mono-≤ 0≤df0 0≤df)

denominator-positive : ∀ df0 df → 0ℚ < df0 → 0ℚ < df → 0ℚ < denominator df0 df
denominator-positive df0 df 0<df0 0<df =
  <-≤-trans 0<df
    (subst (λ z → z ≤ denominator df0 df) (+-identityˡ df)
           (+-mono-≤ (<⇒≤ 0<df0) (≤-refl {df})))

------------------------------------------------------------------------
-- Shrinkage is a pull toward the prior, and nothing else
------------------------------------------------------------------------

-- When the feature's own dispersion is below the prior variance, the shrunken estimate is
-- below it too (cross-multiplied): the correction pulls down, and it cannot overshoot the
-- sample value.
shrinkage-pulls-down :
  ∀ df0 df var0 s2 → 0ℚ ≤ df0 → var0 ≤ s2 →
  numerator df0 df var0 s2 ≤ denominator df0 df * s2
shrinkage-pulls-down df0 df var0 s2 0≤df0 var0≤s2 =
  subst (λ z → numerator df0 df var0 s2 ≤ z) (sym (*-distribʳ-+ s2 df0 df))
        (+-mono-≤ (*-monoˡ-≤-nonNeg df0 {{nonNegative 0≤df0}} var0≤s2)
                  (≤-refl {df * s2}))

-- The mirror image, for a feature whose own dispersion is *above* the prior variance: the
-- correction pulls up toward the prior, and it cannot pass it.
shrinkage-pulls-up :
  ∀ df0 df var0 s2 → 0ℚ ≤ df0 → s2 ≤ var0 →
  denominator df0 df * s2 ≤ numerator df0 df var0 s2
shrinkage-pulls-up df0 df var0 s2 0≤df0 s2≤var0 =
  subst (λ z → z ≤ numerator df0 df var0 s2) (sym (*-distribʳ-+ s2 df0 df))
        (+-mono-≤ (*-monoˡ-≤-nonNeg df0 {{nonNegative 0≤df0}} s2≤var0)
                  (≤-refl {df * s2}))

shrinkage-not-above-prior :
  ∀ df0 df var0 s2 → 0ℚ ≤ df → s2 ≤ var0 →
  numerator df0 df var0 s2 ≤ denominator df0 df * var0
shrinkage-not-above-prior df0 df var0 s2 0≤df s2≤var0 =
  subst (λ z → numerator df0 df var0 s2 ≤ z) (sym (*-distribʳ-+ var0 df0 df))
        (+-mono-≤ (≤-refl {df0 * var0})
                  (*-monoˡ-≤-nonNeg df {{nonNegative 0≤df}} s2≤var0))

-- No correction is applied when the prior says what the data says: the shrunken estimate is
-- the sample estimate, whatever the weights are. This is the sense in which the prior is a
-- prior and not a bias toward a number someone chose.
shrinkage-exact-when-prior-is-sample :
  ∀ df0 df var0 s2 → var0 ≡ s2 → numerator df0 df var0 s2 ≡ denominator df0 df * s2
shrinkage-exact-when-prior-is-sample df0 df var0 s2 var0≡s2 =
  begin
    df0 * var0 + df * s2
      ≡⟨ cong (λ z → df0 * z + df * s2) var0≡s2 ⟩
    df0 * s2 + df * s2
      ≡⟨ sym (*-distribʳ-+ s2 df0 df) ⟩
    denominator df0 df * s2
  ∎
  where
  open ≡-Reasoning

------------------------------------------------------------------------
-- The quasi-likelihood ratio moves with the dispersion
------------------------------------------------------------------------

-- `ql = (1 + m * disp) / (1 + m * trend)`. For a non-negative mean, the numerator compares to
-- `1 * (1 + m * trend) = 1 + m * trend` exactly as `disp` compares to `trend` — so a
-- quasi-likelihood dispersion above one is the statement "this feature is more dispersed than
-- the trend", with no other way to read it.
ql-numerator-mono :
  ∀ m disp trend → 0ℚ ≤ m → disp ≤ trend →
  1ℚ + m * disp ≤ 1ℚ + m * trend
ql-numerator-mono m disp trend 0≤m disp≤trend =
  +-mono-≤ (≤-refl {1ℚ}) (*-monoˡ-≤-nonNeg m {{nonNegative 0≤m}} disp≤trend)

-- The same in the direction a reader of a volcano plot needs: a feature whose dispersion is
-- above the trend has a quasi-likelihood numerator above one.
ql-numerator-above-one :
  ∀ m disp trend → 0ℚ ≤ m → trend ≤ disp →
  1ℚ + m * trend ≤ 1ℚ + m * disp
ql-numerator-above-one m disp trend 0≤m trend≤disp =
  +-mono-≤ (≤-refl {1ℚ}) (*-monoˡ-≤-nonNeg m {{nonNegative 0≤m}} trend≤disp)
