-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Orthonormality of the normalised basis, relative to a named
-- normaliser.
--
-- A `Normaliser` supplies, for every balance, a scalar κ with
-- κ · κ · (r · s · (r + s)) ≈ 1. Over the reals κ = 1/sqrt(r·s·(r+s)),
-- which is the constant in src/analysis/ilr_basis.jl; its existence is
-- the only analytic fact the normalised basis needs, and it is taken as
-- an argument rather than postulated. Given it, the scaled contrasts
-- are orthonormal in the weighted inner product: the PhILR / SBP /
-- dendrogram bases are isometries of the (weighted) Aitchison simplex
-- onto R^{D-1}.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

open import Algebra.Bundles using (CommutativeRing)

module MetaManifold.ILR.Orthonormal {c ℓ} (R : CommutativeRing c ℓ) where

open CommutativeRing R
open import Level using (_⊔_)
open import Relation.Binary.PropositionalEquality.Core using (_≢_)
open import Relation.Binary.Reasoning.Setoid setoid

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum R
open import MetaManifold.ILR.Contrast R


record Normaliser {t} (w : TVec Carrier t) : Set (c ⊔ ℓ) where
  field
    κ      : Node t → Carrier
    κ-norm : ∀ n → κ n * κ n *
                   ((plus-mass w n * minus-mass w n) * (plus-mass w n + minus-mass w n)) ≈ 1#

module _ {t} {w : TVec Carrier t} (N : Normaliser w) where
  open Normaliser N

  basis : Node t → TVec Carrier t
  basis n = κ n ·ᵥ contrast w n

  private
    scaled : ∀ n m → wdot w (basis n) (basis m) ≈ κ n * κ m * wdot w (contrast w n) (contrast w m)
    scaled n m = begin
      wdot w (κ n ·ᵥ contrast w n) (κ m ·ᵥ contrast w m)
        ≈⟨ wdot-·ˡ w (κ n) (contrast w n) (κ m ·ᵥ contrast w m) ⟩
      κ n * wdot w (contrast w n) (κ m ·ᵥ contrast w m)
        ≈⟨ *-congˡ (wdot-·ʳ w (contrast w n) (κ m) (contrast w m)) ⟩
      κ n * (κ m * wdot w (contrast w n) (contrast w m))
        ≈⟨ *-assoc (κ n) (κ m) _ ⟨
      κ n * κ m * wdot w (contrast w n) (contrast w m) ∎

  basis-unit : ∀ n → wdot w (basis n) (basis n) ≈ 1#
  basis-unit n = trans (scaled n n) (trans (*-congˡ (contrast-norm w n)) (κ-norm n))

  basis-orthogonal : ∀ {n m} → n ≢ m → wdot w (basis n) (basis m) ≈ 0#
  basis-orthogonal {n} {m} n≢m =
    trans (scaled n m) (trans (*-congˡ (contrast-orthogonal w n≢m)) (zeroʳ _))
