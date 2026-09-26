-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- The balance map has trivial kernel on centred vectors, hence is
-- injective there: two samples with different (weighted) CLR vectors
-- never share all their balances. No information is lost by moving from
-- CLR to any tree-based ILR basis.
--
-- The hypothesis `Cancellable w` is necessary, not a proof convenience:
-- MetaManifold.ILR.Integer exhibits weights with a zero clade total for
-- which the conclusion is false. It holds for the uniform weights and
-- for all strictly positive weights over an ordered field — the only
-- weights the Julia code accepts (it refuses non-positive part weights).
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

open import Algebra.Bundles using (CommutativeRing)

module MetaManifold.ILR.Kernel {c ℓ} (R : CommutativeRing c ℓ) where

open CommutativeRing R
open import Algebra.Properties.Ring ring using (+-inverseʳ-unique; -0#≈0#)
open import Data.Product.Base using (_,_)
open import Level using (_⊔_)
open import Relation.Binary.Reasoning.Setoid setoid

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum R
open import MetaManifold.ILR.Contrast R

import Algebra.Solver.Ring.NaturalCoefficients.Default commutativeSemiring as Solver
open Solver using (solve; _:+_; _:*_; _:=_)

-- Multiplying by every tip weight, and by every clade's total weight,
-- is injective. Over a field this says: no tip weight is zero and no
-- clade has zero total weight.
data Cancellable : ∀ {t} → TVec Carrier t → Set (c ⊔ ℓ) where
  tipC  : ∀ {p} → (∀ {a} → p * a ≈ 0# → a ≈ 0#) → Cancellable (tip p)
  nodeC : ∀ {l r} {wl : TVec Carrier l} {wr : TVec Carrier r} →
          (∀ {a} → (total wl + total wr) * a ≈ 0# → a ≈ 0#) →
          Cancellable wl → Cancellable wr → Cancellable (wl ⊗ wr)

private
  left-zero : ∀ {a b} → a + b ≈ 0# → b ≈ 0# → a ≈ 0#
  left-zero {a} {b} eq b≈0 = begin
    a        ≈⟨ +-identityʳ a ⟨
    a + 0#   ≈⟨ +-congˡ b≈0 ⟨
    a + b    ≈⟨ eq ⟩
    0#       ∎

  right-zero : ∀ {a b} → a + b ≈ 0# → a ≈ 0# → b ≈ 0#
  right-zero {a} {b} eq a≈0 = left-zero (trans (+-comm b a) eq) a≈0

balance-kernel : ∀ {t} {w : TVec Carrier t} → Cancellable w → ∀ x →
                 wsum w x ≈ 0# → (∀ n → balance w n x ≈ 0#) → AllZero x
balance-kernel (tipC cancel) (tip a) centred _ = cancel centred
balance-kernel {w = wl ⊗ wr} (nodeC cancel cl cr) (xl ⊗ xr) centred bal =
  balance-kernel cl xl A≈0 left-balances , balance-kernel cr xr B≈0 right-balances
  where
  r = total wl
  s = total wr
  A = wsum wl xl
  B = wsum wr xr

  B≈-A : B ≈ - A
  B≈-A = +-inverseʳ-unique A B centred

  root : s * A + (- r) * B ≈ 0#
  root = trans (sym (+-cong (wdot-pureˡ wl s xl) (wdot-pureˡ wr (- r) xr))) (bal here)

  scaled : (r + s) * A ≈ 0#
  scaled = begin
    (r + s) * A            ≈⟨ solve 3 (λ r s A → (r :+ s) :* A := s :* A :+ r :* A) refl r s A ⟩
    s * A + r * A          ≈⟨ +-congˡ (neg*neg r A) ⟨
    s * A + (- r) * (- A)  ≈⟨ +-congˡ (*-congˡ B≈-A) ⟨
    s * A + (- r) * B      ≈⟨ root ⟩
    0#                     ∎

  A≈0 : A ≈ 0#
  A≈0 = cancel scaled

  B≈0 : B ≈ 0#
  B≈0 = trans B≈-A (trans (-‿cong A≈0) -0#≈0#)

  left-balances : ∀ n → balance wl n xl ≈ 0#
  left-balances n = left-zero (bal (inl n)) (wdot-zeroˡ wr xr)

  right-balances : ∀ n → balance wr n xr ≈ 0#
  right-balances n = right-zero (bal (inr n)) (wdot-zeroˡ wl xl)

-- Injectivity on centred vectors.
balance-injective : ∀ {t} {w : TVec Carrier t} → Cancellable w → ∀ x y →
                    wsum w x ≈ 0# → wsum w y ≈ 0# →
                    (∀ n → balance w n x ≈ balance w n y) → x ≋ y
balance-injective {w = w} cw x y x₀ y₀ same =
  allZero-difference x y (balance-kernel cw (x -ᵥ y) centred balances)
  where
  sub-self : ∀ {a b} → a ≈ b → a - b ≈ 0#
  sub-self {a} a≈b = trans (+-congˡ (-‿cong (sym a≈b))) (-‿inverseʳ a)

  centred : wsum w (x -ᵥ y) ≈ 0#
  centred = trans (wsum--ʳ w x y) (sub-self (trans x₀ (sym y₀)))

  balances : ∀ n → balance w n (x -ᵥ y) ≈ 0#
  balances n = trans (wdot--ʳ w (contrast w n) x y) (sub-self (same n))
