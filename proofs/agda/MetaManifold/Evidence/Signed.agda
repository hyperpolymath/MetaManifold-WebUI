{-# OPTIONS --safe --without-K #-}
-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- The signed finite residual model, 'signed-integer-v1' — the model used by
-- the reference explorer in hyperpolymath/residual-evidence-types, by the
-- MetaManifold server routes (issue #7), and pinned by the golden vectors in
-- proofs/vectors/evidence_vectors.json.
--
--   world  = (u , n)   integers in [-6, 6], represented as OFFSETS:
--            a value v is stored as v + 6, so an offset is a Nat in [0, 12]
--            and "value zero" is offset 6.  Offsets keep every observation
--            predicate decidable on Nat, which is what makes the model
--            executable inside Agda itself.
--   exact view     : u + n = r            (offsets: u₀ + n₀ = r₀ + 6)
--   sign view      : sgn(u + n) = sgn(r)  (offsets: signOf (u₀+n₀) 12 = signOf r₀ 6)
--   magnitude view : |u + n| = |r|        (offsets: dist (u₀+n₀) 12 = dist r₀ 6)
--   admissibility  : u in domain, |n| ≤ b, optionally u = 0.
--
-- The correspondence "offset formula = signed view" is pinned across all 546
-- golden-vector cases by the Julia and bun test suites against the reference
-- JavaScript; Decision.agda then proves the decision procedures correct
-- against these predicates, so the whole chain from server code to the
-- Candidate semantics of Residual.agda is validated.

module MetaManifold.Evidence.Signed where

open import MetaManifold.Evidence.Prelude

-- --------------------------------------------------------------------------
-- Model constants and shapes
-- --------------------------------------------------------------------------

LIMIT : Nat
LIMIT = 6

GRID : Nat
GRID = 12                       -- 2 * LIMIT; offsets live in [0, GRID]

World : Set
World = Nat × Nat               -- (u-offset , n-offset)

data View : Set where
  exact sign magnitude : View

-- --------------------------------------------------------------------------
-- Decidable comparison toolkit on Nat
-- --------------------------------------------------------------------------

infix 4 _≤ᵇ_
_≤ᵇ_ : Nat → Nat → Bool
zero ≤ᵇ _ = true
suc m ≤ᵇ zero = false
suc m ≤ᵇ suc n = m ≤ᵇ n

≤ᵇ-to-≤ : ∀ m n → (m ≤ᵇ n) ≡ true → m ≤ n
≤ᵇ-to-≤ zero _ _ = z≤n
≤ᵇ-to-≤ (suc m) zero ()
≤ᵇ-to-≤ (suc m) (suc n) p = s≤s (≤ᵇ-to-≤ m n p)

≤-to-≤ᵇ : ∀ {m n} → m ≤ n → (m ≤ᵇ n) ≡ true
≤-to-≤ᵇ z≤n = refl
≤-to-≤ᵇ (s≤s p) = ≤-to-≤ᵇ p

suc-not-≤ᵇ : ∀ {m n} → m ≤ n → (suc n ≤ᵇ m) ≡ false
suc-not-≤ᵇ z≤n = refl
suc-not-≤ᵇ (s≤s p) = suc-not-≤ᵇ p

==-to-≡ : ∀ m n → (m == n) ≡ true → m ≡ n
==-to-≡ zero zero _ = refl
==-to-≡ zero (suc n) ()
==-to-≡ (suc m) zero ()
==-to-≡ (suc m) (suc n) p = cong suc (==-to-≡ m n p)

==-refl : ∀ m → (m == m) ≡ true
==-refl zero = refl
==-refl (suc m) = ==-refl m

≡-to-== : ∀ {m n} → m ≡ n → (m == n) ≡ true
≡-to-== {m} refl = ==-refl m

signEq : Sign → Sign → Bool
signEq neg neg = true
signEq neg _ = false
signEq zer zer = true
signEq zer _ = false
signEq pos pos = true
signEq pos _ = false

signEq-refl : ∀ s → (signEq s s) ≡ true
signEq-refl neg = refl
signEq-refl zer = refl
signEq-refl pos = refl

signEq-to-≡ : ∀ s t → (signEq s t) ≡ true → s ≡ t
signEq-to-≡ neg neg _ = refl
signEq-to-≡ zer zer _ = refl
signEq-to-≡ pos pos _ = refl

-- Arithmetic: a few standard Nat facts.
plus-zero : ∀ n → n + 0 ≡ n
plus-zero zero = refl
plus-zero (suc n) = cong suc (plus-zero n)

plus-suc : ∀ m n → m + suc n ≡ suc (m + n)
plus-suc zero n = refl
plus-suc (suc m) n = cong suc (plus-suc m n)

≤antisym : ∀ {m n} → m ≤ n → n ≤ m → m ≡ n
≤antisym z≤n z≤n = refl
≤antisym (s≤s p) (s≤s q) = cong suc (≤antisym p q)

≤-split : ∀ {m n} → m ≤ n → (m ≡ n) ⊎ (suc m ≤ n)
≤-split {n = zero} z≤n = inj₁ refl
≤-split {n = suc n} z≤n = inj₂ (s≤s z≤n)
≤-split (s≤s p) with ≤-split p
... | inj₁ q = inj₁ (cong suc q)
... | inj₂ r = inj₂ (s≤s r)

≤-mono-+ : ∀ k {m n} → m ≤ n → k + m ≤ k + n
≤-mono-+ zero p = p
≤-mono-+ (suc k) p = s≤s (≤-mono-+ k p)

-- x ≤ x + y, by induction (all sums reduce on constructor heads).
x≤x+y : ∀ x y → x ≤ x + y
x≤x+y zero y = z≤n
x≤x+y (suc x) y = s≤s (x≤x+y x y)

-- a ≤ b + (a ∸ b), by induction with both subtraction arguments split.
a≤b+∸ : ∀ a b → a ≤ b + (a ∸ b)
a≤b+∸ zero b = z≤n
a≤b+∸ (suc a) zero = ≤-refl
a≤b+∸ (suc a) (suc b) = s≤s (a≤b+∸ a b)

-- a ≤ b + |a − b| (distance bounds the value from above).
a≤mid+dist : ∀ a b → a ≤ b + dist a b
a≤mid+dist a b = ≤-trans (a≤b+∸ a b) (≤-mono-+ b (x≤x+y (a ∸ b) (b ∸ a)))

-- If |n| ≤ b and b ≤ 6 then the noise offset stays inside the grid.
offset-in-grid : ∀ n₀ b → dist n₀ 6 ≤ b → b ≤ 6 → n₀ ≤ 12
offset-in-grid n₀ b p b≤6 =
  ≤-trans (≤-trans (a≤mid+dist n₀ 6) (≤-mono-+ 6 p)) (bound-6 b b≤6)
  where
    bound-6 : ∀ b → b ≤ 6 → 6 + b ≤ 12
    bound-6 zero _ = s≤s (s≤s (s≤s (s≤s (s≤s (s≤s z≤n)))))
    bound-6 (suc b) (s≤s p) = s≤s (s≤s (s≤s (s≤s (s≤s (s≤s (s≤s p))))))

-- --------------------------------------------------------------------------
-- Observation and admissibility: specification (Set) and decision (Bool)
-- --------------------------------------------------------------------------

-- Observation match.  r₀ is the residual's offset.
Obs : View → Nat → World → Set
Obs exact r₀ w = (fst w + snd w) ≡ (r₀ + 6)
Obs sign r₀ w = signOf (fst w + snd w) 12 ≡ signOf r₀ 6
Obs magnitude r₀ w = dist (fst w + snd w) 12 ≡ dist r₀ 6

obs? : View → Nat → World → Bool
obs? exact r₀ w = (fst w + snd w) == (r₀ + 6)
obs? sign r₀ w = signEq (signOf (fst w + snd w) 12) (signOf r₀ 6)
obs? magnitude r₀ w = dist (fst w + snd w) 12 == dist r₀ 6

obs?-sound : ∀ view r₀ w → (obs? view r₀ w) ≡ true → Obs view r₀ w
obs?-sound exact r₀ w p = ==-to-≡ (fst w + snd w) (r₀ + 6) p
obs?-sound sign r₀ w p = signEq-to-≡ (signOf (fst w + snd w) 12) (signOf r₀ 6) p
obs?-sound magnitude r₀ w p = ==-to-≡ (dist (fst w + snd w) 12) (dist r₀ 6) p

obs?-complete : ∀ {view r₀ w} → Obs view r₀ w → (obs? view r₀ w) ≡ true
obs?-complete {exact} {r₀} {w} p =
  subst (λ j → ((fst w + snd w) == j) ≡ true) p (==-refl (fst w + snd w))
obs?-complete {sign} {r₀} {w} p =
  subst (λ j → signEq (signOf (fst w + snd w) 12) j ≡ true) p
        (signEq-refl (signOf (fst w + snd w) 12))
obs?-complete {magnitude} {r₀} {w} p =
  subst (λ j → (dist (fst w + snd w) 12 == j) ≡ true) p
        (==-refl (dist (fst w + snd w) 12))

-- Evidence / admissibility: domain bound on u, noise bound on n, optional
-- zero assumption on u.
Adm : Nat → Bool → World → Set
Adm b z w = (fst w ≤ GRID) × (dist (snd w) 6 ≤ b) ×
            (if z then (fst w ≡ 6) else ⊤)

adm? : Nat → Bool → World → Bool
adm? b z w = (fst w ≤ᵇ GRID) and ((dist (snd w) 6 ≤ᵇ b) and
             (if z then (fst w == 6) else true))

and-split : ∀ {x y} → (x and y) ≡ true → (x ≡ true) × (y ≡ true)
and-split {true} {y} p = refl , p
and-split {false} {y} ()

and-join : ∀ {x y} → (x ≡ true) → (y ≡ true) → (x and y) ≡ true
and-join {true} {y} _ q = q
and-join {false} {y} () q

adm?-sound : ∀ b z w → (adm? b z w) ≡ true → Adm b z w
adm?-sound b z w p
  with and-split {fst w ≤ᵇ GRID}
                 {(dist (snd w) 6 ≤ᵇ b) and (if z then (fst w == 6) else true)} p
...  | (u≤ , rest)
  with and-split {dist (snd w) 6 ≤ᵇ b} {if z then (fst w == 6) else true} rest
...  | (nb , zc) = ≤ᵇ-to-≤ (fst w) GRID u≤ , ≤ᵇ-to-≤ (dist (snd w) 6) b nb ,
                   zero-cond z zc
  where
    zero-cond : (z : Bool) → (if z then (fst w == 6) else true) ≡ true →
                (if z then (fst w ≡ 6) else ⊤)
    zero-cond true q = ==-to-≡ (fst w) 6 q
    zero-cond false _ = tt

adm?-complete : ∀ {b z w} → Adm b z w → (adm? b z w) ≡ true
adm?-complete {b} {z} {w} (u≤ , nb , zc) =
  and-join (≤-to-≤ᵇ u≤) (and-join (≤-to-≤ᵇ nb) (zero-cond z zc))
  where
    zero-cond : (z : Bool) → (if z then (fst w ≡ 6) else ⊤) →
                (if z then (fst w == 6) else true) ≡ true
    zero-cond true eq = ≡-to-== eq
    zero-cond false _ = refl

adm-domain : ∀ {b z w} → Adm b z w → fst w ≤ GRID
adm-domain (u≤ , _ , _) = u≤

adm-noise : ∀ {b z w} → Adm b z w → dist (snd w) 6 ≤ b
adm-noise (_ , nb , _) = nb

-- --------------------------------------------------------------------------
-- Enumeration of the full model domain, and the candidate list
-- --------------------------------------------------------------------------

-- ascend n lo = [lo, lo+1, …, lo+n]
ascend : Nat → Nat → List Nat
ascend zero lo = lo ∷ []
ascend (suc n) lo = lo ∷ ascend n (suc lo)

suc≰ : ∀ m → ¬ (suc m ≤ m)
suc≰ zero ()
suc≰ (suc m) (s≤s p) = suc≰ m p

ascend∈ : ∀ n lo k → lo ≤ k → k ≤ lo + n → k ∈ ascend n lo
ascend∈ zero lo k lo≤k k≤ with ≤-split lo≤k
... | inj₁ lo≡k = inj₁ (sym lo≡k)
... | inj₂ suclo≤k = ⊥-elim (suc≰ lo (subst (λ j → suc lo ≤ j) (sym (≤antisym lo≤k (k≤lo+0 k≤))) suclo≤k))
  where
    k≤lo+0 : k ≤ lo + zero → k ≤ lo
    k≤lo+0 kt = subst (λ j → k ≤ j) (plus-zero lo) kt
ascend∈ (suc n) lo k lo≤k k≤ with ≤-split lo≤k
... | inj₁ lo≡k = inj₁ (sym lo≡k)
... | inj₂ suclo≤k = inj₂ (ascend∈ n (suc lo) k suclo≤k (k≤suclo+n k≤))
  where
    k≤suclo+n : k ≤ lo + suc n → k ≤ suc lo + n
    k≤suclo+n kt = subst (λ j → k ≤ j) (plus-suc lo n) kt

offsets : List Nat
offsets = ascend GRID 0

allWorlds : List World                       -- u-offset outer, n-offset inner
allWorlds = concatMap (λ u₀ → map (λ n₀ → u₀ , n₀) offsets) offsets

-- The admissible-candidate filter, exactly the reference explorer's loop.
cand? : View → Nat → Nat → Bool → World → Bool
cand? view r₀ b z w = obs? view r₀ w and adm? b z w

candidates : View → Nat → Nat → Bool → List World
candidates view r₀ b z = filter (cand? view r₀ b z) allWorlds

-- --------------------------------------------------------------------------
-- Membership lemmas
-- --------------------------------------------------------------------------

++∈-head : ∀ {a} {A : Set a} {b : A} {ys zs : List A} → b ∈ ys → b ∈ ys ++ zs
++∈-head {ys = []} ()
++∈-head {ys = y ∷ ys} (inj₁ eq) = inj₁ eq
++∈-head {ys = y ∷ ys} (inj₂ m) = inj₂ (++∈-head m)

++∈-tail : ∀ {a} {A : Set a} {b : A} {ys zs : List A} → b ∈ zs → b ∈ ys ++ zs
++∈-tail {ys = []} m = m
++∈-tail {ys = _ ∷ ys} m = inj₂ (++∈-tail {ys = ys} m)

map∈ : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) {x : A} {xs : List A} →
       x ∈ xs → f x ∈ map f xs
map∈ f {xs = []} ()
map∈ f {xs = x ∷ xs} (inj₁ eq) = inj₁ (cong f eq)
map∈ f {xs = x ∷ xs} (inj₂ p) = inj₂ (map∈ f p)

∈-cong : ∀ {a b} {A : Set a} {B : Set b} (f : A → List B) {x y : A} {b : B} →
         x ≡ y → b ∈ f x → b ∈ f y
∈-cong f {b = b} eq q = subst (λ j → b ∈ f j) eq q

concatMap∈ : ∀ {a b} {A : Set a} {B : Set b} (f : A → List B) {a : A} {b : B}
             {xs : List A} → a ∈ xs → b ∈ f a → b ∈ concatMap f xs
concatMap∈ f {xs = []} ()
concatMap∈ f {xs = x ∷ xs} (inj₁ eq) q = ++∈-head (∈-cong f eq q)
concatMap∈ f {xs = x ∷ xs} (inj₂ p) q = ++∈-tail {ys = f x} (concatMap∈ f p q)

-- The inspect idiom: pattern-match a boolean expression's value while
-- keeping the equation as data (no with-abstraction refinement needed).
data Inspect {a} {A : Set a} (x : A) : Set a where
  inspecting : (y : A) → x ≡ y → Inspect x

inspect : ∀ {a} {A : Set a} (x : A) → Inspect x
inspect x = inspecting x refl

filter-true : ∀ {a} {A : Set a} (p : A → Bool) (x : A) (xs : List A) →
              (p x) ≡ true → filter p (x ∷ xs) ≡ (x ∷ filter p xs)
filter-true p x xs eq = cong (λ b → if b then x ∷ filter p xs else filter p xs) eq

filter-false : ∀ {a} {A : Set a} (p : A → Bool) (x : A) (xs : List A) →
               (p x) ≡ false → filter p (x ∷ xs) ≡ filter p xs
filter-false p x xs eq = cong (λ b → if b then x ∷ filter p xs else filter p xs) eq

∈-subst : ∀ {a} {A : Set a} {x : A} {l₁ l₂ : List A} → l₁ ≡ l₂ → x ∈ l₁ → x ∈ l₂
∈-subst {x = x} eq m = subst (λ l → x ∈ l) eq m

-- Filter-membership soundness and completeness.  The element is an explicit
-- argument throughout (with it implicit, Agda promotes it to a rigid pattern
-- variable inside these clauses and cannot unify it with the cons head);
-- dispatch is by direct Inspect pattern-matching, which — unlike
-- with-abstraction — leaves the other arguments' types untouched.

mutual

 -- Filter-membership soundness and completeness.  The element x and the list
 -- head y are both explicit (implicit pattern variables get rigidified here
 -- and stop unifying); dispatch is by direct Inspect pattern-matching, which
 -- — unlike with-abstraction — leaves the other arguments' types untouched.

 filter∈-dispatch : ∀ {a} {A : Set a} (p : A → Bool) (x y : A) (xs : List A) →
                    Inspect (p y) → x ∈ filter p (y ∷ xs) →
                    (x ∈ y ∷ xs) × ((p x) ≡ true)
 filter∈-dispatch p x y xs (inspecting true peq) m
   with ∈-subst {x = x} (filter-true p y xs peq) m
 ... | inj₁ eq = inj₁ eq , trans (cong p eq) peq
 ... | inj₂ m′ with filter∈-sound p x xs m′
 ...   | (in-tail , pv) = inj₂ in-tail , pv
 filter∈-dispatch p x y xs (inspecting false peq) m
   with filter∈-sound p x xs (∈-subst {x = x} (filter-false p y xs peq) m)
 ... | (in-tail , pv) = inj₂ in-tail , pv

 filter∈-sound : ∀ {a} {A : Set a} (p : A → Bool) (x : A) (xs : List A) →
                 x ∈ filter p xs → (x ∈ xs) × ((p x) ≡ true)
 filter∈-sound p x [] ()
 filter∈-sound p x (y ∷ xs) m = filter∈-dispatch p x y xs (inspect (p y)) m

 filter∈-complete-false : ∀ {a} {A : Set a} (p : A → Bool) (x y : A) (xs : List A) →
                          (p y) ≡ false → x ∈ y ∷ xs → (p x) ≡ true →
                          x ∈ filter p (y ∷ xs)
 filter∈-complete-false p x y xs peq m pv with m
 ... | inj₁ eq = contradiction eq pv peq
   where
     contradiction : x ≡ y → (p x) ≡ true → (p y) ≡ false → x ∈ filter p (y ∷ xs)
     contradiction eq′ pv′ peq′ =
       nope (trans (sym pv′) (trans (cong p eq′) peq′))
       where
         nope : true ≡ false → x ∈ filter p (y ∷ xs)
         nope ()
 ... | inj₂ m′ =
         ∈-subst {x = x} (sym (filter-false p y xs peq)) (filter∈-complete p x xs m′ pv)

 filter∈-complete : ∀ {a} {A : Set a} (p : A → Bool) (x : A) (xs : List A) →
                    x ∈ xs → (p x) ≡ true → x ∈ filter p xs
 filter∈-complete p x [] () _
 filter∈-complete p x (y ∷ xs) m pv with inspect (p y)
 ... | inspecting true peq =
         ∈-subst {x = x} (sym (filter-true p y xs peq)) (build m)
   where
     build : x ∈ y ∷ xs → x ∈ y ∷ filter p xs
     build (inj₁ eq) = inj₁ eq
     build (inj₂ m′) = inj₂ (filter∈-complete p x xs m′ pv)
 ... | inspecting false peq = filter∈-complete-false p x y xs peq m pv

-- Every world with in-grid offsets is enumerated.
allWorlds∈ : ∀ w → fst w ≤ GRID → snd w ≤ GRID → w ∈ allWorlds
allWorlds∈ (u₀ , n₀) u≤ n≤ =
  concatMap∈ (λ a → map (λ b → a , b) offsets)
             (ascend∈ GRID 0 u₀ z≤n u≤)
             (map∈ (λ b → u₀ , b) (ascend∈ GRID 0 n₀ z≤n n≤))

-- --------------------------------------------------------------------------
-- Soundness and completeness of the enumeration
-- --------------------------------------------------------------------------

-- Splitting the candidate test into its observation and admissibility halves.
cand-split : ∀ view r₀ b z w → (cand? view r₀ b z w) ≡ true →
             ((obs? view r₀ w) ≡ true) × ((adm? b z w) ≡ true)
cand-split view r₀ b z w pv = and-split {obs? view r₀ w} {adm? b z w} pv

-- Every listed candidate satisfies the specification.
candidates-sound : ∀ view r₀ b z w → w ∈ candidates view r₀ b z →
                   (Obs view r₀ w) × Adm b z w
candidates-sound view r₀ b z w m =
  sound-step (filter∈-sound (cand? view r₀ b z) w allWorlds m)
  where
    sound-step : ((w ∈ allWorlds) × ((cand? view r₀ b z w) ≡ true)) →
                 (Obs view r₀ w) × Adm b z w
    sound-step (in-list , pv) =
      obs?-sound view r₀ w (fst (cand-split view r₀ b z w pv)) ,
      adm?-sound b z w (snd (cand-split view r₀ b z w pv))

-- Every world satisfying the specification is listed, provided the bound is
-- within the model's validated range (b ≤ 6), which keeps noise offsets
-- inside the enumerated grid.
candidates-complete : ∀ view r₀ b z w → b ≤ 6 →
                      (Obs view r₀ w) × Adm b z w →
                      w ∈ candidates view r₀ b z
candidates-complete view r₀ b z w b≤6 (o , a) =
  filter∈-complete (cand? view r₀ b z) w (allWorlds)
    (allWorlds∈ w (adm-domain {w = w} a)
                  (offset-in-grid (snd w) b (adm-noise {w = w} a) b≤6))
    (and-join (obs?-complete o) (adm?-complete {w = w} a))

-- --------------------------------------------------------------------------
-- Length and sorted unique u-values (for the golden-vector checks)
-- --------------------------------------------------------------------------

length : ∀ {a} {A : Set a} → List A → Nat
length [] = zero
length (_ ∷ xs) = suc (length xs)

infixr 5 _or_
_or_ : Bool → Bool → Bool
true or _ = true
false or b = b

insert : Nat → List Nat → List Nat
insert k [] = k ∷ []
insert k (x ∷ xs) = if k == x then x ∷ xs else
                    (if k ≤ᵇ x then k ∷ x ∷ xs else (x ∷ insert k xs))

usort : List Nat → List Nat
usort [] = []
usort (x ∷ xs) = insert x (usort xs)

values : List World → List Nat                     -- sorted unique u-offsets
values ws = usort (map fst ws)
