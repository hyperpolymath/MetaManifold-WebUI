-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Sequential binary partitions (Egozcue & Pawlowsky-Glahn 2005).
--
-- An SBP is a (D-1) × D sign matrix: row n says which parts are in the
-- numerator (+1), which in the denominator (-1) and which are not
-- involved (0) in balance n. Egozcue & Pawlowsky-Glahn's conditions
-- are that the first row splits all parts into two non-empty groups
-- and that every later row splits one group produced by an earlier row
-- into two non-empty groups. That is precisely "the rows are the
-- internal nodes of a rooted binary tree", which is how it is stated
-- here: `code n` is row n of the SBP of a tree.
--
-- Proved: every row has a non-empty numerator and denominator
-- (`code-has-plus`, `code-has-minus`), a child row is supported inside
-- one side of its parent row (`code-nested-inl`, `code-nested-inr`),
-- and there are exactly D - 1 rows (`Node.toFin` bijection together
-- with `Tree.internal-count`).
--
-- The Julia validator (`validate_sbp` in src/analysis/ilr_basis.jl)
-- decides the converse — that a user-supplied matrix *is* the code of
-- some tree — by reconstructing that tree, and refuses otherwise.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

module MetaManifold.ILR.SBP where

open import Data.Product.Base using (_×_; _,_)
open import Data.Sum.Base using (_⊎_; inj₁; inj₂)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node

data Sign : Set where
  plus minus off : Sign

-- Row n of the SBP of t. philr's convention (phylo2sbp): first child
-- in the numerator, second child in the denominator.
code : ∀ {t} → Node t → TVec Sign t
code here    = pure plus ⊗ pure minus
code (inl n) = code n ⊗ pure off
code (inr n) = pure off ⊗ code n

code-has-plus : ∀ {t} (n : Node t) → Any (_≡ plus) (code n)
code-has-plus here    = left (any-pure refl)
code-has-plus (inl n) = left (code-has-plus n)
code-has-plus (inr n) = right (code-has-plus n)

code-has-minus : ∀ {t} (n : Node t) → Any (_≡ minus) (code n)
code-has-minus here    = right (any-pure refl)
code-has-minus (inl n) = left (code-has-minus n)
code-has-minus (inr n) = right (code-has-minus n)

------------------------------------------------------------------------
-- Nesting: a row below the root only involves parts on one side of the
-- root row.

-- `child ⊑[ σ ] parent`: every part the child row involves has sign σ
-- in the parent row.
_⊑[_]_ : ∀ {t} → TVec Sign t → Sign → TVec Sign t → Set
child ⊑[ σ ] parent = All (λ { (c , p) → c ≡ off ⊎ p ≡ σ }) (zipWith _,_ child parent)

private
  zip-pureʳ : ∀ {t} (x : TVec Sign t) σ → x ⊑[ σ ] pure σ
  zip-pureʳ (tip x) σ = at (inj₂ refl)
  zip-pureʳ (u ⊗ v) σ = both (zip-pureʳ u σ) (zip-pureʳ v σ)

  zip-offˡ : ∀ {t} (y : TVec Sign t) σ → pure off ⊑[ σ ] y
  zip-offˡ (tip y) σ = at (inj₁ refl)
  zip-offˡ (u ⊗ v) σ = both (zip-offˡ u σ) (zip-offˡ v σ)

code-nested-inl : ∀ {l r} (m : Node l) → code (inl {r = r} m) ⊑[ plus ] code (here {l} {r})
code-nested-inl m = both (zip-pureʳ (code m) plus) (zip-offˡ (pure minus) plus)

code-nested-inr : ∀ {l r} (m : Node r) → code (inr {l = l} m) ⊑[ minus ] code (here {l} {r})
code-nested-inr m = both (zip-offˡ (pure plus) minus) (zip-pureʳ (code m) minus)
