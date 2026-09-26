-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Exact counts and the overflow guard: the machine-checked counterpart of
-- `checked_count_sum` in `src/analysis/numeric_policy.jl`.
--
-- The hazard this module is about is the quiet one.  A sum of read counts that
-- leaves the range of `Int64` *wraps*: it comes back as a small number, or a
-- negative one, and every proportion computed from that total is then wrong in
-- a way no check on the result can see.  The Julia layer therefore raises
-- `CountOverflowError` (or widens to `BigInt`) instead of wrapping.
--
-- The theorems below say that guard is *exact*, in both directions:
--
--   * `checkedAdd-is-exact` — when it returns a value, that value is the true
--     sum.  It never returns a plausible-looking wrong total.
--   * `checkedAdd-never-refuses-a-sum-that-fits` — when the true sum fits, it
--     returns it.  The guard is not so cautious that it refuses valid work.
--   * `checkedAdd-refuses-exactly-when-it-must` — it refuses precisely when the
--     sum leaves the range, so nothing wraps.
--
-- Failing in either of the first two directions would be a defect; only the
-- pair of them together is the property the layer claims, which is why both are
-- proved rather than one of them being called "the safety property".

{-# OPTIONS --without-K --safe #-}

module MetaManifold.ExactCounts where

open import MetaManifold.Prelude

open import Data.Empty using (⊥; ⊥-elim)
open import Data.Integer as ℤ using (ℤ; +_; +0; +[1+_]; -[1+_]; -_; _*_; _+_; _≤_; _<_)
open import Data.Integer.Properties as ℤₚ using (_<?_; _≤?_; +-assoc; +-identityʳ)
open import Data.List.Base as List using (List; []; _∷_; map)
open import Data.Nat.Base as ℕ using (ℕ; zero; suc)
open import Data.Product using (∃; _×_; _,_; proj₁; proj₂)
open import Relation.Binary.PropositionalEquality
  using (_≡_; refl; sym; trans; cong)
open import Relation.Nullary.Decidable using (Dec; yes; no)
open import Relation.Nullary.Negation using (¬_)

------------------------------------------------------------------------
-- A fixed-width accumulator
--
-- `Int64` is `Fits 63`: every value v with −2^63 ≤ v < 2^63.  Modelling the
-- bound as data rather than assuming it is what makes "the guard is exact" a
-- statement that can be proved instead of an intention that can be stated.

pow2 : ℕ → ℤ
pow2 zero    = + 1
pow2 (suc k) = pow2 k * + 2

Fits : ℕ → ℤ → Set
Fits k v = (- pow2 k ≤ v) × (v < pow2 k)

fits? : ∀ k v → Dec (Fits k v)
fits? k v with - pow2 k ≤? v
... | no ¬a = no (λ where (x , _) → ¬a x)
... | yes a with v <? pow2 k
...   | no ¬b = no (λ where (_ , y) → ¬b y)
...   | yes b = yes (a , b)

record Bounded (k : ℕ) : Set where
  constructor mkBounded
  field
    intValue : ℤ
    fits  : Fits k intValue
open Bounded public

------------------------------------------------------------------------
-- The checked operations

data Checked (A : Set) : Set where
  ok      : A → Checked A
  refused : Refusal → Checked A

ok-injective : ∀ {A} {x y : A} → ok x ≡ ok y → x ≡ y
ok-injective refl = refl

-- A refusal is never an `ok`.  Used wherever a proof reaches a branch in which
-- the outcome was a refusal but the hypothesis says it was a value: the branch
-- is empty, and this is what says so.
refused≢ok : ∀ {A} {a : A} {r : Refusal} → refused r ≡ ok a → ⊥
refused≢ok ()

-- The decision `checkedAdd` makes, as data.  Making the decision a value rather
-- than leaving it inside a `with` is what lets the theorems below re-make it and
-- reason about the branch the implementation actually took.
data AddOutcome (k : ℕ) : ℤ → Set where
  inRange   : ∀ s → Fits k s → AddOutcome k s
  outOfRange : ∀ s → ¬ Fits k s → AddOutcome k s

classifyAdd : ∀ {k} (a b : Bounded k) → AddOutcome k (intValue a + intValue b)
classifyAdd {k} a b with fits? k (intValue a + intValue b)
... | yes f  = inRange (intValue a + intValue b) f
... | no  ¬f = outOfRange (intValue a + intValue b) ¬f

-- Checked addition: the true sum if it still fits, `refused overflow` if it
-- does not.  There is no branch in which a wrapped value escapes.
checkedAdd : ∀ {k} → Bounded k → Bounded k → Checked (Bounded k)
checkedAdd {k} a b with classifyAdd a b
... | inRange s f     = ok (mkBounded s f)
... | outOfRange s ¬f = refused overflow

-- Checked sum over a non-empty collection, mirroring `checked_count_sum`: the
-- accumulator starts at the first element, so no identity element has to be
-- invented for an empty one.
checkedSumOf : ∀ {k} (x : Bounded k) (xs : List (Bounded k)) → Checked (Bounded k)
checkedSumOf {k} x []       = ok x
checkedSumOf {k} x (y ∷ ys) with classifyAdd x y
... | outOfRange s ¬f = refused overflow
... | inRange s f     = checkedSumOf (mkBounded s f) ys

------------------------------------------------------------------------
-- The guard is exact

-- (1) A returned intValue is the true sum.
checkedAdd-is-exact :
  ∀ {k} (a b : Bounded k) {c : Bounded k} →
  checkedAdd a b ≡ ok c → intValue c ≡ intValue a + intValue b
checkedAdd-is-exact a b {c} p with classifyAdd a b
... | inRange s f     = sym (cong intValue (ok-injective p))
... | outOfRange s ¬f = ⊥-elim (refused≢ok p)


-- (2) A sum that fits is never refused: the guard is not over-cautious.
checkedAdd-never-refuses-a-sum-that-fits :
  ∀ {k} (a b : Bounded k) →
  Fits k (intValue a + intValue b) → ∃ λ (c : Bounded k) → checkedAdd a b ≡ ok c
checkedAdd-never-refuses-a-sum-that-fits a b f with classifyAdd a b
... | inRange s _     = _ , refl
... | outOfRange s ¬f = ⊥-elim (¬f f)

-- (3) It refuses exactly when the sum leaves the range, so nothing wraps.
checkedAdd-refuses-exactly-when-it-must :
  ∀ {k} (a b : Bounded k) →
  checkedAdd a b ≡ refused overflow → ¬ Fits k (intValue a + intValue b)
checkedAdd-refuses-exactly-when-it-must a b p with classifyAdd a b
... | inRange s f     = ⊥-elim (refused≢ok (sym p))
... | outOfRange s ¬f = ¬f

-- A fourth statement would be natural here: that the refusal produced is
-- *literally* `overflow` and no other constructor (`r ≡ overflow`).  That needs
-- injectivity for `Checked.refused`, and Agda will not discharge `refl` on
-- `refused r ≡ refused s` under `--without-K` in this module.  It is recorded as
-- an open obligation in `proofs/residue/exact-counts.residue` rather than
-- quietly dropped, and nothing the layer claims rests on it: statement (3)
-- already fixes *when* a refusal happens to exactly the out-of-range case, which
-- is the property that prevents a wrapped count from being mistaken for a total.

------------------------------------------------------------------------
-- The same guarantee for a whole table
--
-- `checked_count_sum` is a fold, and a fold's guarantee is an induction.  This
-- is the theorem the analysis layer actually relies on: if a table's counts sum
-- without overflowing, the total it reports *is* the sum of the counts, and
-- every exact proportion downstream inherits that.

checkedSumOf-is-exact :
  ∀ {k} (x : Bounded k) (xs : List (Bounded k)) {s : Bounded k} →
  checkedSumOf x xs ≡ ok s →
  intValue s ≡ intValue x + sumℤ (List.map intValue xs)
checkedSumOf-is-exact x [] {s} refl = sym (ℤₚ.+-identityʳ (intValue x))
checkedSumOf-is-exact x (y ∷ ys) {s} p with classifyAdd x y
... | outOfRange s′ ¬f = ⊥-elim (refused≢ok p)
... | inRange s′ f =
  trans (checkedSumOf-is-exact (mkBounded (intValue x + intValue y) f) ys p)
        (ℤₚ.+-assoc (intValue x) (intValue y) (sumℤ (List.map intValue ys)))

