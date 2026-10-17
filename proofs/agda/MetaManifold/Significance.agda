-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- A proposed publication interface, not a proof of the Julia representation.
-- This model stores numbers only in computed-result. Julia's AlphaSignificance
-- can retain pairwise rows after an omnibus failure, so the two representations
-- are not equivalent. No refinement mapping or extraction connects them.
-- The theorems below establish properties of this Agda interface only. They
-- establish neither statistical validity nor that Julia callers obey the gate.
-- A Julia integration needs explicit publication guards and regression tests.
-- Exact rationals and lists abstract Float64 p-values and DataFrame rows.

{-# OPTIONS --safe --without-K #-}

module MetaManifold.Significance where

open import Data.Bool using (Bool; true; false)
open import Data.List using (List; map)
open import Data.Rational using (ℚ)
open import Data.String using (String)
open import Relation.Nullary using (¬_)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; cong)

-- Julia's statuses: :computed, :r_unavailable, :no_paired_samples, :test_failed.
data Status : Set where
  computed r-unavailable no-paired-samples test-failed : Status

-- The discipline: the omnibus p-value and the pairwise p-values exist only
-- in the constructor that claims the test ran. A result that reveals nothing
-- names its status, carries a proof that the status is not `computed`, and a
-- reader-facing reason -- and no numbers, because there are none to read.
data AlphaSignificance : Set where
  computed-result  : (omnibus : ℚ) (pairwise : List ℚ) → AlphaSignificance
  reveals-nothing : (status : Status) → ¬ (status ≡ computed) → String → AlphaSignificance

-- The model's publication gate.
was-computed : AlphaSignificance → Bool
was-computed (computed-result _ _)   = true
was-computed (reveals-nothing _ _ _) = false

-- 1. Publishing the omnibus p-value requires evidence the test ran. On the
--    reveals-nothing branch the evidence is an inhabitant of `false ≡ true`,
--    which does not exist, so the branch cannot produce a number at all.
publish : (r : AlphaSignificance) → was-computed r ≡ true → ℚ
publish (computed-result omnibus _) refl = omnibus
publish (reveals-nothing _ _ _) ()

-- 2. The pairwise table, same discipline.
pairwise-published : (r : AlphaSignificance) → was-computed r ≡ true → List ℚ
pairwise-published (computed-result _ pairwise) refl = pairwise
pairwise-published (reveals-nothing _ _ _) ()

-- 3. The dual: the reader-facing reason can be read only from a result that
--    did not run. A computed result has no reason to show, and the evidence
--    it would need (`true ≡ false`) does not exist.
reason : (r : AlphaSignificance) → was-computed r ≡ false → String
reason (computed-result _ _) ()
reason (reveals-nothing _ _ why) refl = why

-- 4. The status of a result that did not run is never `computed`, by
--    construction: the proof obligation lives in the constructor, so a
--    `reveals-nothing` value cannot even be built with the `computed`
--    status.
unrun-status-not-computed :
  (s : Status) (h : ¬ (s ≡ computed)) (why : String) →
  let r = reveals-nothing s h why in was-computed r ≡ false
unrun-status-not-computed s h why = refl

-- The status of a computed result is `computed`, and its evidence is the
-- constructor's own shape -- so the two constructors never meet: a result
-- is either readable as numbers or readable as a reason, never both.
computed-status : (o : ℚ) (p : List ℚ) →
  was-computed (computed-result o p) ≡ true
computed-status o p = refl

-- Map every pairwise p-value through a function without changing the
-- publish discipline: reading remains possible only on the computed branch.
map-pairwise : (f : ℚ → ℚ) (r : AlphaSignificance) → was-computed r ≡ true → List ℚ
map-pairwise f (computed-result _ pairwise) refl = map f pairwise
map-pairwise f (reveals-nothing _ _ _) ()
