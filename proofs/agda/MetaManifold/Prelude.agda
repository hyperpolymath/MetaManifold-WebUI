-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Foundations for the machine-checked core of MetaManifold's statistics layer
-- (issue #1).
--
-- This module exists to make one design decision checkable rather than merely
-- stated.  `src/analysis/numeric_policy.jl` refuses to produce a proportion
-- whose denominator is zero, because Julia's own `//` will happily answer `1//0`
-- and that non-finite Rational goes on to render in a chart as if it were a
-- number.  Here the same fact is a property of the *type*: the denominator of a
-- `ℚᵘ` is `suc denominator-1`, so zero is not a denominator this type can hold
-- at all.  Every refusal below therefore has somewhere to go that is not a
-- number, and every value that does come back is provably a real quotient.
--
-- Everything in `proofs/agda` is built on this file plus the Agda standard
-- library and nothing else.  There are no `postulate`s anywhere in the tree;
-- `proofs/tests/axiom-audit.sh` checks that, and checks its own control.

{-# OPTIONS --without-K --safe #-}

module MetaManifold.Prelude where

open import Data.Bool.Base using (Bool; true; false)
open import Data.Empty using (⊥; ⊥-elim)
open import Data.Integer as ℤ using (ℤ; +_; +0; +[1+_]; -[1+_]; _*_; _+_; _≤_; _<_; nonNegative)
open import Data.Integer.Properties as ℤₚ
  using (pos-*; pos-+; *-comm; *-zeroˡ; _≡?_; *-monoʳ-≤-nonNeg)
  renaming (+-*-commutativeRing to +-*-commutativeRingℤ)
open import Data.Nat.Base using (z≤n; s≤s)
open import Data.List.Base as List using (List; []; _∷_; map)
open import Data.Nat.Base as ℕ using (ℕ; zero; suc; NonZero; ≢-nonZero)
open import Data.Product using (Σ; Σ-syntax; ∃; ∃-syntax; _×_; _,_)
open import Data.Rational.Unnormalised
  using (ℚᵘ; mkℚᵘ; _≃_; ↥_; ↧_; ↧ₙ_; 0ℚᵘ; 1ℚᵘ)
  renaming (_+_ to _+ℚ_; _*_ to _*ℚ_; _/_ to _/ℚ_; _≤_ to _≤ℚ_; _<_ to _<ℚ_)
open import Data.Rational.Unnormalised.Base using (*≡*; *≤*; *<*)
open import Data.Rational.Unnormalised.Properties
  using (+-*-commutativeRing; ≃-isEquivalence; +-isMagma; *-isMagma)
open import Data.Sum.Base using (_⊎_; inj₁; inj₂)
open import Data.Vec.Base as Vec using (Vec; []; _∷_)
open import Function.Base using (_∘′_; const)
open import Relation.Binary using (Decidable)
open import Relation.Binary.PropositionalEquality
  using (_≡_; _≢_; refl; sym; trans; cong; cong₂; subst)
open import Relation.Nullary.Decidable using (yes; no)
open import Relation.Nullary.Negation using (¬_)

------------------------------------------------------------------------
-- Refusals
--
-- The statistics layer's job is not to always produce a number.  It is to
-- produce a number *or* name the reason it cannot.  These constructors are the
-- reasons; the comment on each names the exception it stands for in
-- `src/analysis/`.  A refusal is not an error path bolted on afterwards: it is
-- one arm of the same sum type as the answer, which is what makes
-- `outcome-total` below a theorem rather than a convention.

data Refusal : Set where
  -- UnsupportedRepresentationError("a proportion", "n/0", …)
  zeroTotal         : Refusal
  -- ArgumentError("count (c) exceeds total (t)")
  countExceedsTotal : Refusal
  -- ResourceLimitError("denominator", limit, observed)
  budgetExhausted   : Refusal
  -- CountOverflowError(left, right)
  overflow          : Refusal
  -- UnsupportedRepresentationError("an exactly-known count", …): a Float64
  -- past 2^53 cannot say which integer it holds.
  unprovenCount     : Refusal

data Outcome (A : Set) : Set where
  value   : A → Outcome A
  refused : Refusal → Outcome A

-- There is no third arm.  This looks trivial and it is the point: "the answer is
-- either the exact value or a named refusal" is a statement about the shape of
-- the type, so a later edit that forgets a case cannot violate it quietly.
outcome-total : ∀ {A} (o : Outcome A) →
                (∃ λ a → o ≡ value a) ⊎ (∃ λ r → o ≡ refused r)
outcome-total (value a)   = inj₁ (a , refl)
outcome-total (refused r) = inj₂ (r , refl)

-- A refusal is never a value.  Stated because the whole layer's safety story
-- rests on the two arms not being confused downstream: a `nothing` that reaches
-- a chart as `0.0` is exactly the failure mode the refusals exist to prevent.
refused≢value : ∀ {A} {a : A} {r : Refusal} → value a ≢ refused r
refused≢value ()

is-value : ∀ {A} → Outcome A → Bool
is-value (value _)   = true
is-value (refused _) = false

------------------------------------------------------------------------
-- Exact rationals
--
-- `ℚᵘ` is the *unnormalised* rationals: an integer numerator and a positive
-- denominator, with equality `_≃_` by cross-multiplication.  Two reasons this
-- models `Rational{BigInt}` faithfully rather than approximately:
--
--   1. `Rational{BigInt}(n, d)` normalises by gcd, but normalising changes the
--      representation and never the value.  Every theorem here is about values
--      (`_≃_`), so each one transfers to the normalised form unchanged.
--   2. The denominator is `suc _` by construction, so the zero-denominator case
--      is unrepresentable rather than checked-and-hoped-for.

infix 4 _≟ℚᵘ_

_≟ℚᵘ_ : Decidable _≃_
p ≟ℚᵘ q with (↥ p * ↧ q) ≡? (↥ q * ↧ p)
... | yes e  = yes (*≡* e)
... | no  ¬e = no (λ where (*≡* e) → ¬e e)

-- Setoid structure over `_≃_`, so `≃-Reasoning` chains are available.
open import Algebra.Structures using (IsMagma)
open import Relation.Binary.Structures using (IsEquivalence)
open IsEquivalence ≃-isEquivalence public
  using () renaming (refl to ≃-refl; sym to ≃-sym; trans to ≃-trans)

-- Congruence of the two operations, taken from the library's own structures
-- rather than re-proved.
open IsMagma +-isMagma public using () renaming (∙-cong to +-cong-≃)
open IsMagma *-isMagma public using () renaming (∙-cong to *-cong-≃)

-- Ring solvers, so that rational and integer identities are discharged by
-- computation rather than by hand-written chains.  The ℚᵘ one is what makes
-- "the proportions of a sample sum to exactly one" a one-line proof instead of
-- a page of `*-assoc`.
open import Algebra.Solver.Ring.AlmostCommutativeRing using (fromCommutativeRing)
import Algebra.Solver.Ring.Simple as RingSolver

module ℚᵘ-Solver = RingSolver (fromCommutativeRing +-*-commutativeRing) _≟ℚᵘ_
open ℚᵘ-Solver public using (con; _:+_; _:*_; _:=_) renaming (solve to solve-ℚ)

module ℤ-Solver = RingSolver (fromCommutativeRing +-*-commutativeRingℤ) _≡?_
open ℤ-Solver public using ()
  renaming (solve to solve-ℤ; _:=_ to _:=ℤ_; con to conℤ; _:+_ to _:+ℤ_; _:*_ to _:*ℤ_)

-- `n/d` with the positivity proof made explicit.  `_/ℚ_` wants a `NonZero`
-- instance; this turns the proof a caller already holds into one.
_/[_]_ : (n : ℤ) (d : ℕ) → d ≢ 0 → ℚᵘ
n /[ d ] p = _/ℚ_ n d {{ℕ.≢-nonZero p}}

infixl 7 _/[_]_

-- The two facts about quotients that everything else is built from.

-- `a/d + b/d ≃ (a + b)/d`: proportions over a common total add by adding their
-- counts.  This single lemma is why the exact relative abundances of one sample
-- sum to exactly one, with no rounding anywhere in the chain.
common-denominator-+ : ∀ (a b : ℤ) (d : ℕ) →
                       mkℚᵘ a d +ℚ mkℚᵘ b d ≃ mkℚᵘ (a + b) d
common-denominator-+ a b d = *≡* cross
  where
  -- ↥(p+q) · ↧r  ≡  ↥r · ↧(p+q), where p = a/d, q = b/d, r = (a+b)/d:
  --   (a·(1+d) + b·(1+d)) · (1+d)  ≡  (a+b) · ((1+d)·(1+d))
  cross : (a * +[1+ d ] + b * +[1+ d ]) * +[1+ d ]
          ≡ (a + b) * +[1+ d ℕ.+ d ℕ.* suc d ]
  cross = trans
    (solve-ℤ 3 (λ a b d → (a :*ℤ d :+ℤ b :*ℤ d) :*ℤ d :=ℤ (a :+ℤ b) :*ℤ (d :*ℤ d))
       refl a b (+[1+ d ]))
    (cong ((a + b) *_) (sym (ℤₚ.pos-* (suc d) (suc d))))

-- `n/n ≃ 1`: the whole of a sample is the whole.
--
-- Note what is *absent* from this statement: no side condition that `n` is
-- non-zero.  In `ℚᵘ` the denominator is `suc _`, so `n/n` here means
-- `(n+1)/(n+1)` and the zero-denominator case is not a case this type has.  The
-- Julia layer has to *check* for it at runtime, because `Rational{BigInt}` and
-- `//` both admit `1//0`; here there is nothing to check.  That is the precise
-- sense in which the refusals in this development are total.
whole-is-one : ∀ (n : ℕ) → mkℚᵘ (+[1+ n ]) n ≃ 1ℚᵘ
whole-is-one n = *≡* (*-comm (+[1+ n ]) (+[1+ 0 ]))

-- `0/n ≃ 0`: a feature absent from a sample that has reads at all is exactly
-- zero.  That is a different claim from the sample having no reads, which is
-- refused rather than reported as zero.
zero-over : ∀ (d : ℕ) → mkℚᵘ (+ 0) d ≃ 0ℚᵘ
zero-over d = *≡* (trans (ℤₚ.*-zeroˡ (+[1+ 0 ])) (sym (ℤₚ.*-zeroˡ (+[1+ d ]))))

------------------------------------------------------------------------
-- Sums
--
-- The Julia layer sums counts with `checked_count_sum` and rationals with
-- `exact_rational_sum`, and the two do not share an identity element on the
-- empty collection: an empty count sum is `0` (nothing was read) but an empty
-- rational sum is `nothing`, because "the values add up to none" is not the same
-- claim as "the values add up to zero".  Keeping those apart is why the sums
-- below are separate definitions.

-- Written out rather than taken from a library fold, so that the identity
-- element each sum starts from is visible in the definition: `+0` for counts,
-- `0ℚᵘ` for rationals.  Neither is available for an empty collection of
-- *proportions*, which is why the analysis layer returns `nothing` there.
sumℤ : List ℤ → ℤ
sumℤ []       = +0
sumℤ (x ∷ xs) = x + sumℤ xs

sumℕ : List ℕ → ℕ
sumℕ []       = zero
sumℕ (x ∷ xs) = x ℕ.+ sumℕ xs

sumℚᵘ : List ℚᵘ → ℚᵘ
sumℚᵘ []       = 0ℚᵘ
sumℚᵘ (x ∷ xs) = x +ℚ sumℚᵘ xs

sumVecℤ : ∀ {n} → Vec ℤ n → ℤ
sumVecℤ []       = +0
sumVecℤ (x ∷ xs) = x + sumVecℤ xs

sumVecℕ : ∀ {n} → Vec ℕ n → ℕ
sumVecℕ []       = zero
sumVecℕ (x ∷ xs) = x ℕ.+ sumVecℕ xs

sumVecℚᵘ : ∀ {n} → Vec ℚᵘ n → ℚᵘ
sumVecℚᵘ []       = 0ℚᵘ
sumVecℚᵘ (x ∷ xs) = x +ℚ sumVecℚᵘ xs

-- Every count of a sample over the same denominator, as a vector of rationals.
-- This is the exact relative abundance of each feature before any rounding.
over-denominator : ∀ {n} (cs : Vec ℤ n) (d : ℕ) → Vec ℚᵘ n
over-denominator []       d = []
over-denominator (c ∷ cs) d = mkℚᵘ c d ∷ over-denominator cs d

-- Congruence of addition in its right argument, with the left one pinned.  The
-- library's `∙-cong` needs both arguments' endpoints named; naming the left pair
-- explicitly is what lets `≃-refl` infer which value is unchanged.
+-cong-≃ʳ : ∀ {u v w : ℚᵘ} → u ≃ v → (w +ℚ u) ≃ (w +ℚ v)
+-cong-≃ʳ {u} {v} {w} p = +-cong-≃ {w} {w} {u} {v} ≃-refl p

-- Summing with a common denominator distributes over the sum of the numerators.
-- This is the algebraic content of "aggregate counts, never average
-- proportions" (`src/analysis/exact_summaries.jl`), proved rather than asserted.
sum-over-common-denominator : ∀ (ns : List ℤ) (d : ℕ) →
                              sumℚᵘ (List.map (λ n → mkℚᵘ n d) ns)
                              ≃ mkℚᵘ (sumℤ ns) d
sum-over-common-denominator []       d = ≃-sym (zero-over d)
sum-over-common-denominator (n ∷ ns) d =
  ≃-trans {mkℚᵘ n d +ℚ sumℚᵘ (List.map (λ m → mkℚᵘ m d) ns)}
          {mkℚᵘ n d +ℚ mkℚᵘ (sumℤ ns) d}
          {mkℚᵘ (n + sumℤ ns) d}
    (+-cong-≃ʳ {sumℚᵘ (List.map (λ m → mkℚᵘ m d) ns)} {mkℚᵘ (sumℤ ns) d} {mkℚᵘ n d}
       (sum-over-common-denominator ns d))
    (common-denominator-+ n (sumℤ ns) d)

-- The same statement for the vector of counts in one sample, which is the shape
-- the analysis layer actually holds.
sumVec-over-common-denominator : ∀ {k} (cs : Vec ℤ k) (d : ℕ) →
                                 sumVecℚᵘ (over-denominator cs d)
                                 ≃ mkℚᵘ (sumVecℤ cs) d
sumVec-over-common-denominator []       d = ≃-sym (zero-over d)
sumVec-over-common-denominator (c ∷ cs) d =
  ≃-trans {mkℚᵘ c d +ℚ sumVecℚᵘ (over-denominator cs d)}
          {mkℚᵘ c d +ℚ mkℚᵘ (sumVecℤ cs) d}
          {mkℚᵘ (c + sumVecℤ cs) d}
    (+-cong-≃ʳ {sumVecℚᵘ (over-denominator cs d)} {mkℚᵘ (sumVecℤ cs) d} {mkℚᵘ c d}
       (sumVec-over-common-denominator cs d))
    (common-denominator-+ c (sumVecℤ cs) d)

-- Propositional equality implies value equality.  Used whenever a numerator is
-- rewritten by an ℕ or ℤ computation: the quotient changes representation, never
-- value, and this is the one step that carries that across.
≡⇒≃ : ∀ {p q : ℚᵘ} → p ≡ q → p ≃ q
≡⇒≃ {p} pq = subst (λ x → p ≃ x) pq ≃-refl

-- `+` preserves ℕ sums: the integer sum of the counts of a sample is the
-- integer image of their ℕ sum.  Without this, "the counts add up to the depth"
-- (an ℕ fact) could not be used where the rationals need an ℤ numerator.
sumVecℕ-map-+ : ∀ {n} (cs : Vec ℕ n) → sumVecℤ (Vec.map +_ cs) ≡ + sumVecℕ cs
sumVecℕ-map-+ []       = refl
sumVecℕ-map-+ (c ∷ cs) = trans (cong (λ x → + c + x) (sumVecℕ-map-+ cs)) (sym (ℤₚ.pos-+ c (sumVecℕ cs)))


-- Monotonicity of a quotient in its numerator: over a common denominator, the
-- order of the values *is* the order of the counts.  Used by the permutation
-- and multiple-testing modules, where every comparison is between quantities
-- that share a denominator by construction.
numerator-monotone-≤ :
  ∀ (n m : ℤ) (d : ℕ) → n ≤ m → mkℚᵘ n d ≤ℚ mkℚᵘ m d
numerator-monotone-≤ n m d n≤m =
  *≤* (ℤₚ.*-monoʳ-≤-nonNeg +[1+ d ] {{nonNegative (ℤ.+≤+ z≤n)}} n≤m)


-- Injectivity of the value arm, so a proof that two outcomes are the same
-- `value` yields a proof that the two numbers are the same number.
value-injective : ∀ {A} {a b : A} → value a ≡ value b → a ≡ b
value-injective refl = refl
