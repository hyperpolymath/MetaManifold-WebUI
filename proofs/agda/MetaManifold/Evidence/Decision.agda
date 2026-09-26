{-# OPTIONS --safe --without-K #-}
-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Decision procedures for the signed finite residual model, and the proofs
-- that they exactly decide the Candidate semantics of Residual.agda.
--
-- These are the procedures the MetaManifold server routes (issue #7) and the
-- residual explorer UI run — here executed inside Agda itself and proved
-- correct, which closes the gap the standalone reference explorer honestly
-- flagged ("separately tested JavaScript, with no proved extraction
-- correspondence").
--
--   decide cs = entailed     ⇔ Holds  Present  (every candidate has u ≠ 0)
--   decide cs = refuted      ⇔ Holds  Absent   (every candidate has u = 0)
--   decide cs = unresolved   ⇔ ¬Holds Present ∧ ¬Holds Absent
--   decide cs = inconsistent ⇔ no candidate exists (an empty candidate set
--                                does NOT make every claim true — there is no
--                                inhabited Case at all)

module MetaManifold.Evidence.Decision where

open import MetaManifold.Evidence.Prelude
open import MetaManifold.Evidence.Signed

-- --------------------------------------------------------------------------
-- The finite-case candidate set and claims over it
-- --------------------------------------------------------------------------

-- The evidence-refined preimage fibre for the finite model, as a type.
FCase : View → Nat → Nat → Bool → Set
FCase view r₀ b z = Σ World (λ w → (Obs view r₀ w) × (Adm b z w))

-- A claim holds when it holds of every admissible candidate's world.
FHolds : ∀ {p} (view : View) (r₀ b : Nat) (z : Bool) →
         (World → Set p) → Set p
FHolds view r₀ b z P = (c : FCase view r₀ b z) → P (fst c)

-- Presence: u ≠ 0, i.e. the u-offset is not the zero offset 6.
Present : World → Set
Present w = ¬ (fst w ≡ 6)

-- Absence: u = 0.
Absent : World → Set
Absent w = fst w ≡ 6

-- A numeric query is identified when every admissible candidate agrees on it.
FIdentified : (view : View) (r₀ b : Nat) (z : Bool) →
              (World → Nat) → Set
FIdentified view r₀ b z query =
  Σ Nat (λ v → FHolds view r₀ b z (λ w → query w ≡ v))

-- Two admissible candidates that disagree on the query refute identification
-- (the finite-model shadow of different-candidates-refute-identification).
finitely-refute-identification :
  ∀ (view : View) (r₀ b : Nat) (z : Bool) (query : World → Nat)
  (x y : FCase view r₀ b z) →
  ¬ (query (fst x) ≡ query (fst y)) →
  ¬ (FIdentified view r₀ b z query)
finitely-refute-identification view r₀ b z query x y disagree (v , agrees) =
  disagree (trans (agrees x) (sym (agrees y)))

-- --------------------------------------------------------------------------
-- Boolean any?-toolkit
-- --------------------------------------------------------------------------

not? : Bool → Bool
not? b = if b then false else true

any? : ∀ {a} {A : Set a} (p : A → Bool) → List A → Bool
any? p [] = false
any? p (x ∷ xs) = (p x) or (any? p xs)

contr-bool : (b : Bool) → (b ≡ true) → (b ≡ false) → ⊥ {lzero}
contr-bool true refl ()
contr-bool false () refl

true≢false→anything : ∀ {a} {A : Set a} → (true ≡ false) → A
true≢false→anything ()

any-true-tail :
  ∀ {a} {A : Set a} (p : A → Bool) (x : A) (xs : List A) →
  Σ A (λ y → (y ∈ xs) × ((p y) ≡ true)) →
  Σ A (λ y → (y ∈ x ∷ xs) × ((p y) ≡ true))
any-true-tail p x xs (y , m , pv) = y , inj₂ m , pv

any-true : ∀ {a} {A : Set a} (p : A → Bool) (xs : List A) →
           (any? p xs) ≡ true → Σ A (λ x → (x ∈ xs) × ((p x) ≡ true))
any-true p [] ()
any-true p (x ∷ xs) q with inspect (p x)
... | inspecting true peq = x , inj₁ refl , peq
... | inspecting false peq =
        any-true-tail p x xs
          (any-true p xs (subst (λ b → (b or any? p xs) ≡ true) peq q))

any-false : ∀ {a} {A : Set a} (p : A → Bool) (xs : List A) →
            (any? p xs) ≡ false → (x : A) → x ∈ xs → (p x) ≡ false
any-false p [] q x ()
any-false p (y ∷ xs) q x m with inspect (p y)
... | inspecting true peq =
        true≢false→anything (subst (λ b → (b or any? p xs) ≡ false) peq q)
... | inspecting false peq with m
... | inj₁ eq = trans (cong p eq) peq
... | inj₂ m′ =
        any-false p xs (subst (λ b → (b or any? p xs) ≡ false) peq q) x m′

-- --------------------------------------------------------------------------
-- The decide computation (exactly what the server/UI compute)
-- --------------------------------------------------------------------------

data Verdict : Set where
  entailed refuted unresolved inconsistent : Verdict

is-zero : World → Bool
is-zero w = fst w == 6

is-nonzero : World → Bool
is-nonzero w = not? (is-zero w)

has-zero? : List World → Bool
has-zero? cs = any? is-zero cs

has-nonzero? : List World → Bool
has-nonzero? cs = any? is-nonzero cs

verdict₂ : Bool → Bool → Verdict
verdict₂ false _ = entailed          -- no zero-candidate: all present
verdict₂ true false = refuted        -- only zero-candidates: all absent
verdict₂ true true = unresolved      -- both kinds remain

decide : List World → Verdict
decide [] = inconsistent
decide (w ∷ ws) = verdict₂ (has-zero? (w ∷ ws)) (has-nonzero? (w ∷ ws))

-- Full result record: what every endpoint returns for a residual case.
record Result : Set where
  constructor mk-result
  field
    count : Nat
    verdict : Verdict
    identified-values : List Nat       -- sorted unique u-offsets
open Result public

result : View → Nat → Nat → Bool → Result
result view r₀ b z =
  mk-result (length cs) (decide cs) (values cs)
  where cs = candidates view r₀ b z

-- --------------------------------------------------------------------------
-- Bridging lemmas: boolean tests to propositions
-- --------------------------------------------------------------------------

zero-free→present : (w : World) → (is-zero w) ≡ false → Present w
zero-free→present w hz eq = contr-bool (fst w == 6) (≡-to-== eq) hz

nonzero-step : (w : World) → (is-nonzero w) ≡ false → Inspect (is-zero w) → Absent w
nonzero-step w hn (inspecting true pz) = ==-to-≡ (fst w) 6 pz
nonzero-step w hn (inspecting false pz) =
  ⊥-elim (contr-bool (not? (is-zero w))
                      (subst (λ j → (not? j) ≡ true) (sym pz) refl) hn)

nonzero-free→absent : (w : World) → (is-nonzero w) ≡ false → Absent w
nonzero-free→absent w hn = nonzero-step w hn (inspect (is-zero w))

-- Inversions of the decide computation.

refuted≢entailed : verdict₂ true false ≡ entailed → ⊥ {lzero}
refuted≢entailed ()

unresolved≢entailed : verdict₂ true true ≡ entailed → ⊥ {lzero}
unresolved≢entailed ()

entailed≢refuted : ∀ j → verdict₂ false j ≡ refuted → ⊥ {lzero}
entailed≢refuted j ()

unresolved≢refuted : verdict₂ true true ≡ refuted → ⊥ {lzero}
unresolved≢refuted ()

entailed≢inconsistent : ∀ j → verdict₂ false j ≡ inconsistent → ⊥ {lzero}
entailed≢inconsistent j ()

refuted≢inconsistent : verdict₂ true false ≡ inconsistent → ⊥ {lzero}
refuted≢inconsistent ()

unresolved≢inconsistent : verdict₂ true true ≡ inconsistent → ⊥ {lzero}
unresolved≢inconsistent ()

decide-entailed⇒zero-free : ∀ cs → (decide cs ≡ entailed) → (has-zero? cs ≡ false)
decide-entailed⇒zero-free [] ()
decide-entailed⇒zero-free (w ∷ ws) eq with inspect (has-zero? (w ∷ ws))
... | inspecting false hz = hz
... | inspecting true hz = impossible hz eq
  where
    impossible : (has-zero? (w ∷ ws)) ≡ true → decide (w ∷ ws) ≡ entailed →
                 has-zero? (w ∷ ws) ≡ false
    impossible hz′ eq′ with inspect (has-nonzero? (w ∷ ws))
    ... | inspecting false hn′ =
            ⊥-elim (refuted≢entailed
              (subst (λ j → verdict₂ true j ≡ entailed) hn′
                (subst (λ j → verdict₂ j (has-nonzero? (w ∷ ws)) ≡ entailed) hz′ eq′)))
    ... | inspecting true hn′ =
            ⊥-elim (unresolved≢entailed
              (subst (λ j → verdict₂ true j ≡ entailed) hn′
                (subst (λ j → verdict₂ j (has-nonzero? (w ∷ ws)) ≡ entailed) hz′ eq′)))

decide-refuted⇒nonzero-free : ∀ cs → (decide cs ≡ refuted) → (has-nonzero? cs ≡ false)
decide-refuted⇒nonzero-free [] ()
decide-refuted⇒nonzero-free (w ∷ ws) eq with inspect (has-nonzero? (w ∷ ws))
... | inspecting false hn = hn
... | inspecting true hn = impossible hn eq
  where
    impossible : (has-nonzero? (w ∷ ws)) ≡ true → decide (w ∷ ws) ≡ refuted →
                 has-nonzero? (w ∷ ws) ≡ false
    impossible hn′ eq′ with inspect (has-zero? (w ∷ ws))
    ... | inspecting false hz′ =
            ⊥-elim (entailed≢refuted (has-nonzero? (w ∷ ws))
              (subst (λ j → verdict₂ false j ≡ refuted) hn′
                (subst (λ j → verdict₂ j (has-nonzero? (w ∷ ws)) ≡ refuted) hz′ eq′)))
    ... | inspecting true hz′ =
            ⊥-elim (unresolved≢refuted
              (subst (λ j → verdict₂ true j ≡ refuted) hn′
                (subst (λ j → verdict₂ j (has-nonzero? (w ∷ ws)) ≡ refuted) hz′ eq′)))

unresolved⇒entailed-impossible : ∀ j → verdict₂ false j ≡ unresolved → ⊥ {lzero}
unresolved⇒entailed-impossible j ()

unresolved⇒refuted-impossible : verdict₂ true false ≡ unresolved → ⊥ {lzero}
unresolved⇒refuted-impossible ()

decide-unresolved⇒both : ∀ cs → (decide cs ≡ unresolved) →
                          (has-zero? cs ≡ true) × (has-nonzero? cs ≡ true)
decide-unresolved⇒both [] ()
decide-unresolved⇒both (w ∷ ws) eq
  with inspect (has-zero? (w ∷ ws)) | inspect (has-nonzero? (w ∷ ws))
... | inspecting false hz | _ =
        ⊥-elim (unresolved⇒entailed-impossible (has-nonzero? (w ∷ ws))
          (subst (λ j → verdict₂ j (has-nonzero? (w ∷ ws)) ≡ unresolved) hz eq))
... | inspecting true hz′ | inspecting false hn =
        ⊥-elim (unresolved⇒refuted-impossible
          (subst (λ j → verdict₂ true j ≡ unresolved) hn
            (subst (λ j → verdict₂ j (has-nonzero? (w ∷ ws)) ≡ unresolved) hz′ eq)))
... | inspecting true hz | inspecting true hn = hz , hn

decide-inconsistent⇒empty : ∀ cs → (decide cs ≡ inconsistent) → (w : World) → ¬ (w ∈ cs)
decide-inconsistent⇒empty [] eq w ()
decide-inconsistent⇒empty (y ∷ ws) eq w m
  with inspect (has-zero? (y ∷ ws)) | inspect (has-nonzero? (y ∷ ws))
... | inspecting false hz | _ =
        ⊥-elim (entailed≢inconsistent (has-nonzero? (y ∷ ws))
          (subst (λ j → verdict₂ j (has-nonzero? (y ∷ ws)) ≡ inconsistent) hz eq))
... | inspecting true hz′ | inspecting false hn =
        ⊥-elim (refuted≢inconsistent
          (subst (λ j → verdict₂ true j ≡ inconsistent) hn
            (subst (λ j → verdict₂ j (has-nonzero? (y ∷ ws)) ≡ inconsistent) hz′ eq)))
... | inspecting true hz′ | inspecting true hn′ =
        ⊥-elim (unresolved≢inconsistent
          (subst (λ j → verdict₂ true j ≡ inconsistent) hn′
            (subst (λ j → verdict₂ j (has-nonzero? (y ∷ ws)) ≡ inconsistent) hz′ eq)))

-- --------------------------------------------------------------------------
-- Main correctness theorems
-- --------------------------------------------------------------------------

-- entailed ⇒ every admissible candidate is present.
entailed⇒holds : ∀ view r₀ b z → b ≤ 6 →
                 (decide (candidates view r₀ b z) ≡ entailed) →
                 FHolds view r₀ b z Present
entailed⇒holds view r₀ b z b≤6 v✓ c =
  zero-free→present w hz
  where
    w = fst c
    w∈ = candidates-complete view r₀ b z w b≤6 (snd c)
    hz = any-false is-zero (candidates view r₀ b z)
           (decide-entailed⇒zero-free (candidates view r₀ b z) v✓) w w∈

-- refuted ⇒ every admissible candidate is absent.
refuted⇒holds-absent : ∀ view r₀ b z → b ≤ 6 →
                       (decide (candidates view r₀ b z) ≡ refuted) →
                       FHolds view r₀ b z Absent
refuted⇒holds-absent view r₀ b z b≤6 v✓ c =
  nonzero-free→absent w hn
  where
    w = fst c
    w∈ = candidates-complete view r₀ b z w b≤6 (snd c)
    hn = any-false is-nonzero (candidates view r₀ b z)
           (decide-refuted⇒nonzero-free (candidates view r₀ b z) v✓) w w∈

-- unresolved ⇒ neither presence nor absence is warranted.
unresolved⇒¬holds : ∀ view r₀ b z → b ≤ 6 →
                    (decide (candidates view r₀ b z) ≡ unresolved) →
                    (¬ (FHolds view r₀ b z Present)) × (¬ (FHolds view r₀ b z Absent))
unresolved⇒¬holds view r₀ b z b≤6 v✓ =
  (λ holds → refutes-absent holds) ,
  (λ holds → refutes-present holds)
  where
    cs = candidates view r₀ b z
    hz = fst (decide-unresolved⇒both cs v✓)
    hn = snd (decide-unresolved⇒both cs v✓)

    zero-w = fst (any-true is-zero cs hz)
    zero-m = fst (snd (any-true is-zero cs hz))
    zero-p = snd (snd (any-true is-zero cs hz))
    zero-cand : FCase view r₀ b z
    zero-cand = zero-w , candidates-sound view r₀ b z zero-w zero-m
    zero-absent : Absent (fst zero-cand)
    zero-absent = ==-to-≡ (fst zero-w) 6 zero-p

    nonzero-w = fst (any-true is-nonzero cs hn)
    nonzero-m = fst (snd (any-true is-nonzero cs hn))
    nonzero-p = snd (snd (any-true is-nonzero cs hn))
    nonzero-cand : FCase view r₀ b z
    nonzero-cand = nonzero-w , candidates-sound view r₀ b z nonzero-w nonzero-m
    nonzero-present : Present (fst nonzero-cand)
    nonzero-present = zero-free→present nonzero-w
                        (contr-opposite (is-zero nonzero-w) nonzero-p)
      where
        contr-opposite : (b : Bool) → (not? b ≡ true) → (b ≡ false)
        contr-opposite true ()
        contr-opposite false _ = refl

    refutes-absent : FHolds view r₀ b z Present → ⊥
    refutes-absent holds = holds zero-cand zero-absent

    refutes-present : FHolds view r₀ b z Absent → ⊥
    refutes-present holds = nonzero-present (holds nonzero-cand)

-- inconsistent ⇒ NO candidate exists: an empty candidate set does not make
-- every claim true — there is no inhabited case at all.
inconsistent⇒no-candidate : ∀ view r₀ b z → b ≤ 6 →
                            (decide (candidates view r₀ b z) ≡ inconsistent) →
                            ¬ (FCase view r₀ b z)
inconsistent⇒no-candidate view r₀ b z b≤6 v✓ c =
  decide-inconsistent⇒empty (candidates view r₀ b z) v✓ (fst c)
    (candidates-complete view r₀ b z (fst c) b≤6 (snd c))

-- --------------------------------------------------------------------------
-- The worked examples of the reference explorer, as computed and proved
-- terms.  r = 2 means offset 8; the noise bound |n| ≤ b is a Nat.
-- --------------------------------------------------------------------------

-- Preset 2 "Present, value unknown": r = 2, |n| ≤ 1.
present-case : candidates exact 8 1 false ≡ (7 , 7) ∷ (8 , 6) ∷ (9 , 5) ∷ []
present-case = refl

present-entailed : decide (candidates exact 8 1 false) ≡ entailed
present-entailed = refl

present-values : values (candidates exact 8 1 false) ≡ 7 ∷ 8 ∷ 9 ∷ []
present-values = refl

-- The witnesses, as members of the finite case.
seven-seven : FCase exact 8 1 false
seven-seven = (7 , 7) , refl , (≤7-12 , ≤1-1 , tt)
  where
    ≤7-12 : 7 ≤ 12
    ≤7-12 = s≤s (s≤s (s≤s (s≤s (s≤s (s≤s (s≤s z≤n))))))
    ≤1-1 : dist 7 6 ≤ 1
    ≤1-1 = s≤s z≤n

eight-six : FCase exact 8 1 false
eight-six = (8 , 6) , refl , (≤8-12 , ≤0-1 , tt)
  where
    ≤8-12 : 8 ≤ 12
    ≤8-12 = s≤s (s≤s (s≤s (s≤s (s≤s (s≤s (s≤s (s≤s z≤n)))))))
    ≤0-1 : dist 6 6 ≤ 1
    ≤0-1 = z≤n

seven≢eight : ¬ (7 ≡ 8)
seven≢eight ()

-- Presence without identification: the canonical residual-evidence example.
present-without-identification : ¬ (FIdentified exact 8 1 false fst)
present-without-identification =
  finitely-refute-identification exact 8 1 false fst seven-seven eight-six seven≢eight

present-holds : FHolds exact 8 1 false Present
present-holds = entailed⇒holds exact 8 1 false ≤6 present-entailed
  where
    ≤6 : 1 ≤ 6
    ≤6 = s≤s z≤n

-- Preset 1 "Residual alone": r = 2, unbounded noise.
ambiguous-unresolved : decide (candidates exact 8 6 false) ≡ unresolved
ambiguous-unresolved = refl

-- Preset 3 "Value identified": r = 2, no noise.
exact-entailed : decide (candidates exact 8 0 false) ≡ entailed
exact-entailed = refl

exact-identified-value : values (candidates exact 8 0 false) ≡ 8 ∷ []
exact-identified-value = refl

-- Preset 4 "Cancellation": r = 0, unbounded noise.
cancellation-unresolved : decide (candidates exact 6 6 false) ≡ unresolved
cancellation-unresolved = refl

-- Preset 5 "Conflicting assumptions": r = 2, |n| ≤ 1, u = 0 — no candidate
-- exists, and no claim is issued.
conflict-inconsistent : decide (candidates exact 8 1 true) ≡ inconsistent
conflict-inconsistent = refl

conflict-no-candidate : ¬ (FCase exact 8 1 true)
conflict-no-candidate =
  inconsistent⇒no-candidate exact 8 1 true ≤6 conflict-inconsistent
  where
    ≤6 : 1 ≤ 6
    ≤6 = s≤s z≤n
