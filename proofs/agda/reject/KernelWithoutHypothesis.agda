-- SPDX-License-Identifier: AGPL-3.0-only
-- MUST FAIL: the kernel theorem without `Cancellable` is false
-- (MetaManifold.ILR.Integer.kernel-needs-hypothesis). If this ever
-- type-checks, a definition has been weakened. The only Cancellable
-- witnesses available are for specific weights, so using one for an
-- arbitrary w is a type error.
-- EXPECT: !=
{-# OPTIONS --safe --without-K #-}
module reject.KernelWithoutHypothesis where

open import Data.Integer.Base using (0ℤ)
open import Data.Integer.Properties using (+-*-commutativeRing)
open import Relation.Binary.PropositionalEquality using (_≡_)
open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Sum +-*-commutativeRing
open import MetaManifold.ILR.Contrast +-*-commutativeRing
open import MetaManifold.ILR.Kernel +-*-commutativeRing
open import MetaManifold.ILR.Integer using (uniform-cancellable)

bad : ∀ {t} (w x : TVec _ t) → wsum w x ≡ 0ℤ → (∀ n → balance w n x ≡ 0ℤ) → AllZero x
bad {t} w x = balance-kernel {w = w} (uniform-cancellable t) x
