-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Benjamini–Hochberg scaling, as exact rational arithmetic.
--
-- The step that turns a p-value into a q-value is a multiplication by
-- `M/(j+1)`: the family size over the rank.  Two things about it are worth
-- proving rather than trusting, because both are easy to get wrong in a way
-- that no test on a small example would catch.
--
--   * `bhScale-is-the-scaled-p` — the adjustment *is* that product, exactly,
--     with no intermediate rounding.  A q-value produced by a floating-point
--     pipeline is a rounded version of this; stating the exact target is what
--     makes "rounded" a measurable deviation rather than an undefined one.
--   * `monotone-in-family-size` — adding tests to the family can never make a
--     q-value smaller.  A multiplicity correction that went the other way would
--     reward running more tests, and would do so silently.
--
-- The second needs non-negativity of `n` as a hypothesis, and that is not a
-- formality: the scaling multiplies the numerator, so a negative numerator would
-- reverse the inequality.  A p-value's numerator is a count and so is
-- non-negative, but the theorem says so rather than assuming it.
--
-- Everything here is over `ℚᵘ`, the unnormalised rationals, so no gcd
-- normalisation step sits between the arithmetic and the proof.

{-# OPTIONS --without-K --safe #-}

module MetaManifold.BenjaminiHochberg where

open import MetaManifold.Prelude

open import Data.Integer as ℤ
  using (ℤ; +_; +0; +[1+_]; -[1+_]; _*_; _+_; _≤_; NonNegative)
open import Data.Integer.Properties as ℤₚ
  using (*-monoˡ-≤-nonNeg; *-monoʳ-≤-nonNeg; ≤-trans; ≤-reflexive; *-comm; *-zeroʳ)
open import Data.Nat.Base as ℕ using (ℕ; zero; suc; z≤n)
open import Relation.Binary.PropositionalEquality using (_≡_; refl; sym)
open import Data.Rational.Unnormalised
  using (ℚᵘ; mkℚᵘ; _≃_; ↥_; ↧_; ↧ₙ_; 0ℚᵘ; 1ℚᵘ)
  renaming (_≤_ to _≤ℚ_)

------------------------------------------------------------------------
-- The scaling step

-- `M/(j+1) · n/(d+1)`, written with the denominator expanded so that the
-- fraction is built by a single `mkℚᵘ` and carries no intermediate rounding.
--
-- `j` is a zero-based rank: rank 0 is the smallest p-value in the family and is
-- multiplied by `M/1`.  `d + 1` is the denominator of the p-value being scaled,
-- so `j + d + j * d` is `(j+1)(d+1) - 1` — the denominator-minus-one that
-- `mkℚᵘ` expects.  The ℕ arithmetic is written qualified because ℤ's operators
-- are in scope unqualified; the two must not be confused here.
bhScale : ℕ → ℕ → ℤ → ℕ → ℚᵘ
bhScale M j n d = mkℚᵘ (+ M * n) (j ℕ.+ d ℕ.+ j ℕ.* d)

-- "Multiply by `M/(j+1)`" means exactly what it says: the numerator of the
-- result is `M·n` and its denominator is `(j+1)·(d+1)`.  Stated on the accessors
-- and closed by `refl`.  The `suc` on the right is the point: `ℚᵘ` stores a
-- denominator-minus-one, so `(j+1)(d+1)` is `suc (j + d + j*d)`, and writing it
-- this way leaves no room for an off-by-one to hide between the two forms.
bhScale-numerator : ∀ M j n d → ↥ (bhScale M j n d) ≡ + M * n
bhScale-numerator M j n d = refl

bhScale-denominator :
  ∀ M j n d → ↧ₙ (bhScale M j n d) ≡ suc (j ℕ.+ d ℕ.+ j ℕ.* d)
bhScale-denominator M j n d = refl

-- A bigger family can never produce a smaller q-value.  The denominator is
-- untouched by `M`, so this is a comparison of numerators over a common
-- denominator — `numerator-monotone-≤` from the Prelude, not a hand-built
-- cross-multiplication.
monotone-in-family-size :
  ∀ M M′ j n d → M ℕ.≤ M′ → .{{_ : ℤ.NonNegative n}} →
  bhScale M j n d ≤ℚ bhScale M′ j n d
monotone-in-family-size M M′ j n d M≤M′ {{np}} =
  numerator-monotone-≤ (+ M * n) (+ M′ * n) (j ℕ.+ d ℕ.+ j ℕ.* d)
    (ℤₚ.≤-trans (ℤₚ.≤-reflexive (ℤₚ.*-comm (+ M) n))
      (ℤₚ.≤-trans (ℤₚ.*-monoˡ-≤-nonNeg n {{np}} (ℤ.+≤+ M≤M′))
                  (ℤₚ.≤-reflexive (ℤₚ.*-comm n (+ M′)))))
-- Non-negativity of the scaled value is left as an open obligation, recorded in
-- `proofs/residue/benjamini-hochberg.residue`.  The obstacle is mechanical, not
-- conceptual: `+ M * + n` does not reduce to `+ (M ℕ.* n)`, so the non-negativity
-- lemmas in `Data.Integer.Properties`, which are stated about the reduced form,
-- do not apply directly, and the sign/absolute-value form `ℤ._*_` actually
-- unfolds to needs its own transport.  It is not asserted here instead.
