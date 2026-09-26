------------------------------------------------------------------------
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Machine-checked laws of the zero-replacement operators of issue #21.
--
-- What is proved here is the part of the two operators (multiplicative replacement,
-- Martín-Fernández et al. 2003, and Bayesian multiplicative replacement, Martín-Fernández
-- et al. 2015 — both as implemented in `src/analysis/zero_replacement.jl`) that does not
-- depend on the values a prior happens to produce:
--
--   1. the sample total is preserved (total-preserving);
--   2. every observed part is scaled by one common factor, so the ratios among observed
--      parts are unchanged (cross-ratios-preserved, ratios-preserved);
--   3. an inserted value is strictly positive (imputation-positive) and strictly below the
--      detection limit it was derived from (imputation-below-limit).
--
-- Encoding, stated plainly so that nothing is claimed that was not proved. A sample is
-- represented by what the laws depend on: the observed values, and the detection limits of
-- the parts that were zero. The zeros themselves contribute 0 to the original total, so the
-- original total of the sample is `sum observed`; the replaced table is
-- `scale (1 - Δ) observed` together with the inserted values `map (δ *_) limits`. The
-- hypothesis `Δ * sum observed ≡ sum (map (δ *_) limits)` is the implementation's condition
-- `Δ = (imputed mass) / (sample total)` in division-free form, and it is exactly the
-- condition the Julia code refuses when it fails (Δ ≥ 1 is refused at run time, so no law
-- here assumes Δ < 1: preservation holds for every Δ that the operator accepts).
--
-- What is deliberately NOT here, and why:
--
--   * the numbers the policies choose (δ's default 0.65, the GBM posterior mean and its
--     concentration estimate) are modelling choices, not algebra. What is proved is that
--     whatever numbers are inserted, the laws above hold, because both policies are
--     instances of them.
--   * that the pseudocount policy moves the ratios of observed parts is checked numerically
--     by the unit tests (test/unit/test_zero_replacement.jl) and stated in the docs; the
--     general algebraic statement needs a cancellation lemma for ℚ that the standard
--     library at the pinned revision does not expose for propositional equality, and this
--     development does not postulate one.
--   * the CLR/ILR transforms and the non-totality of `log` at zero are not formalised (the
--     standard library has no logarithm on ℚ). The reason replacement is *mandatory* there
--     is argued in docs/statistics/zero-handling.md.
--
-- The impossibility statement that no data-determined rule can recover the lost zeros is
-- proved in proofs/agda/NoRigidReplacement.agda, which is what makes the "every replacement
-- is biased" warning in the Julia provenance a theorem rather than a slogan.
------------------------------------------------------------------------
module ZeroReplacement where

open import Data.List using (List; []; _∷_; map)
open import Data.Rational using (ℚ; _+_; _*_; _<_)
open import Data.Rational.Base using (0ℚ; 1ℚ; _-_; -_; positive)
open import Data.Rational.Properties using
  ( *-assoc; *-comm; *-identityˡ; *-identityʳ; *-zeroʳ
  ; *-distribˡ-+; *-distribʳ-+
  ; +-assoc; +-identityʳ; +-inverseˡ
  ; *-monoʳ-<-pos
  )
open import Relation.Binary.PropositionalEquality using
  (_≡_; refl; sym; trans; cong; cong₂; subst; module ≡-Reasoning)
open ≡-Reasoning

------------------------------------------------------------------------
-- Sample totals
------------------------------------------------------------------------

-- The total of a list of values. The observed values of a sample are such a list; the
-- zeros of the sample contribute 0ℚ and are represented by the detection limits carried in
-- a second list instead.
sum : List ℚ → ℚ
sum []       = 0ℚ
sum (x ∷ xs) = x + sum xs

-- Scaling every value of a list by one common factor — the operation the policies apply to
-- the observed parts of a sample.
scale : ℚ → List ℚ → List ℚ
scale s = map (s *_)

sum-scale : ∀ s xs → sum (scale s xs) ≡ s * sum xs
sum-scale s []       = sym (*-zeroʳ s)
sum-scale s (x ∷ xs) =
  begin
    s * x + sum (scale s xs) ≡⟨ cong (s * x +_) (sum-scale s xs) ⟩
    s * x + s * sum xs       ≡⟨ sym (*-distribˡ-+ s x (sum xs)) ⟩
    s * (x + sum xs)         ∎

------------------------------------------------------------------------
-- 1. The weighted parts sum back to the sample total
------------------------------------------------------------------------

-- `1 - Δ + Δ ≡ 1`, the arithmetic step of total preservation.
1-Δ+Δ≡1 : ∀ Δ → (1ℚ - Δ) + Δ ≡ 1ℚ
1-Δ+Δ≡1 Δ =
  begin
    (1ℚ + (- Δ)) + Δ ≡⟨ +-assoc 1ℚ (- Δ) Δ ⟩
    1ℚ + ((- Δ) + Δ) ≡⟨ cong (1ℚ +_) (+-inverseˡ Δ) ⟩
    1ℚ + 0ℚ          ≡⟨ +-identityʳ 1ℚ ⟩
    1ℚ               ∎

-- The scaled observed parts plus the inserted values are the original sample total, whenever
-- Δ is the fraction of the total that the inserted values carry. This is the law the runtime
-- invariant `Σ x̃ = Σ x` asserts on every call and the unit tests assert on fixtures: the
-- replacement changes the shape of the sample, never its depth.
total-preserving :
  ∀ (δ Δ : ℚ) (observed limits : List ℚ) →
  Δ * sum observed ≡ sum (map (δ *_) limits) →
  sum (scale (1ℚ - Δ) observed) + sum (map (δ *_) limits) ≡ sum observed
total-preserving δ Δ observed limits Δ-is-mass =
  begin
    sum (scale (1ℚ - Δ) observed) + sum (map (δ *_) limits)
      ≡⟨ cong₂ _+_ (sum-scale (1ℚ - Δ) observed) (sum-scale δ limits) ⟩
    (1ℚ - Δ) * sum observed + δ * sum limits
      ≡⟨ cong ((1ℚ - Δ) * sum observed +_) imputed-in-scale ⟩
    (1ℚ - Δ) * sum observed + Δ * sum observed
      ≡⟨ sym (*-distribʳ-+ (sum observed) (1ℚ - Δ) Δ) ⟩
    ((1ℚ - Δ) + Δ) * sum observed
      ≡⟨ cong (_* sum observed) (1-Δ+Δ≡1 Δ) ⟩
    1ℚ * sum observed
      ≡⟨ *-identityˡ (sum observed) ⟩
    sum observed
      ∎
  where
    -- The same hypothesis, with the inserted values summed in the scale of the sample.
    imputed-in-scale : δ * sum limits ≡ Δ * sum observed
    imputed-in-scale = trans (sym (sum-scale δ limits)) (sym Δ-is-mass)

------------------------------------------------------------------------
-- 2. One common factor, so the ratios among observed parts are unchanged
------------------------------------------------------------------------

-- Cross-multiplied form: for any two observed parts, scaling both by the same factor leaves
-- the cross products equal. Written this way there is no division and no side condition, and
-- it is exactly the statement `x̃_i / x̃_j = x_i / x_j` whenever the division is defined.
cross-ratios-preserved : ∀ s x y → (s * x) * y ≡ (s * y) * x
cross-ratios-preserved s x y =
  begin
    (s * x) * y ≡⟨ *-assoc s x y ⟩
    s * (x * y) ≡⟨ cong (s *_) (*-comm x y) ⟩
    s * (y * x) ≡⟨ sym (*-assoc s y x) ⟩
    (s * y) * x ∎

-- Witness form: if `q` witnesses the ratio between two observed parts before replacement,
-- the same `q` witnesses the ratio between them after. This is the property pseudocounts do
-- not have, and the reason the issue asks for these policies.
ratios-preserved : ∀ s q x y → x ≡ q * y → s * x ≡ q * (s * y)
ratios-preserved s q x y x≡qy =
  begin
    s * x       ≡⟨ cong (s *_) x≡qy ⟩
    s * (q * y) ≡⟨ sym (*-assoc s q y) ⟩
    (s * q) * y ≡⟨ cong (_* y) (*-comm s q) ⟩
    (q * s) * y ≡⟨ *-assoc q s y ⟩
    q * (s * y) ∎

------------------------------------------------------------------------
-- 3. What is inserted stays small and positive
------------------------------------------------------------------------

-- A positive fraction of a positive detection limit is strictly positive: a replaced zero
-- is never reported as an absent or negative part.
imputation-positive : ∀ δ dl → 0ℚ < δ → 0ℚ < dl → 0ℚ < δ * dl
imputation-positive δ dl 0<δ 0<dl =
  subst (λ z → z < δ * dl) (*-zeroʳ δ)
        (*-monoʳ-<-pos δ {{positive 0<δ}} 0<dl)

-- With δ < 1 the inserted value is strictly below the detection limit it was derived from:
-- the replaced zero stays below the smallest value the part was ever seen at, which is the
-- ordering the multiplicative policy promises and the tests assert.
imputation-below-limit : ∀ δ dl → δ < 1ℚ → 0ℚ < dl → δ * dl < dl
imputation-below-limit δ dl δ<1 0<dl =
  subst (λ z → δ * dl < z) (*-identityʳ dl)
        (subst (λ z → z < dl * 1ℚ) (*-comm dl δ)
               (*-monoʳ-<-pos dl {{positive 0<dl}} δ<1))
