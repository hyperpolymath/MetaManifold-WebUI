-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Decimal rounding of an exact rational, specified and checked.
--
-- Issue #1 requires that a number crossing from exact arithmetic into display
-- text is *rounded by a stated rule*, and that the rule is the one the printed
-- digits obey.  This module states two rules as predicates, shows the primary
-- one is decidable, and then instantiates them at the exact values the Julia
-- conformance tests compare against — so a known-answer vector is not a number
-- somebody typed into two places, but a value a proof assistant has checked
-- against the definition of "correctly rounded".
--
-- Both rules say `|n/(d+1) − m/10^s| ≤ 1/(2·10^s)`; they differ only in which
-- side of an exact half is taken, and that difference is entirely visible in the
-- strictness of the two inequalities.  Nothing about tie handling is hidden in a
-- library's defaults:
--
--   * `IsRounding`    — `2n·10^s − (d+1) ≤ 2m(d+1) < 2n·10^s + (d+1)`,
--     which takes the exact half *downwards* (`1/2` at 0 dp is `0`).
--   * `IsRoundHalfUp` — `2m(d+1) − (d+1) ≤ 2n·10^s < 2m(d+1) + (d+1)`,
--     which takes it *upwards* (`1/2` at 0 dp is `1`).
--
-- Which one the display layer must use is a contract decision; that the two are
-- different, and exactly where, is what these definitions record.

{-# OPTIONS --without-K --safe #-}

module MetaManifold.DecimalRounding where

open import MetaManifold.Prelude

open import Data.Integer as ℤ
  using (ℤ; +_; +0; +[1+_]; -[1+_]; -_; _*_; _+_; _-_; _≤_; _<_)
open import Data.Integer.Properties as ℤₚ using (_≤?_; _<?_)
open import Data.Nat.Base as ℕ using (ℕ; zero; suc)
open import Data.Product using (_×_; _,_)
open import Relation.Nullary.Decidable using (Dec; yes; no; toWitness)

------------------------------------------------------------------------
-- The scale and the two specs

pow10 : ℕ → ℤ
pow10 zero    = + 1
pow10 (suc s) = pow10 s * + 10

-- `m` is `n/(d+1)` rounded to `s` decimal places, exact halves going down.
-- Written entirely with integers: no division, so there is no rounding inside
-- the specification of rounding.
IsRounding : ℤ → ℕ → ℕ → ℤ → Set
IsRounding n d s m =
  (+ 2 * (n * pow10 s) - +[1+ d ] ℤ.≤ + 2 * m * +[1+ d ])
  × (+ 2 * m * +[1+ d ] ℤ.< + 2 * (n * pow10 s) + +[1+ d ])

-- The same tolerance with exact halves going up.
IsRoundHalfUp : ℤ → ℕ → ℕ → ℤ → Set
IsRoundHalfUp n d s m =
  (+ 2 * m * +[1+ d ] - +[1+ d ] ℤ.≤ + 2 * (n * pow10 s))
  × (+ 2 * (n * pow10 s) ℤ.< + 2 * m * +[1+ d ] + +[1+ d ])

-- The primary spec is decidable, so a harness can ask it of any candidate
-- instead of trusting a second implementation of the same rule.
isRounding? : ∀ n d s m → Dec (IsRounding n d s m)
isRounding? n d s m
  with + 2 * (n * pow10 s) - +[1+ d ] ℤ.≤? + 2 * m * +[1+ d ]
... | no ¬lo = no (λ where (lo , _) → ¬lo lo)
... | yes lo
  with + 2 * m * +[1+ d ] ℤ.<? + 2 * (n * pow10 s) + +[1+ d ]
...   | no ¬hi = no (λ where (_ , hi) → ¬hi hi)
...   | yes hi = yes (lo , hi)

------------------------------------------------------------------------
-- Known-answer vectors
--
-- Each of these is a decimal the application prints.  The proofs are `toWitness`
-- applied to a decision procedure, so the check is computation, not assertion:
-- if the digits did not satisfy the rounding spec, these definitions would fail
-- to type-check.  These are the same values the Julia conformance testset reads
-- out of `test/fixtures/`.

-- 2/3 to two decimals is 0.67.   (2·2·100 − 3 = 397 ≤ 2·67·3 = 402 < 403)
rounding-2/3-at-2dp : IsRounding (+ 2) 2 2 (+ 67)
rounding-2/3-at-2dp =
  toWitness {a? = + 397 ℤ.≤? + 402} _ , toWitness {a? = + 402 ℤ.<? + 403} _

-- 1/3 to two decimals is 0.33.   (197 ≤ 198 < 203)
rounding-1/3-at-2dp : IsRounding (+ 1) 2 2 (+ 33)
rounding-1/3-at-2dp =
  toWitness {a? = + 197 ℤ.≤? + 198} _ , toWitness {a? = + 198 ℤ.<? + 203} _

-- 5/8 to three decimals is 0.625, exactly representable, so no tie arises.
-- (2·5·1000 − 8 = 9992 ≤ 2·625·8 = 10000 < 10008)
rounding-5/8-at-3dp : IsRounding (+ 5) 7 3 (+ 625)
rounding-5/8-at-3dp =
  toWitness {a? = + 9992 ℤ.≤? + 10000} _ , toWitness {a? = + 10000 ℤ.<? + 10008} _

-- Zero stays zero at any precision: the rounding of an exact zero is zero, not
-- a small number that merely prints as zero.  (−1 ≤ 0 < 1 at 2 dp for 0/1)
rounding-zero-at-2dp : IsRounding (+ 0) 0 2 (+ 0)
rounding-zero-at-2dp =
  toWitness {a? = (-[1+ 0 ]) ℤ.≤? + 0} _ , toWitness {a? = + 0 ℤ.<? + 1} _

-- One whole stays one: rounding must not introduce error where there is none.
-- (2·1·100 − 1 = 199 ≤ 2·100·1 = 200 < 201)
rounding-one-at-2dp : IsRounding (+ 1) 0 2 (+ 100)
rounding-one-at-2dp =
  toWitness {a? = + 199 ℤ.≤? + 200} _ , toWitness {a? = + 200 ℤ.<? + 201} _

------------------------------------------------------------------------
-- The tie
--
-- At an exact half the two specs disagree, and each is the one its own
-- inequalities select.  This is the pair of definitions that makes "which way
-- do halves go?" answerable by reading the code rather than by running it.

-- 1/2 at zero decimals is 0 under `IsRounding`.   (2 − 2 = 0 ≤ 0 < 2 + 2 = 4)
half-ties-round-down : IsRounding (+ 1) 1 0 (+ 0)
half-ties-round-down =
  toWitness {a? = + 0 ℤ.≤? + 0} _ , toWitness {a? = + 0 ℤ.<? + 4} _

-- …and 1 under `IsRoundHalfUp`.   (2·1·2 − 2 = 2 ≤ 2 < 2·1·2 + 2 = 6)
half-ties-round-up : IsRoundHalfUp (+ 1) 1 0 (+ 1)
half-ties-round-up =
  toWitness {a? = + 2 ℤ.≤? + 2} _ , toWitness {a? = + 2 ℤ.<? + 6} _

-- The two rules agree wherever there is no tie.  Stated for the vectors above,
-- which are the ones the shipped code prints: 2/3, 1/3, 5/8 and 1 all round the
-- same under either rule, so the tie direction is the *only* thing the contract
-- decision can change.
agreement-2/3 : IsRoundHalfUp (+ 2) 2 2 (+ 67)
agreement-2/3 =
  toWitness {a? = + 399 ℤ.≤? + 400} _ , toWitness {a? = + 400 ℤ.<? + 405} _

agreement-1/3 : IsRoundHalfUp (+ 1) 2 2 (+ 33)
agreement-1/3 =
  toWitness {a? = + 195 ℤ.≤? + 200} _ , toWitness {a? = + 200 ℤ.<? + 201} _

agreement-5/8 : IsRoundHalfUp (+ 5) 7 3 (+ 625)
agreement-5/8 =
  toWitness {a? = + 9992 ℤ.≤? + 10000} _ , toWitness {a? = + 10000 ℤ.<? + 10008} _

agreement-one : IsRoundHalfUp (+ 1) 0 2 (+ 100)
agreement-one =
  toWitness {a? = + 199 ℤ.≤? + 200} _ , toWitness {a? = + 200 ℤ.<? + 201} _
