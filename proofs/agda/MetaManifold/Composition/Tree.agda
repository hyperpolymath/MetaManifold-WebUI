-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Rooted binary trees and tip-indexed vectors.
--
-- A `Tree` is the shape of a phylogeny, a sequential binary partition
-- (SBP) or a balance dendrogram once validation has succeeded: rooted
-- and strictly bifurcating. The Julia side (src/analysis/ilr_basis.jl)
-- refuses multifurcating and unrooted input instead of resolving it, so
-- every tree the analysis uses is one of these.
--
-- `TVec A t` is a vector with one entry per tip of `t`, structured like
-- the tree. It is the proof-side form of "one value per taxon"; the
-- flat `Vec` form is recovered by `flatten`, in left-to-right tip order.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

module MetaManifold.Composition.Tree where

open import Level using (Level)
open import Data.Nat.Base using (ℕ; zero; suc; _+_)
open import Data.Nat.Properties using (+-suc; +-comm)
open import Data.Vec.Base using (Vec; []; _∷_; _++_)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; sym; trans; cong; cong₂)

private
  variable
    a b c : Level
    A B C : Set a

data Tree : Set where
  leaf : Tree
  node : Tree → Tree → Tree

-- Number of tips (taxa, parts of the composition): D.
leaves : Tree → ℕ
leaves leaf       = 1
leaves (node l r) = leaves l + leaves r

-- Number of internal nodes: one balance each.
internal : Tree → ℕ
internal leaf       = 0
internal (node l r) = suc (internal l + internal r)

-- D parts give exactly D - 1 balances.
internal-count : ∀ t → suc (internal t) ≡ leaves t
internal-count leaf       = refl
internal-count (node l r) =
  trans (cong suc (sym (+-suc (internal l) (internal r))))
        (cong₂ _+_ (internal-count l) (internal-count r))

------------------------------------------------------------------------
-- Tip-indexed vectors

infixr 5 _⊗_

data TVec (A : Set a) : Tree → Set a where
  tip : A → TVec A leaf
  _⊗_ : ∀ {l r} → TVec A l → TVec A r → TVec A (node l r)

pure : ∀ {t} → A → TVec A t
pure {t = leaf}     x = tip x
pure {t = node l r} x = pure x ⊗ pure x

map : ∀ {t} → (A → B) → TVec A t → TVec B t
map f (tip x) = tip (f x)
map f (u ⊗ v) = map f u ⊗ map f v

zipWith : ∀ {t} → (A → B → C) → TVec A t → TVec B t → TVec C t
zipWith f (tip x) (tip y) = tip (f x y)
zipWith f (u ⊗ v) (u′ ⊗ v′) = zipWith f u u′ ⊗ zipWith f v v′

flatten : ∀ {t} → TVec A t → Vec A (leaves t)
flatten (tip x) = x ∷ []
flatten (u ⊗ v) = flatten u ++ flatten v

map-pure : ∀ {t} (f : A → B) (x : A) → map {t = t} f (pure x) ≡ pure (f x)
map-pure {t = leaf}     f x = refl
map-pure {t = node l r} f x = cong₂ _⊗_ (map-pure f x) (map-pure f x)

------------------------------------------------------------------------
-- Predicates on tip vectors

-- Some tip satisfies P.
data Any {p} {A : Set a} (P : A → Set p) : ∀ {t} → TVec A t → Set (a Level.⊔ p) where
  at    : ∀ {x} → P x → Any P (tip x)
  left  : ∀ {l r} {u : TVec A l} {v : TVec A r} → Any P u → Any P (u ⊗ v)
  right : ∀ {l r} {u : TVec A l} {v : TVec A r} → Any P v → Any P (u ⊗ v)

-- Every tip satisfies P.
data All {p} {A : Set a} (P : A → Set p) : ∀ {t} → TVec A t → Set (a Level.⊔ p) where
  at   : ∀ {x} → P x → All P (tip x)
  both : ∀ {l r} {u : TVec A l} {v : TVec A r} → All P u → All P v → All P (u ⊗ v)

any-pure : ∀ {p} {P : A → Set p} {t} {x} → P x → Any P (pure {t = t} x)
any-pure {t = leaf}     px = at px
any-pure {t = node l r} px = left (any-pure px)

all-pure : ∀ {p} {P : A → Set p} {t} {x} → P x → All P (pure {t = t} x)
all-pure {t = leaf}     px = at px
all-pure {t = node l r} px = both (all-pure px) (all-pure px)

------------------------------------------------------------------------
-- The comb (caterpillar) tree: ((((1,2),3),4),...). It is the tree whose
-- balances are the Helmert contrasts that MetaManifold uses by default.

comb : ℕ → Tree
comb zero    = leaf
comb (suc n) = node (comb n) leaf

comb-leaves : ∀ n → leaves (comb n) ≡ suc n
comb-leaves zero    = refl
comb-leaves (suc n) = trans (cong (_+ 1) (comb-leaves n)) (+-comm (suc n) 1)
