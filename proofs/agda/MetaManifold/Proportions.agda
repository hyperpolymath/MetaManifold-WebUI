-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Exact proportions: the machine-checked counterpart of
-- `src/analysis/numeric_policy.jl` (`exact_fraction`, `exact_relative_abundance`)
-- and `src/analysis/exact_summaries.jl`.
--
-- The headline result is `proportions-sum-to-one`: the exact relative abundances
-- of one sample sum to *exactly* one, as a rational value, with no rounding
-- anywhere in the chain.  That is a property compositional analysis quietly
-- assumes and almost never checks; here it is a theorem, and a theorem about
-- *values*, so it transfers to `Rational{BigInt}` and not only to the
-- unnormalised model used to prove it.
--
-- The second group of results is about refusals.  A sample with no reads has no
-- composition, so `exact_relative_abundance` returns `nothing` rather than `0`.
-- `zero-total-is-refused` pins that, and `value-is-the-quotient` pins the
-- converse: whenever this layer does hand back a number, that number is the
-- quotient it claims to be.

{-# OPTIONS --without-K --safe #-}

module MetaManifold.Proportions where

open import MetaManifold.Prelude

open import Data.Empty using (⊥; ⊥-elim)
open import Data.Integer using (ℤ; +_; +0; +[1+_]; _*_; _+_)
open import Data.Integer.Properties as ℤₚ using (pos-+)
open import Data.List.Base as List using (List; []; _∷_; map)
open import Data.Nat.Base as ℕ using (ℕ; zero; suc)
open import Data.Nat.Properties as ℕₚ using (_≤?_; <-irrefl; ≤-trans)
open import Data.Product using (∃; _×_; _,_)
open import Data.Rational.Unnormalised
  using (ℚᵘ; mkℚᵘ; _≃_; ↥_; ↧_; 0ℚᵘ; 1ℚᵘ)
  renaming (_+_ to _+ℚ_)
open import Data.Vec.Base as Vec using (Vec; []; _∷_)
open import Relation.Nullary.Decidable using (yes; no)
open import Relation.Binary.PropositionalEquality
  using (_≡_; _≢_; refl; sym; trans; cong)

------------------------------------------------------------------------
-- The operation itself
--
-- `relativeAbundance c t` is `c/t` exactly, or a named refusal.  The refusals
-- are checked in the order the Julia layer checks them, so the reason a caller
-- sees here is the reason the Julia layer would give.

relativeAbundance : ℕ → ℕ → Outcome ℚᵘ
relativeAbundance c zero with c ℕₚ.≤? zero
... | no  _ = refused countExceedsTotal
... | yes _ = refused zeroTotal
relativeAbundance c (suc m) with c ℕₚ.≤? suc m
... | no  _ = refused countExceedsTotal
... | yes _ = value (+ c /[ suc m ] (λ ()))

-- The exact relative abundance of every feature of a sample, given the
-- denominator (depth − 1, in ℚᵘ's encoding).  Every entry shares one
-- denominator, which is what makes `proportions-sum-to-one` a one-step
-- consequence of `sumVec-over-common-denominator`.
abundances : ∀ {n} → Vec ℕ n → ℕ → Vec ℚᵘ n
abundances cs m = over-denominator (Vec.map +_ cs) m

------------------------------------------------------------------------
-- The refusals are what they say they are

-- A sample of zero reads has no composition.  `nothing`, not `0`: a proportion
-- of zero claims the feature is absent from a sample that was sequenced, which
-- a sample that was not sequenced cannot support.
zero-total-is-refused : relativeAbundance 0 zero ≡ refused zeroTotal
zero-total-is-refused = refl

-- A sample with no reads, asked about a feature that claims reads, is refused
-- for the *count* reason and not the total one, because
-- `exact_relative_abundance` checks `count <= total` before `iszero(total)`.
-- The order is not arbitrary: the two reasons tell a user different things
-- about which of the two numbers is wrong, and this theorem pins the order
-- rather than leaving it to a reader of the source.
zero-total-with-count-is-refused-as-exceeding :
  ∀ c → relativeAbundance (suc c) zero ≡ refused countExceedsTotal
zero-total-with-count-is-refused-as-exceeding c = refl

-- A count larger than its own total is not a count of that table.  Refused
-- rather than clamped, because clamping would silently invent a composition
-- that sums to one.
count-exceeds-total-is-refused :
  ∀ c t → suc t ℕ.≤ c → relativeAbundance c t ≡ refused countExceedsTotal
count-exceeds-total-is-refused c zero t<c with c ℕₚ.≤? zero
... | no  _   = refl
... | yes c≤0 = ⊥-elim (ℕₚ.<-irrefl refl (ℕₚ.≤-trans t<c c≤0))
count-exceeds-total-is-refused c (suc m) t<c with c ℕₚ.≤? suc m
... | no  _   = refl
... | yes c≤t = ⊥-elim (ℕₚ.<-irrefl refl (ℕₚ.≤-trans t<c c≤t))

-- Whenever a value does come back it is the quotient it claims to be, over a
-- denominator that is the sample's own depth.  This is the formal content of
-- "no silent downgrade": there is no input for which this layer returns a
-- number that is not `count / total`.
refused-not-value : ∀ {A} {r : Refusal} {a : A} → refused r ≡ value a → ⊥
refused-not-value p = refused≢value (sym p)

value-is-the-quotient :
  ∀ c t q → relativeAbundance c t ≡ value q →
  ∃ λ (m : ℕ) → (t ≡ suc m) × (q ≃ mkℚᵘ (+ c) m)
value-is-the-quotient c zero q p with c ℕₚ.≤? zero
... | no  _ = ⊥-elim (refused-not-value p)
... | yes _ = ⊥-elim (refused-not-value p)
value-is-the-quotient c (suc m) q p with c ℕₚ.≤? suc m
... | no  _ = ⊥-elim (refused-not-value p)
... | yes _ = m , refl , ≡⇒≃ (sym (value-injective p))

-- A produced value always has a denominator that is not zero.  In `ℚᵘ` this is
-- true by construction; stating it makes the property available to callers, and
-- it is exactly what the Julia layer has to *establish* at runtime because
-- `Rational{BigInt}` will build `1//0` on request.
value-has-nonzero-denominator :
  ∀ c t q → relativeAbundance c t ≡ value q → ↧ q ≢ +0
value-has-nonzero-denominator c zero q p with c ℕₚ.≤? zero
... | no  _ = ⊥-elim (refused-not-value p)
... | yes _ = ⊥-elim (refused-not-value p)
value-has-nonzero-denominator c (suc m) q p with c ℕₚ.≤? suc m
... | no  _ = ⊥-elim (refused-not-value p)
... | yes _ = λ ()

------------------------------------------------------------------------
-- The headline theorem

-- The exact relative abundances of one sample sum to exactly one.
--
-- Read the hypotheses, because they carry the whole scientific content: the
-- counts are ℕ (non-negative integers, not floats) and the sample's own counts
-- add up to its depth.  Under those two facts Σᵢ cᵢ/depth is *exactly* 1ℚᵘ —
-- not 0.9999999999, not 1.0 after rounding, 1.  No rounding rule, no precision
-- setting and no float appears in the statement or in the proof.
proportions-sum-to-one :
  ∀ {n} (cs : Vec ℕ n) (m : ℕ) →
  sumVecℕ cs ≡ suc m →
  sumVecℚᵘ (abundances cs m) ≃ 1ℚᵘ
proportions-sum-to-one cs m tot =
  ≃-trans {sumVecℚᵘ (abundances cs m)} {mkℚᵘ (+[1+ m ]) m} {1ℚᵘ}
    (≃-trans {sumVecℚᵘ (abundances cs m)}
             {mkℚᵘ (sumVecℤ (Vec.map +_ cs)) m}
             {mkℚᵘ (+[1+ m ]) m}
      (sumVec-over-common-denominator (Vec.map +_ cs) m)
      (≡⇒≃ (cong (λ s → mkℚᵘ s m)
             (trans (sumVecℕ-map-+ cs) (cong +_ tot)))))
    (whole-is-one m)

-- The same fact for a sample held as a list, which is the shape that arrives
-- from a CSV or a DuckDB query before it becomes a vector.
abundances-list : List ℕ → ℕ → List ℚᵘ
abundances-list []       m = []
abundances-list (c ∷ cs) m = mkℚᵘ (+ c) m ∷ abundances-list cs m

sum-abundances-list : ∀ (cs : List ℕ) (m : ℕ) →
                      sumℚᵘ (abundances-list cs m) ≃ mkℚᵘ (+ sumℕ cs) m
sum-abundances-list []       m = ≃-sym (zero-over m)
sum-abundances-list (c ∷ cs) m =
  ≃-trans {mkℚᵘ (+ c) m +ℚ sumℚᵘ (abundances-list cs m)}
          {mkℚᵘ (+ c) m +ℚ mkℚᵘ (+ sumℕ cs) m}
          {mkℚᵘ (+ (c ℕ.+ sumℕ cs)) m}
    (+-cong-≃ʳ {sumℚᵘ (abundances-list cs m)} {mkℚᵘ (+ sumℕ cs) m} {mkℚᵘ (+ c) m}
       (sum-abundances-list cs m))
    (common-denominator-+ (+ c) (+ sumℕ cs) m)

proportions-sum-to-one-list :
  ∀ (cs : List ℕ) (m : ℕ) →
  sumℕ cs ≡ suc m →
  sumℚᵘ (abundances-list cs m) ≃ 1ℚᵘ
proportions-sum-to-one-list cs m tot =
  ≃-trans {sumℚᵘ (abundances-list cs m)} {mkℚᵘ (+[1+ m ]) m} {1ℚᵘ}
    (≃-trans {sumℚᵘ (abundances-list cs m)}
             {mkℚᵘ (+ sumℕ cs) m}
             {mkℚᵘ (+[1+ m ]) m}
      (sum-abundances-list cs m)
      (≡⇒≃ {mkℚᵘ (+ sumℕ cs) m} {mkℚᵘ (+[1+ m ]) m}
         (cong (λ s → mkℚᵘ s m) (cong +_ tot))))
    (whole-is-one m)

------------------------------------------------------------------------
-- Aggregating counts, never averaging proportions
--
-- `exact_summaries.jl` builds a group summary by summing counts and dividing
-- once.  Averaging the per-sample proportions instead gives a different number
-- whenever the samples have different depths, and the difference is invisible
-- in the result.  The two agree *exactly* when the denominators agree, which is
-- the statement below — so the choice appears as a hypothesis instead of being
-- buried in an implementation.
aggregate-then-divide :
  ∀ {n} (cs : Vec ℕ n) (m : ℕ) →
  sumVecℚᵘ (abundances cs m) ≃ mkℚᵘ (+ sumVecℕ cs) m
aggregate-then-divide cs m =
  ≃-trans {sumVecℚᵘ (abundances cs m)}
          {mkℚᵘ (sumVecℤ (Vec.map +_ cs)) m}
          {mkℚᵘ (+ sumVecℕ cs) m}
    (sumVec-over-common-denominator (Vec.map +_ cs) m)
    (≡⇒≃ (cong (λ s → mkℚᵘ s m) (sumVecℕ-map-+ cs)))
