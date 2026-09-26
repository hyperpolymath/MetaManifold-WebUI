{-# OPTIONS --safe --without-K #-}
-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Echo types — proof-relevant fibres as structured-loss witnesses, following
-- hyperpolymath/echo-types (MPL-2.0).
--
--   Echo f y := Σ (x : A) , (f x ≡ y)
--
-- In MetaManifold: f is the observation function (sequencing + denoising),
-- A the possible true worlds, B the observed table.  The fibre over an
-- observed value is exactly "every true world compatible with the
-- observation, with its proof".  `avec_fibre` records that this fibre is
-- inhabited; `sans_fibre` that it is not (the artefact retains no origin
-- structure).  The total-space factorisation below is the standard fact that
-- nothing is gained or lost by grouping witnesses fibre-wise: it is the
-- licence for the server to store rows as (observed, witnesses) pairs.

module MetaManifold.Evidence.Echo where

open import MetaManifold.Evidence.Prelude
open import MetaManifold.Evidence.Residual

Echo : ∀ {a b} {A : Set a} {B : Set b} → (A → B) → B → Set (a ⊔ b)
Echo f y = Σ _ (λ x → f x ≡ y)

-- An artefact over y carries semantic fibre exactly when its echo fibre is
-- inhabited.  This mirrors Julia's  avec_fibre(fiber) = !isempty(fiber.witnesses).
data AvecFibre {a b} {A : Set a} {B : Set b} (f : A → B) (y : B) : Set (a ⊔ b) where
  carries : (x : A) (p : f x ≡ y) → AvecFibre f y

sans-fibre : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) (y : B) → Set (a ⊔ b)
sans-fibre {A = A} f y = (x : A) → ¬ (f x ≡ y)
-- (kept pointful so it reads as "no witness exists"; equivalent to ¬ Echo)

sans-fibre-no-witness :
  ∀ {a b} {A : Set a} {B : Set b} {f : A → B} {y : B} →
  sans-fibre f y → (x : A) → ¬ (f x ≡ y)
sans-fibre-no-witness h x p = h x p

-- Echo fibres are exactly Candidates with trivial (always-true) evidence.
Echo-as-Candidate :
  ∀ {a b} {A : Set a} {B : Set b} {f : A → B} {y : B} →
  Echo f y → Candidate f y (λ _ → ⊤)
Echo-as-Candidate (x , p) = x , p , tt

Candidate-as-Echo :
  ∀ {a b} {A : Set a} {B : Set b} {f : A → B} {y : B} →
  Candidate f y (λ _ → ⊤) → Echo f y
Candidate-as-Echo (x , p , _) = x , p

-- Total space of fibres: pairing each input with its fibre over its image.
Total : ∀ {a b} {A : Set a} {B : Set b} → (A → B) → Set (a ⊔ b)
Total {A = A} {B = B} f = Σ B (Echo f)

encode : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) (x : A) → Total f
encode f x = f x , x , refl

-- The left leg of the factorisation is an equivalence (HoTT Book §4.8
-- restated in Echo vocabulary): projecting a fibre down to its witness
-- recovers the input, and every point of the total space is the encoding of
-- its own witness.  Both directions hold by eta-for-Sigma and J; no funext.
fib⁻¹ : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) → Total f → A
fib⁻¹ f (_ , x , _) = x

encode-fib⁻¹ : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) (x : A) →
  fib⁻¹ f (encode f x) ≡ x
encode-fib⁻¹ f x = refl

fib⁻¹-encode : ∀ {a b} {A : Set a} {B : Set b} (f : A → B) (t : Total f) →
  encode f (fib⁻¹ f t) ≡ t
fib⁻¹-encode f (y , x , p) = J (λ y′ q → encode f x ≡ (y′ , x , q)) refl p

-- Residue: what the observation could not distinguish, made first-class.
-- The cloud-size heuristic in the UI (log(1 + count)) is a *presentation*
-- choice over this count; the fibre itself is the semantics.
fibre-count : ∀ {a b} {A : Set a} {B : Set b} {f : A → B} {y : B} →
  List A → Nat
fibre-count xs = fibre-count′ xs
  where
    fibre-count′ : ∀ {a} {A : Set a} → List A → Nat
    fibre-count′ [] = zero
    fibre-count′ (_ ∷ xs) = suc (fibre-count′ xs)
