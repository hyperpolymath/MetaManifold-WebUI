-- SPDX-License-Identifier: AGPL-3.0-only
-- MUST FAIL: a contrast is not orthogonal to itself (its norm is
-- r·s·(r+s) = 1·1·2 = 2 here, not 0). Checks that orthogonality is not
-- vacuously provable, e.g. by a definition collapsing to zero.
-- EXPECT: 2 != 0
{-# OPTIONS --safe --without-K #-}
module reject.OrthogonalSelf where

open import Data.Integer.Base using (0ℤ; 1ℤ)
open import Data.Integer.Properties using (+-*-commutativeRing)
open import Relation.Binary.PropositionalEquality using (_≡_; refl)
open import MetaManifold.Composition.Tree
open import MetaManifold.Composition.Node
open import MetaManifold.Composition.Sum +-*-commutativeRing
open import MetaManifold.ILR.Contrast +-*-commutativeRing

w : TVec _ (node leaf leaf)
w = tip 1ℤ ⊗ tip 1ℤ

bad : wdot w (contrast w here) (contrast w here) ≡ 0ℤ
bad = refl
