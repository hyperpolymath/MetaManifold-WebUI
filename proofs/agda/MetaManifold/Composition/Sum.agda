-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Weighted sums and the weighted inner product on tip vectors, over an
-- arbitrary commutative ring.
--
-- With part weights p (philr's `p`; all ones for the standard Aitchison
-- geometry) the inner product of two log-scale vectors is
--
--     ⟪ x , y ⟫ₚ = Σᵢ pᵢ · xᵢ · yᵢ          (wdot p x y)
--
-- and the weighted sum is Σᵢ pᵢ · xᵢ (wsum p x). A vector is centred
-- (lies in the image of philr's clrp) exactly when wsum p x ≈ 0.
--
-- This module is shared vocabulary for every compositional transform in
-- the proof suite (ILR here, zero replacement in #21): nothing in it is
-- specific to balances.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

open import Algebra.Bundles using (CommutativeRing)

module MetaManifold.Composition.Sum {c ℓ} (R : CommutativeRing c ℓ) where

open CommutativeRing R
open import Algebra.Properties.Ring ring
  using (-‿distribˡ-*; -‿distribʳ-*; -‿involutive; -‿+-comm;
         +-inverseˡ-unique; x[y-z]≈xy-xz)
open import Data.Product.Base using (_×_; _,_)
open import Relation.Binary.Reasoning.Setoid setoid
open import Relation.Binary.PropositionalEquality.Core as ≡ using (_≡_)

open import MetaManifold.Composition.Tree

import Algebra.Solver.Ring.NaturalCoefficients.Default commutativeSemiring as Solver
open Solver using (solve; _:+_; _:*_; _:=_)

private
  variable t : Tree

------------------------------------------------------------------------
-- Ring facts used below (negation is outside the ℕ-coefficient solver,
-- so it is handled by hand and the solver sees negation-free goals).

neg*neg : ∀ a b → (- a) * (- b) ≈ a * b
neg*neg a b = begin
  (- a) * (- b)    ≈⟨ -‿distribˡ-* a (- b) ⟨
  - (a * (- b))    ≈⟨ -‿cong (-‿distribʳ-* a b) ⟨
  - (- (a * b))    ≈⟨ -‿involutive (a * b) ⟩
  a * b            ∎

interchange : ∀ a b c d → (a + b) + (c + d) ≈ (a + c) + (b + d)
interchange = solve 4 (λ a b c d → (a :+ b) :+ (c :+ d) := (a :+ c) :+ (b :+ d)) refl

sum-zero : ∀ {a b} → a ≈ 0# → b ≈ 0# → a + b ≈ 0#
sum-zero a≈0 b≈0 = trans (+-cong a≈0 b≈0) (+-identityʳ 0#)

-- a - b ≈ 0 ⇒ a ≈ b
difference-zero : ∀ {a b} → a - b ≈ 0# → a ≈ b
difference-zero {a} {b} eq = trans (+-inverseˡ-unique a (- b) eq) (-‿involutive b)

------------------------------------------------------------------------
-- Definitions

-- Σᵢ xᵢ
total : TVec Carrier t → Carrier
total (tip x) = x
total (u ⊗ v) = total u + total v

-- Σᵢ pᵢ xᵢ
wsum : TVec Carrier t → TVec Carrier t → Carrier
wsum (tip p)   (tip x)   = p * x
wsum (w ⊗ w′)  (x ⊗ x′)  = wsum w x + wsum w′ x′

-- Σᵢ pᵢ xᵢ yᵢ
wdot : TVec Carrier t → TVec Carrier t → TVec Carrier t → Carrier
wdot (tip p)  (tip x)  (tip y)  = p * (x * y)
wdot (w ⊗ w′) (x ⊗ x′) (y ⊗ y′) = wdot w x y + wdot w′ x′ y′

-- Pointwise equality of tip vectors.
infix 4 _≋_
_≋_ : TVec Carrier t → TVec Carrier t → Set ℓ
tip x   ≋ tip y   = x ≈ y
(u ⊗ v) ≋ (u′ ⊗ v′) = u ≋ u′ × v ≋ v′

≋-refl : (x : TVec Carrier t) → x ≋ x
≋-refl (tip x) = refl
≋-refl (u ⊗ v) = ≋-refl u , ≋-refl v

≡⇒≋ : {x y : TVec Carrier t} → x ≡ y → x ≋ y
≡⇒≋ {x = x} ≡.refl = ≋-refl x

-- Vector operations.
infixl 6 _+ᵥ_ _-ᵥ_
_+ᵥ_ _-ᵥ_ : TVec Carrier t → TVec Carrier t → TVec Carrier t
_+ᵥ_ = zipWith _+_
_-ᵥ_ = zipWith _-_

infixl 7 _·ᵥ_
_·ᵥ_ : Carrier → TVec Carrier t → TVec Carrier t
k ·ᵥ x = map (k *_) x

------------------------------------------------------------------------
-- Constants

wsum-pure : ∀ (w : TVec Carrier t) k → wsum w (pure k) ≈ total w * k
wsum-pure (tip p) k = refl
wsum-pure (w ⊗ w′) k = trans (+-cong (wsum-pure w k) (wsum-pure w′ k))
                             (sym (distribʳ k (total w) (total w′)))

wsum-zero : ∀ (w : TVec Carrier t) → wsum w (pure 0#) ≈ 0#
wsum-zero w = trans (wsum-pure w 0#) (zeroʳ (total w))

wdot-pureˡ : ∀ (w : TVec Carrier t) k y → wdot w (pure k) y ≈ k * wsum w y
wdot-pureˡ (tip p) k (tip y) =
  solve 3 (λ p k y → p :* (k :* y) := k :* (p :* y)) refl p k y
wdot-pureˡ (w ⊗ w′) k (y ⊗ y′) =
  trans (+-cong (wdot-pureˡ w k y) (wdot-pureˡ w′ k y′))
        (sym (distribˡ k (wsum w y) (wsum w′ y′)))

wdot-comm : ∀ (w x y : TVec Carrier t) → wdot w x y ≈ wdot w y x
wdot-comm (tip p) (tip x) (tip y) = *-congˡ (*-comm x y)
wdot-comm (w ⊗ w′) (x ⊗ x′) (y ⊗ y′) = +-cong (wdot-comm w x y) (wdot-comm w′ x′ y′)

wdot-pureʳ : ∀ (w x : TVec Carrier t) k → wdot w x (pure k) ≈ k * wsum w x
wdot-pureʳ w x k = trans (wdot-comm w x (pure k)) (wdot-pureˡ w k x)

wdot-zeroˡ : ∀ (w y : TVec Carrier t) → wdot w (pure 0#) y ≈ 0#
wdot-zeroˡ w y = trans (wdot-pureˡ w 0# y) (zeroˡ (wsum w y))

wdot-zeroʳ : ∀ (w x : TVec Carrier t) → wdot w x (pure 0#) ≈ 0#
wdot-zeroʳ w x = trans (wdot-pureʳ w x 0#) (zeroˡ (wsum w x))

------------------------------------------------------------------------
-- Linearity in the last argument (the data argument of a balance).

wdot-+ʳ : ∀ (w x y z : TVec Carrier t) →
          wdot w x (y +ᵥ z) ≈ wdot w x y + wdot w x z
wdot-+ʳ (tip p) (tip x) (tip y) (tip z) =
  solve 4 (λ p x y z → p :* (x :* (y :+ z)) := p :* (x :* y) :+ p :* (x :* z))
        refl p x y z
wdot-+ʳ (w ⊗ w′) (x ⊗ x′) (y ⊗ y′) (z ⊗ z′) =
  trans (+-cong (wdot-+ʳ w x y z) (wdot-+ʳ w′ x′ y′ z′))
        (interchange _ _ _ _)

wdot-·ʳ : ∀ (w x : TVec Carrier t) k y → wdot w x (k ·ᵥ y) ≈ k * wdot w x y
wdot-·ʳ (tip p) (tip x) k (tip y) =
  solve 4 (λ p x k y → p :* (x :* (k :* y)) := k :* (p :* (x :* y))) refl p x k y
wdot-·ʳ (w ⊗ w′) (x ⊗ x′) k (y ⊗ y′) =
  trans (+-cong (wdot-·ʳ w x k y) (wdot-·ʳ w′ x′ k y′))
        (sym (distribˡ k _ _))

-- (a - b) + (c - d) ≈ (a + c) - (b + d)
private
  sub-interchange : ∀ a b c d → (a - b) + (c - d) ≈ (a + c) - (b + d)
  sub-interchange a b c d = begin
    (a + - b) + (c + - d)  ≈⟨ interchange a (- b) c (- d) ⟩
    (a + c) + (- b + - d)  ≈⟨ +-congˡ (-‿+-comm b d) ⟩
    (a + c) + - (b + d)    ∎

wdot--ʳ : ∀ (w x y z : TVec Carrier t) →
          wdot w x (y -ᵥ z) ≈ wdot w x y - wdot w x z
wdot--ʳ (tip p) (tip x) (tip y) (tip z) = begin
  p * (x * (y - z))            ≈⟨ *-congˡ (x[y-z]≈xy-xz x y z) ⟩
  p * (x * y - x * z)          ≈⟨ x[y-z]≈xy-xz p (x * y) (x * z) ⟩
  p * (x * y) - p * (x * z)    ∎
wdot--ʳ (w ⊗ w′) (x ⊗ x′) (y ⊗ y′) (z ⊗ z′) =
  trans (+-cong (wdot--ʳ w x y z) (wdot--ʳ w′ x′ y′ z′))
        (sub-interchange _ _ _ _)

wsum--ʳ : ∀ (w y z : TVec Carrier t) → wsum w (y -ᵥ z) ≈ wsum w y - wsum w z
wsum--ʳ (tip p) (tip y) (tip z) = x[y-z]≈xy-xz p y z
wsum--ʳ (w ⊗ w′) (y ⊗ y′) (z ⊗ z′) =
  trans (+-cong (wsum--ʳ w y z) (wsum--ʳ w′ y′ z′)) (sub-interchange _ _ _ _)

------------------------------------------------------------------------
-- All entries of x - y are zero ⇒ x ≋ y

AllZero : TVec Carrier t → Set ℓ
AllZero (tip x) = x ≈ 0#
AllZero (u ⊗ v) = AllZero u × AllZero v

allZero-difference : ∀ (x y : TVec Carrier t) → AllZero (x -ᵥ y) → x ≋ y
allZero-difference (tip x) (tip y) z = difference-zero z
allZero-difference (u ⊗ v) (u′ ⊗ v′) (zu , zv) =
  allZero-difference u u′ zu , allZero-difference v v′ zv

------------------------------------------------------------------------
-- Congruence

wdot-congʳ : ∀ (w x : TVec Carrier t) {y z} → y ≋ z → wdot w x y ≈ wdot w x z
wdot-congʳ (tip p) (tip x) {tip y} {tip z} y≈z = *-congˡ (*-congˡ y≈z)
wdot-congʳ (w ⊗ w′) (x ⊗ x′) {y ⊗ y′} {z ⊗ z′} (e , e′) =
  +-cong (wdot-congʳ w x e) (wdot-congʳ w′ x′ e′)

wdot-·ˡ : ∀ (w : TVec Carrier t) k x y → wdot w (k ·ᵥ x) y ≈ k * wdot w x y
wdot-·ˡ w k x y = trans (wdot-comm w (k ·ᵥ x) y)
                  (trans (wdot-·ʳ w y k x) (*-congˡ (wdot-comm w y x)))
