-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- The comb tree reproduces MetaManifold's default (Helmert) ILR basis.
--
-- src/analysis/Execution.jl's default basis is, for i = 1 … D-1,
--
--     ilr_i = sqrt(i/(i+1)) · ( mean(log x₁ … log xᵢ) - log xᵢ₊₁ )
--
-- whose unnormalised contrast is (1, …, 1, -i, 0, …, 0) with i ones.
-- `helmert` below is that row, defined without reference to trees. The
-- theorem says the balances of the comb tree ((…((1,2),3)…),D) under
-- uniform weights are exactly these rows, and its masses are r = i,
-- s = 1, so the normalising constant 1/sqrt(r·s·(r+s)) turns
-- i·(mean - log xᵢ₊₁) into sqrt(i/(i+1))·(mean - log xᵢ₊₁).
--
-- Order: the tree's preorder visits the root first, and the comb's root
-- is Helmert's *last* balance (all D-1 first parts against part D).
-- `index` numbers the comb's balances in preorder; row `k` of the
-- preorder is Helmert balance i = D-1-k. The Julia equivalence test maps
-- indices explicitly rather than assuming the two orders agree.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

open import Algebra.Bundles using (CommutativeRing)

module MetaManifold.ILR.Comb {c ℓ} (R : CommutativeRing c ℓ) where

open CommutativeRing R hiding (zero)
open import Data.Fin.Base using (Fin; zero; suc; toℕ)
open import Data.Fin.Properties using (toℕ-↑ˡ)
open import Data.Nat.Base using (ℕ; zero; suc) renaming (_+_ to _+ℕ_)
import Data.Nat.Properties as ℕ
open import Data.Product.Base using (_×_; _,_)
open import Data.Vec.Base using (Vec; []; _∷_; _++_; _∷ʳ_; replicate)
open import Data.Vec.Relation.Binary.Pointwise.Inductive using (Pointwise; []; _∷_)
open import Relation.Binary.PropositionalEquality.Core as ≡ using (_≡_; cong; subst)

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum R
open import MetaManifold.ILR.Contrast R

-- n as a ring element: 1 + 1 + … + 1.
count : ℕ → Carrier
count zero    = 0#
count (suc n) = 1# + count n

-- Helmert rows, in the comb tree's preorder: row zero of `helmert n`
-- is Julia's balance_{n} (first n parts against part n+1).
helmert : ∀ n → Fin n → Vec Carrier (suc n)
helmert (suc n) zero    = replicate (suc n) 1# ∷ʳ - count (suc n)
helmert (suc n) (suc k) = helmert n k ∷ʳ 0#

uniform : ∀ {t} → TVec Carrier t
uniform = pure 1#

-- Preorder number of a comb balance, as a Fin n.
index : ∀ {n} → Node (comb n) → Fin n
index {suc n} here    = zero
index {suc n} (inl i) = suc (index i)

-- `index` is the preorder numbering `toFin` of Node.agda.
index-is-preorder : ∀ {n} (i : Node (comb n)) → toℕ (toFin i) ≡ toℕ (index i)
index-is-preorder {suc n} here    = ≡.refl
index-is-preorder {suc n} (inl i) =
  cong suc (≡.trans (toℕ-↑ˡ (toFin i) 0) (index-is-preorder i))

total-uniform-comb : ∀ n → total (uniform {comb n}) ≈ count (suc n)
total-uniform-comb zero    = sym (+-identityʳ 1#)
total-uniform-comb (suc n) = trans (+-congʳ (total-uniform-comb n)) (+-comm _ 1#)

-- Julia's balance number i for a comb balance: the size of its
-- numerator clade.
julia-index : ∀ {n} → Node (comb n) → ℕ
julia-index {suc n} here    = suc n
julia-index {suc n} (inl i) = julia-index i

-- i = D - 1 - k, i.e. i + k = n (= D - 1) with k the preorder number.
julia-index-reverses : ∀ {n} (i : Node (comb n)) → julia-index i +ℕ toℕ (index i) ≡ n
julia-index-reverses {suc n} here    = ℕ.+-identityʳ (suc n)
julia-index-reverses {suc n} (inl i) =
  ≡.trans (ℕ.+-suc (julia-index i) (toℕ (index i))) (cong suc (julia-index-reverses i))

-- Masses: r = i, s = 1 (so 1/sqrt(r·s·(r+s)) = 1/sqrt(i(i+1))).
comb-masses : ∀ n (i : Node (comb n)) →
  plus-mass uniform i ≈ count (julia-index i) × minus-mass uniform i ≈ 1#
comb-masses (suc n) here    = total-uniform-comb n , refl
comb-masses (suc n) (inl i) = comb-masses n i

------------------------------------------------------------------------
-- The theorem

private
  -- flatten appends with _++_, Helmert rows with _∷ʳ_.
  snoc⁺ : ∀ {m n} {xs : Vec Carrier m} {ys : Vec Carrier n} {x y} →
          Pointwise _≈_ xs ys → x ≈ y → Pointwise _≈_ (xs ++ x ∷ []) (ys ∷ʳ y)
  snoc⁺ []           x≈y = x≈y ∷ []
  snoc⁺ (e ∷ es)     x≈y = e ∷ snoc⁺ es x≈y

  replicate-snoc : ∀ n (k : Carrier) → replicate (suc n) k ≡ replicate n k ∷ʳ k
  replicate-snoc zero    k = ≡.refl
  replicate-snoc (suc n) k = cong (k ∷_) (replicate-snoc n k)

  flatten-pure-comb : ∀ n k → Pointwise _≈_ (flatten (pure {t = comb n} k)) (replicate (suc n) k)
  flatten-pure-comb zero    k = refl ∷ []
  flatten-pure-comb (suc n) k =
    subst (Pointwise _≈_ (flatten (pure {t = comb n} k) ++ k ∷ []))
          (≡.sym (replicate-snoc (suc n) k))
          (snoc⁺ (flatten-pure-comb n k) refl)

comb-is-helmert : ∀ n (i : Node (comb n)) →
  Pointwise _≈_ (flatten (contrast uniform i)) (helmert n (index i))
comb-is-helmert (suc n) here =
  snoc⁺ (flatten-pure-comb n 1#) (-‿cong (total-uniform-comb n))
comb-is-helmert (suc n) (inl i) =
  snoc⁺ (comb-is-helmert n i) refl
