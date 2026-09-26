-- SPDX-License-Identifier: AGPL-3.0-only
-- MUST FAIL: `--safe` (set in metamanifold-proofs.agda-lib, deliberately
-- NOT repeated in a pragma here) forbids postulates. Guards against the
-- library flags being dropped.
-- EXPECT: [Pp]ostulate
module reject.Postulate where

open import Relation.Binary.PropositionalEquality using (_≡_)
open import MetaManifold.Composition.Tree

postulate every-tree-is-a-leaf : (t : Tree) → t ≡ leaf
