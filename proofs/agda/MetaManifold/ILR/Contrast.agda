-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Balance contrasts of a tree under part weights, over any commutative
-- ring.
--
-- For internal node n with numerator parts N₊ and denominator parts N₋
-- and part weights p, write r = Σ_{N₊} p and s = Σ_{N₋} p. The contrast
--
--     contrast p n = s on N₊,  -r on N₋,  0 elsewhere
--
-- is philr's `buildilrBasep` column (entries +c/r and -c/s with
-- c = sqrt(rs/(r+s))) multiplied by the non-zero scalar rs/c. Every
-- property proved here is invariant under that rescaling, so it holds
-- for the normalised basis the Julia code uses; the scalar itself is
-- pinned by `contrast-norm` (norm² = r·s·(r+s), hence the normalised
-- column has norm 1 exactly when multiplied by 1/sqrt(r·s·(r+s))).
--
-- Uniform weights (p = 1) give the classical Egozcue et al. (2003)
-- balance with coefficients ±sqrt(rs/(r+s))·(1/r or 1/s).
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

open import Algebra.Bundles using (CommutativeRing)

module MetaManifold.ILR.Contrast {c ℓ} (R : CommutativeRing c ℓ) where

open CommutativeRing R
open import Algebra.Properties.Ring ring using (-‿distribʳ-*)
open import Data.Empty using (⊥-elim)
open import Data.Product.Base using (_,_)
open import Relation.Binary.PropositionalEquality.Core as ≡
  using (_≡_; _≢_; cong)
open import Relation.Binary.Reasoning.Setoid setoid

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum R
open import MetaManifold.ILR.SBP

import Algebra.Solver.Ring.NaturalCoefficients.Default commutativeSemiring as Solver
open Solver using (solve; _:+_; _:*_; _:=_)

private
  variable t : Tree

------------------------------------------------------------------------
-- Masses and contrasts

-- r: total weight of the numerator of balance n.
plus-mass : TVec Carrier t → Node t → Carrier
plus-mass (wl ⊗ wr) here    = total wl
plus-mass (wl ⊗ wr) (inl n) = plus-mass wl n
plus-mass (wl ⊗ wr) (inr n) = plus-mass wr n

-- s: total weight of the denominator of balance n.
minus-mass : TVec Carrier t → Node t → Carrier
minus-mass (wl ⊗ wr) here    = total wr
minus-mass (wl ⊗ wr) (inl n) = minus-mass wl n
minus-mass (wl ⊗ wr) (inr n) = minus-mass wr n

contrast : TVec Carrier t → Node t → TVec Carrier t
contrast (wl ⊗ wr) here    = pure (total wr) ⊗ pure (- total wl)
contrast (wl ⊗ wr) (inl n) = contrast wl n ⊗ pure 0#
contrast (wl ⊗ wr) (inr n) = pure 0# ⊗ contrast wr n

-- The (unnormalised) balance of a log-scale vector x at node n.
balance : TVec Carrier t → Node t → TVec Carrier t → Carrier
balance w n x = wdot w (contrast w n) x

------------------------------------------------------------------------
-- The contrast is determined by the SBP row and the two masses: this is
-- what lets the Julia code compute a balance from a sign matrix alone.

interpret : Carrier → Carrier → Sign → Carrier
interpret r s plus  = s
interpret r s minus = - r
interpret r s off   = 0#

private
  -- `w` only fixes the tree index, which `_≋_` cannot infer.
  pure≋map : ∀ {t} (w : TVec Carrier t) (f : Sign → Carrier) σ →
             pure {t = t} (f σ) ≋ map f (pure σ)
  pure≋map {t} w f σ = ≡⇒≋ {t = t} (≡.sym (map-pure f σ))

contrast-from-code : ∀ (w : TVec Carrier t) n →
  contrast w n ≋ map (interpret (plus-mass w n) (minus-mass w n)) (code n)
contrast-from-code (wl ⊗ wr) here =
  pure≋map wl (interpret (total wl) (total wr)) plus ,
  pure≋map wr (interpret (total wl) (total wr)) minus
contrast-from-code (wl ⊗ wr) (inl n) =
  contrast-from-code wl n ,
  pure≋map wr (interpret (plus-mass wl n) (minus-mass wl n)) off
contrast-from-code (wl ⊗ wr) (inr n) =
  pure≋map wl (interpret (plus-mass wr n) (minus-mass wr n)) off ,
  contrast-from-code wr n

-- Masses from the SBP row: r = Σ p over the +1 entries, s over the -1.
indicator : Sign → Sign → Carrier
indicator plus  plus  = 1#
indicator minus minus = 1#
indicator _     _     = 0#

private
  wsum-one : ∀ (w : TVec Carrier t) → wsum w (pure 1#) ≈ total w
  wsum-one w = trans (wsum-pure w 1#) (*-identityʳ (total w))

  wsum-map-pure : ∀ (w : TVec Carrier t) (f : Sign → Carrier) σ →
                  wsum w (map f (pure σ)) ≈ total w * f σ
  wsum-map-pure w f σ = trans (≡⇒≈ (cong (wsum w) (map-pure f σ))) (wsum-pure w (f σ))
    where
    ≡⇒≈ : ∀ {a b} → a ≡ b → a ≈ b
    ≡⇒≈ ≡.refl = refl

  plus-side : ∀ a b → a * 1# + b * 0# ≈ a
  plus-side a b = trans (+-cong (*-identityʳ a) (zeroʳ b)) (+-identityʳ a)

  minus-side : ∀ a b → a * 0# + b * 1# ≈ b
  minus-side a b = trans (+-cong (zeroʳ a) (*-identityʳ b)) (+-identityˡ b)

  plus-zero : ∀ a b → a + b * 0# ≈ a
  plus-zero a b = trans (+-congˡ (zeroʳ b)) (+-identityʳ a)

  zero-plus : ∀ a b → a * 0# + b ≈ b
  zero-plus a b = trans (+-congʳ (zeroʳ a)) (+-identityˡ b)

plus-mass-from-code : ∀ (w : TVec Carrier t) n →
  plus-mass w n ≈ wsum w (map (indicator plus) (code n))
plus-mass-from-code (wl ⊗ wr) here = sym (trans
  (+-cong (wsum-map-pure wl (indicator plus) plus) (wsum-map-pure wr (indicator plus) minus))
  (plus-side (total wl) (total wr)))
plus-mass-from-code (wl ⊗ wr) (inl n) = sym (trans
  (+-congˡ (wsum-map-pure wr (indicator plus) off))
  (trans (plus-zero _ (total wr)) (sym (plus-mass-from-code wl n))))
plus-mass-from-code (wl ⊗ wr) (inr n) = sym (trans
  (+-congʳ (wsum-map-pure wl (indicator plus) off))
  (trans (zero-plus (total wl) _) (sym (plus-mass-from-code wr n))))

minus-mass-from-code : ∀ (w : TVec Carrier t) n →
  minus-mass w n ≈ wsum w (map (indicator minus) (code n))
minus-mass-from-code (wl ⊗ wr) here = sym (trans
  (+-cong (wsum-map-pure wl (indicator minus) plus) (wsum-map-pure wr (indicator minus) minus))
  (minus-side (total wl) (total wr)))
minus-mass-from-code (wl ⊗ wr) (inl n) = sym (trans
  (+-congˡ (wsum-map-pure wr (indicator minus) off))
  (trans (plus-zero _ (total wr)) (sym (minus-mass-from-code wl n))))
minus-mass-from-code (wl ⊗ wr) (inr n) = sym (trans
  (+-congʳ (wsum-map-pure wl (indicator minus) off))
  (trans (zero-plus (total wl) _) (sym (minus-mass-from-code wr n))))

------------------------------------------------------------------------
-- Each contrast is centred: Σᵢ pᵢ cᵢ = 0. Consequently a balance does not
-- depend on which centring (clr, clrp, none) is applied to log x first.

private
  rs-cancel : ∀ r s → r * s + s * (- r) ≈ 0#
  rs-cancel r s = begin
    r * s + s * (- r)    ≈⟨ +-congˡ (-‿distribʳ-* s r) ⟨
    r * s + - (s * r)    ≈⟨ +-congˡ (-‿cong (*-comm s r)) ⟩
    r * s + - (r * s)    ≈⟨ -‿inverseʳ (r * s) ⟩
    0#                   ∎

contrast-sum-zero : ∀ (w : TVec Carrier t) n → wsum w (contrast w n) ≈ 0#
contrast-sum-zero (wl ⊗ wr) here =
  trans (+-cong (wsum-pure wl (total wr)) (wsum-pure wr (- total wl)))
        (rs-cancel (total wl) (total wr))
contrast-sum-zero (wl ⊗ wr) (inl n) = sum-zero (contrast-sum-zero wl n) (wsum-zero wr)
contrast-sum-zero (wl ⊗ wr) (inr n) = sum-zero (wsum-zero wl) (contrast-sum-zero wr n)

------------------------------------------------------------------------
-- Distinct contrasts are orthogonal in the weighted inner product.

private
  -- The root contrast against any contrast strictly inside the left or
  -- right subtree.
  root-inl : ∀ {l r} (wl : TVec Carrier l) (wr : TVec Carrier r) (m : Node l) →
             wdot (wl ⊗ wr) (contrast (wl ⊗ wr) here) (contrast (wl ⊗ wr) (inl m)) ≈ 0#
  root-inl wl wr m = sum-zero
    (trans (wdot-pureˡ wl (total wr) (contrast wl m))
           (trans (*-congˡ (contrast-sum-zero wl m)) (zeroʳ (total wr))))
    (wdot-zeroʳ wr (pure (- total wl)))

  root-inr : ∀ {l r} (wl : TVec Carrier l) (wr : TVec Carrier r) (m : Node r) →
             wdot (wl ⊗ wr) (contrast (wl ⊗ wr) here) (contrast (wl ⊗ wr) (inr m)) ≈ 0#
  root-inr wl wr m = sum-zero
    (wdot-zeroʳ wl (pure (total wr)))
    (trans (wdot-pureˡ wr (- total wl) (contrast wr m))
           (trans (*-congˡ (contrast-sum-zero wr m)) (zeroʳ (- total wl))))

  flip : ∀ (w x y : TVec Carrier t) → wdot w x y ≈ 0# → wdot w y x ≈ 0#
  flip w x y eq = trans (wdot-comm w y x) eq

contrast-orthogonal : ∀ (w : TVec Carrier t) {n m : Node t} → n ≢ m →
                      wdot w (contrast w n) (contrast w m) ≈ 0#
contrast-orthogonal (wl ⊗ wr) {here}  {here}  n≢m = ⊥-elim (n≢m ≡.refl)
contrast-orthogonal (wl ⊗ wr) {here}  {inl m} _   = root-inl wl wr m
contrast-orthogonal (wl ⊗ wr) {here}  {inr m} _   = root-inr wl wr m
contrast-orthogonal (wl ⊗ wr) {inl n} {here}  _   =
  flip (wl ⊗ wr) (contrast (wl ⊗ wr) here) (contrast (wl ⊗ wr) (inl n)) (root-inl wl wr n)
contrast-orthogonal (wl ⊗ wr) {inr n} {here}  _   =
  flip (wl ⊗ wr) (contrast (wl ⊗ wr) here) (contrast (wl ⊗ wr) (inr n)) (root-inr wl wr n)
contrast-orthogonal (wl ⊗ wr) {inl n} {inl m} n≢m =
  sum-zero (contrast-orthogonal wl (λ eq → n≢m (cong inl eq))) (wdot-zeroʳ wr (pure 0#))
contrast-orthogonal (wl ⊗ wr) {inl n} {inr m} _   =
  sum-zero (wdot-zeroʳ wl (contrast wl n)) (wdot-zeroˡ wr (contrast wr m))
contrast-orthogonal (wl ⊗ wr) {inr n} {inl m} _   =
  sum-zero (wdot-zeroˡ wl (contrast wl m)) (wdot-zeroʳ wr (contrast wr n))
contrast-orthogonal (wl ⊗ wr) {inr n} {inr m} n≢m =
  sum-zero (wdot-zeroʳ wl (pure 0#)) (contrast-orthogonal wr (λ eq → n≢m (cong inr eq)))

------------------------------------------------------------------------
-- Norm: ⟪ c , c ⟫ₚ = r·s·(r+s). The normalised philr/Egozcue column is
-- c / sqrt(r·s·(r+s)); for uniform weights this is the textbook constant
-- sqrt(rs/(r+s)) on the ±1/r, ±1/s scale.

contrast-norm : ∀ (w : TVec Carrier t) n →
  wdot w (contrast w n) (contrast w n)
    ≈ (plus-mass w n * minus-mass w n) * (plus-mass w n + minus-mass w n)
contrast-norm (wl ⊗ wr) here = begin
  wdot wl (pure s) (pure s) + wdot wr (pure (- r)) (pure (- r))
    ≈⟨ +-cong (wdot-pureˡ wl s (pure s)) (wdot-pureˡ wr (- r) (pure (- r))) ⟩
  s * wsum wl (pure s) + (- r) * wsum wr (pure (- r))
    ≈⟨ +-cong (*-congˡ (wsum-pure wl s)) (*-congˡ (wsum-pure wr (- r))) ⟩
  s * (r * s) + (- r) * (s * (- r))
    ≈⟨ +-congˡ (*-congˡ (-‿distribʳ-* s r)) ⟨
  s * (r * s) + (- r) * (- (s * r))
    ≈⟨ +-congˡ (neg*neg r (s * r)) ⟩
  s * (r * s) + r * (s * r)
    ≈⟨ solve 2 (λ r s → s :* (r :* s) :+ r :* (s :* r) := (r :* s) :* (r :+ s)) refl r s ⟩
  (r * s) * (r + s) ∎
  where r = total wl; s = total wr
contrast-norm (wl ⊗ wr) (inl n) =
  trans (+-congˡ (wdot-zeroʳ wr (pure 0#)))
        (trans (+-identityʳ _) (contrast-norm wl n))
contrast-norm (wl ⊗ wr) (inr n) =
  trans (+-congʳ (wdot-zeroʳ wl (pure 0#)))
        (trans (+-identityˡ _) (contrast-norm wr n))
