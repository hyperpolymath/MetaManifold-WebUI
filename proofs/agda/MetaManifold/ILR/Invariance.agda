-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Invariance of balances.
--
-- Exact part (any commutative ring): a balance is linear in the
-- log-scale data and blind to adding a constant to every part.
--
-- Transcendental seam: `LogHom` is a *named assumption*, not a
-- postulate — a map from a commutative monoid (think: positive reals
-- under ×) into the ring that turns products into sums. Every theorem
-- that uses it takes it as an argument. From it:
--
--   * `balance-perturb`: Aitchison perturbation x ⊕ y (partwise
--     product) becomes addition of balance vectors;
--   * `balance-scale-invariant`: multiplying every part of a sample by
--     the same positive factor — library size, closure to proportions,
--     any per-sample scaling — leaves every balance unchanged.
--
-- The second is why ILR balances are computed on counts or proportions
-- interchangeably, and why sample-level scaling factors (issue #16) do
-- not interact with the choice of ILR basis (issue #20).
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

open import Algebra.Bundles using (CommutativeRing; CommutativeMonoid)

module MetaManifold.ILR.Invariance {c ℓ} (R : CommutativeRing c ℓ) where

open CommutativeRing R
open import Data.Product.Base using (_,_)
open import Level using (_⊔_; suc)
open import Relation.Binary.PropositionalEquality.Core as ≡ using (_≡_)
open import Relation.Binary.Reasoning.Setoid setoid

open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum R
open import MetaManifold.ILR.Contrast R

private
  variable t : Tree

------------------------------------------------------------------------
-- Exact invariance

balance-+ : ∀ (w : TVec Carrier t) n x y →
            balance w n (x +ᵥ y) ≈ balance w n x + balance w n y
balance-+ w n = wdot-+ʳ w (contrast w n)

balance-· : ∀ (w : TVec Carrier t) n k x → balance w n (k ·ᵥ x) ≈ k * balance w n x
balance-· w n = wdot-·ʳ w (contrast w n)

balance-constant : ∀ (w : TVec Carrier t) n k → balance w n (pure k) ≈ 0#
balance-constant w n k =
  trans (wdot-pureʳ w (contrast w n) k)
        (trans (*-congˡ (contrast-sum-zero w n)) (zeroʳ k))

balance-shift-invariant : ∀ (w : TVec Carrier t) n x k →
                          balance w n (x +ᵥ pure k) ≈ balance w n x
balance-shift-invariant w n x k =
  trans (balance-+ w n x (pure k))
        (trans (+-congˡ (balance-constant w n k)) (+-identityʳ _))

balance-cong : ∀ (w : TVec Carrier t) n {x y} → x ≋ y → balance w n x ≈ balance w n y
balance-cong w n = wdot-congʳ w (contrast w n)

------------------------------------------------------------------------
-- The log seam

record LogHom {m ℓm} (M : CommutativeMonoid m ℓm) : Set (c ⊔ ℓ ⊔ m ⊔ ℓm) where
  open CommutativeMonoid M using () renaming (Carrier to Pos; _∙_ to _×ₘ_)
  field
    log     : Pos → Carrier
    log-hom : ∀ a b → log (a ×ₘ b) ≈ log a + log b

module _ {m ℓm} {M : CommutativeMonoid m ℓm} (L : LogHom M) where
  open CommutativeMonoid M using () renaming (Carrier to Pos; _∙_ to _×ₘ_)
  open LogHom L

  -- Aitchison perturbation: partwise product.
  perturb : TVec Pos t → TVec Pos t → TVec Pos t
  perturb = zipWith _×ₘ_

  logs : TVec Pos t → TVec Carrier t
  logs = map log

  logs-perturb : ∀ (x y : TVec Pos t) → logs (perturb x y) ≋ logs x +ᵥ logs y
  logs-perturb (tip a) (tip b) = log-hom a b
  logs-perturb (u ⊗ v) (u′ ⊗ v′) = logs-perturb u u′ , logs-perturb v v′

  balance-perturb : ∀ (w : TVec Carrier t) n x y →
    balance w n (logs (perturb x y)) ≈ balance w n (logs x) + balance w n (logs y)
  balance-perturb w n x y =
    trans (balance-cong w n (logs-perturb x y)) (balance-+ w n (logs x) (logs y))

  balance-scale-invariant : ∀ (w : TVec Carrier t) n x (λ′ : Pos) →
    balance w n (logs (perturb x (pure λ′))) ≈ balance w n (logs x)
  balance-scale-invariant {t} w n x λ′ = begin
    balance w n (logs (perturb x (pure λ′)))       ≈⟨ balance-perturb w n x (pure λ′) ⟩
    balance w n (logs x) + balance w n (logs (pure λ′))
      ≈⟨ +-congˡ (balance-cong w n (≡⇒≋ {t = t} (map-pure log λ′))) ⟩
    balance w n (logs x) + balance w n (pure (log λ′))
      ≈⟨ +-congˡ (balance-constant w n (log λ′)) ⟩
    balance w n (logs x) + 0#                      ≈⟨ +-identityʳ _ ⟩
    balance w n (logs x)                           ∎
