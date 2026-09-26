-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Positions of internal nodes, and their preorder enumeration.
--
-- `Node t` names one internal node of `t`: the root (`here`) or a node
-- inside the left / right subtree. Each internal node carries exactly
-- one balance, so `Node t` indexes the balances.
--
-- `toFin`/`fromFin` are the preorder numbering (root first, then the
-- left subtree, then the right subtree) and are proved mutually
-- inverse: the balances of a D-tip tree are in bijection with
-- `Fin (D - 1)`. Preorder is the order in which R `philr` numbers
-- balances (ape's internal-node order) and the order in which
-- src/analysis/ilr_basis.jl emits them.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

module MetaManifold.Composition.Node where

open import Data.Fin.Base using (Fin; zero; suc; _↑ˡ_; _↑ʳ_; splitAt)
open import Data.Fin.Properties
  using (splitAt-↑ˡ; splitAt-↑ʳ; splitAt⁻¹-↑ˡ; splitAt⁻¹-↑ʳ)
open import Data.Sum.Base using (inj₁; inj₂)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; cong; trans)

open import MetaManifold.Composition.Tree

data Node : Tree → Set where
  here : ∀ {l r} → Node (node l r)
  inl  : ∀ {l r} → Node l → Node (node l r)
  inr  : ∀ {l r} → Node r → Node (node l r)

toFin : ∀ {t} → Node t → Fin (internal t)
toFin                 here    = zero
toFin {node l r}      (inl n) = suc (toFin n ↑ˡ internal r)
toFin {node l r}      (inr n) = suc (internal l ↑ʳ toFin n)

fromFin : ∀ {t} → Fin (internal t) → Node t
fromFin {node l r} zero    = here
fromFin {node l r} (suc i) with splitAt (internal l) i
... | inj₁ j = inl (fromFin j)
... | inj₂ k = inr (fromFin k)

fromFin-toFin : ∀ {t} (n : Node t) → fromFin (toFin n) ≡ n
fromFin-toFin                 here    = refl
fromFin-toFin {node l r}      (inl n)
  rewrite splitAt-↑ˡ (internal l) (toFin n) (internal r)
  = cong inl (fromFin-toFin n)
fromFin-toFin {node l r}      (inr n)
  rewrite splitAt-↑ʳ (internal l) (internal r) (toFin n)
  = cong inr (fromFin-toFin n)

toFin-fromFin : ∀ {t} (i : Fin (internal t)) → toFin (fromFin {t} i) ≡ i
toFin-fromFin {node l r} zero = refl
toFin-fromFin {node l r} (suc i) with splitAt (internal l) i in eq
... | inj₁ j = cong suc (trans (cong (_↑ˡ internal r) (toFin-fromFin j)) (splitAt⁻¹-↑ˡ eq))
... | inj₂ k = cong suc (trans (cong (internal l ↑ʳ_) (toFin-fromFin k)) (splitAt⁻¹-↑ʳ eq))
