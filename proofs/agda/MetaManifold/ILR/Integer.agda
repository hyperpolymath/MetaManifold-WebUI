-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- The integer instance: the generic results specialised to ℤ, the
-- side-condition of the kernel theorem discharged for positive weights,
-- a counterexample proving that side-condition is needed, and philr's
-- own known-answer SBP reproduced by `code`.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

module MetaManifold.ILR.Integer where

open import Data.Integer.Base
  using (ℤ; +_; -[1+_]; 0ℤ; 1ℤ; -1ℤ; _*_; _<_; +<+; >-nonZero)
open import Data.Integer.Properties
  using (+-*-commutativeRing; *-cancelˡ-≡; *-zeroʳ; +-mono-<)
open import Data.Nat.Base using (s≤s; z≤n)
open import Data.Product.Base using (_×_; _,_)
open import Data.Vec.Base using (_∷_; [])
open import Relation.Binary.PropositionalEquality using (_≡_; refl; sym; trans)
open import Relation.Nullary.Negation using (¬_)

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum +-*-commutativeRing
open import MetaManifold.ILR.SBP
open import MetaManifold.ILR.Contrast +-*-commutativeRing
open import MetaManifold.ILR.Kernel +-*-commutativeRing

------------------------------------------------------------------------
-- Positive weights are cancellable.

Positive : ∀ {t} → TVec ℤ t → Set
Positive = All (0ℤ <_)

private
  total-positive : ∀ {t} {w : TVec ℤ t} → Positive w → 0ℤ < total w
  total-positive (at p)      = p
  total-positive (both l r)  = +-mono-< (total-positive l) (total-positive r)

  cancel : ∀ {k} → 0ℤ < k → ∀ {a} → k * a ≡ 0ℤ → a ≡ 0ℤ
  cancel {k} k>0 {a} eq = *-cancelˡ-≡ k a 0ℤ {{>-nonZero k>0}} (trans eq (sym (*-zeroʳ k)))

positive-cancellable : ∀ {t} {w : TVec ℤ t} → Positive w → Cancellable w
positive-cancellable (at p)     = tipC (cancel p)
positive-cancellable (both l r) =
  nodeC (cancel (+-mono-< (total-positive l) (total-positive r)))
        (positive-cancellable l) (positive-cancellable r)

-- Uniform weights (the standard Aitchison geometry) in particular.
uniform-cancellable : ∀ t → Cancellable (pure {t = t} 1ℤ)
uniform-cancellable t = positive-cancellable (all-pure {t = t} (+<+ (s≤s z≤n)))

-- Hence, over ℤ with positive weights, balances are injective on
-- centred vectors.
balance-injective-positive : ∀ {t} {w : TVec ℤ t} → Positive w → ∀ x y →
  wsum w x ≡ 0ℤ → wsum w y ≡ 0ℤ → (∀ n → balance w n x ≡ balance w n y) → x ≋ y
balance-injective-positive pw = balance-injective (positive-cancellable pw)

------------------------------------------------------------------------
-- Negative control: without the hypothesis the kernel theorem is false.
--
-- Weights (1, -1) have clade total 0. The vector x = (1, 1) is centred
-- (1·1 + (-1)·1 = 0) and its only balance is 1·(-1·1) + (-1)·(-1·1) = 0,
-- yet x ≠ 0. This is why the Julia code refuses non-positive part
-- weights instead of computing with them.

private
  w₀ x₀ : TVec ℤ (node leaf leaf)
  w₀ = tip 1ℤ ⊗ tip -1ℤ
  x₀ = tip 1ℤ ⊗ tip 1ℤ

  x₀-centred : wsum w₀ x₀ ≡ 0ℤ
  x₀-centred = refl

  x₀-balances : ∀ n → balance w₀ n x₀ ≡ 0ℤ
  x₀-balances here = refl

  x₀-nonzero : ¬ AllZero x₀
  x₀-nonzero (() , _)

kernel-needs-hypothesis :
  ¬ (∀ {t} (w x : TVec ℤ t) → wsum w x ≡ 0ℤ → (∀ n → balance w n x ≡ 0ℤ) → AllZero x)
kernel-needs-hypothesis claim = x₀-nonzero (claim w₀ x₀ x₀-centred x₀-balances)

signed-weights-not-cancellable : ¬ Cancellable w₀
signed-weights-not-cancellable c = x₀-nonzero (balance-kernel c x₀ x₀-centred x₀-balances)

------------------------------------------------------------------------
-- Known answer shared with R philr's test suite (tests/testthat): the
-- tree (otu1,(otu2,otu3)) has SBP columns (1,-1,-1) and (0,1,-1), and
-- with part weights p = (1, 1, 0.5) philr's basis is
--   [[ 0.7745967, 0], [-0.5163978, 0.5773503], [-0.5163978, -1.1547005]].
-- Over ℤ we use p = (2, 2, 1) (= 2 × philr's p): the unnormalised
-- contrasts below are proportional to philr's columns (3 : -2 : -2 and
-- 1 : -2), which is all that the scale of p can change.

t₃ : Tree
t₃ = node leaf (node leaf leaf)

sbp-column-1 : flatten (code (here {leaf} {node leaf leaf})) ≡ plus ∷ minus ∷ minus ∷ []
sbp-column-1 = refl

sbp-column-2 : flatten (code (inr {leaf} (here {leaf} {leaf}))) ≡ off ∷ plus ∷ minus ∷ []
sbp-column-2 = refl

p₃ : TVec ℤ t₃
p₃ = tip (+ 2) ⊗ (tip (+ 2) ⊗ tip (+ 1))

contrast-column-1 : flatten (contrast p₃ here) ≡ + 3 ∷ -[1+ 1 ] ∷ -[1+ 1 ] ∷ []
contrast-column-1 = refl

contrast-column-2 : flatten (contrast p₃ (inr here)) ≡ 0ℤ ∷ + 1 ∷ -[1+ 1 ] ∷ []
contrast-column-2 = refl

-- The two columns are orthogonal under p (2·3·0 + 2·(-2)·1 + 1·(-2)·(-2) = 0)
-- and have squared norms r·s·(r+s) = 2·3·5 = 30 and 2·1·3 = 6.
columns-orthogonal : wdot p₃ (contrast p₃ here) (contrast p₃ (inr here)) ≡ 0ℤ
columns-orthogonal = refl

column-norms : wdot p₃ (contrast p₃ here) (contrast p₃ here) ≡ + 30
             × wdot p₃ (contrast p₃ (inr here)) (contrast p₃ (inr here)) ≡ + 6
column-norms = refl , refl
