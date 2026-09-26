{-# OPTIONS --safe --without-K #-}
-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Tiny standard-library-free prelude, in the style of
-- hyperpolymath/residual-evidence-types (MPL-2.0).  Depending only on
-- Agda.Builtin modules keeps this library typecheckable by a bare Agda
-- install with no stdlib setup, which is how CI checks it.

module MetaManifold.Evidence.Prelude where

open import Agda.Primitive using (Level; lzero; lsuc; _⊔_) public
open import Agda.Builtin.Equality using (_≡_; refl) public
open import Agda.Builtin.Sigma using (Σ; _,_; fst; snd) public
open import Agda.Builtin.Nat using (Nat; zero; suc; _+_; _*_; _==_; _<_) public

-- Truncated subtraction, defined here rather than imported: the builtin
-- primitive only reduces when BOTH arguments are constructor-headed, while
-- this one reduces as soon as the first is, which the distance proofs need.
infixl 6 _∸_
_∸_ : Nat → Nat → Nat
zero ∸ _ = zero
suc m ∸ zero = suc m
suc m ∸ suc n = m ∸ n
open import Agda.Builtin.Bool using (Bool; true; false) public
open import Agda.Builtin.Unit using (⊤; tt) public
open import Agda.Builtin.List using (List; []; _∷_) public

-- Empty type and negation (level-polymorphic so it can appear in
-- level-polymorphic membership).
data ⊥ {a} : Set a where

infix 3 ¬_
¬_ : ∀ {a} → Set a → Set a
¬_ {a} A = A → ⊥ {a}

⊥-elim : ∀ {a b} {A : Set b} → ⊥ {a} → A
⊥-elim ()

-- Products as nested Sigmas.
infixr 4 _×_
_×_ : ∀ {a b} → Set a → Set b → Set (a ⊔ b)
A × B = Σ A (λ _ → B)

-- Equality toolkit (intensional, no funext assumed anywhere).
sym : ∀ {a} {A : Set a} {x y : A} → x ≡ y → y ≡ x
sym refl = refl

trans : ∀ {a} {A : Set a} {x y z : A} → x ≡ y → y ≡ z → x ≡ z
trans refl q = q

cong : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) {x y : A} → x ≡ y → f x ≡ f y
cong f refl = refl

subst : ∀ {a p} {A : Set a} (P : A → Set p) {x y : A} → x ≡ y → P x → P y
subst P refl p = p

J : ∀ {a p} {A : Set a} {x : A} (P : (y : A) → x ≡ y → Set p) →
    P x refl → {y : A} (eq : x ≡ y) → P y eq
J P p refl = p

-- Booleans as propositions.
T : Bool → Set
T true = ⊤
T false = ⊥

infixr 5 _and_
_and_ : Bool → Bool → Bool
true and x = x
false and _ = false

-- Natural-number order (from residual-evidence-types' prelude).
infix 4 _≤_
data _≤_ : Nat → Nat → Set where
  z≤n : ∀ {n} → zero ≤ n
  s≤s : ∀ {m n} → m ≤ n → suc m ≤ suc n

≤-refl : ∀ {n} → n ≤ n
≤-refl {zero} = z≤n
≤-refl {suc n} = s≤s ≤-refl

≤-trans : ∀ {a b c} → a ≤ b → b ≤ c → a ≤ c
≤-trans z≤n _ = z≤n
≤-trans (s≤s p) (s≤s q) = s≤s (≤-trans p q)

≤-suc : ∀ {m n} → m ≤ n → m ≤ suc n
≤-suc z≤n = z≤n
≤-suc (s≤s p) = s≤s (≤-suc p)

-- Trichotomy of natural numbers, used for the sign view of the finite
-- residual model.
data Sign : Set where
  neg zer pos : Sign

signOf : (a mid : Nat) → Sign
signOf a mid with a < mid
... | true = neg
... | false with a == mid
...   | true = zer
...   | false = pos

-- |a − b| on naturals (both truncated subtractions; exactly one is nonzero).
dist : (a b : Nat) → Nat
dist a b = (a ∸ b) + (b ∸ a)

-- Absolute value of a signed offset value v = off − 6, as a natural.
absOff : (off : Nat) → Nat
absOff off = dist off 6

-- Minimal list toolkit.
infixr 5 _++_
_++_ : ∀ {a} {A : Set a} → List A → List A → List A
[] ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)

map : ∀ {a b} {A : Set a} {B : Set b} → (A → B) → List A → List B
map f [] = []
map f (x ∷ xs) = f x ∷ map f xs

concatMap : ∀ {a b} {A : Set a} {B : Set b} → (A → List B) → List A → List B
concatMap f [] = []
concatMap f (x ∷ xs) = f x ++ concatMap f xs

if_then_else_ : ∀ {a} {A : Set a} → Bool → A → A → A
if true then x else _ = x
if false then _ else y = y

filter : ∀ {a} {A : Set a} → (A → Bool) → List A → List A
filter p [] = []
filter p (x ∷ xs) = if p x then x ∷ filter p xs else filter p xs

-- Coproducts.
data _⊎_ {a b} (A : Set a) (B : Set b) : Set (a ⊔ b) where
  inj₁ : A → A ⊎ B
  inj₂ : B → A ⊎ B

-- List membership, as a recursive proposition (not an indexed datatype):
-- index-free, so it never trips the --without-K unification restrictions.
infix 4 _∈_
_∈_ : ∀ {a} {A : Set a} → A → List A → Set a
x ∈ [] = ⊥
x ∈ (y ∷ xs) = (x ≡ y) ⊎ (x ∈ xs)
