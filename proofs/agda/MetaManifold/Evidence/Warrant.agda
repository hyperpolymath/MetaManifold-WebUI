{-# OPTIONS --safe --without-K #-}
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Warrant without soundness, following hyperpolymath/epistemic-types
-- (MPL-2.0): a warrant is proof-relevant but NOT automatically sound.  Having
-- a receipt for A is a different proposition from A being true; conflating
-- the two is precisely the "scientific misuse: cherry-picking" risk named in
-- MetaManifold-WebUI issue #7.  The Julia `Epistemic.Warrant` /
-- `Epistemic.SoundWarrant` pair and the `epi_status` ladder
-- (:SansFibre → :Belief → :Warranted → :Factive) are finite shadows of the
-- definitions and separation results in this module.

module MetaManifold.Evidence.Warrant where

open import MetaManifold.Evidence.Prelude

-- A warrant for A at standpoint κ exposes only a type of evidence tokens.
-- There is deliberately no field `Evidence → A`: that would make every
-- warrant factive.
record Warrant {kℓ ℓ wℓ : Level} (K : Set kℓ) (κ : K) (A : Set ℓ)
  : Set (kℓ ⊔ ℓ ⊔ lsuc wℓ) where
  constructor mkWarrant
  field
    Evidence : Set wℓ

-- Epi packages a warrant object with a token of it.  Sigma-like, but the
-- evidence type is read from the warrant, so a forged token of the wrong
-- type cannot be smuggled in.
record Epi {kℓ ℓ wℓ : Level} (K : Set kℓ) (κ : K) (A : Set ℓ)
  : Set (kℓ ⊔ ℓ ⊔ lsuc wℓ) where
  constructor epi
  field
    warrant  : Warrant {kℓ = kℓ} {ℓ = ℓ} {wℓ = wℓ} K κ A
    evidence : Warrant.Evidence warrant

-- Soundness is a SEPARATE assumption.  Only after adding it can a token be
-- exchanged for the claim.
record SoundWarrant {kℓ ℓ wℓ : Level} (K : Set kℓ) (κ : K) (A : Set ℓ)
  : Set (kℓ ⊔ ℓ ⊔ lsuc wℓ) where
  constructor soundWarrant
  field
    warrant : Warrant {kℓ = kℓ} {ℓ = ℓ} {wℓ = wℓ} K κ A
    sound   : Warrant.Evidence warrant → A

sound-epi :
  {kℓ ℓ wℓ : Level} {K : Set kℓ} {κ : K} {A : Set ℓ} →
  (sw : SoundWarrant {wℓ = wℓ} K κ A) →
  Warrant.Evidence (SoundWarrant.warrant sw) → A
sound-epi sw token = SoundWarrant.sound sw token

-- Separation: Epi κ A does not give A.  A concrete countermodel — a
-- standpoint with trivial evidence for an uninhabited claim — shows that no
-- general extraction function can exist.  Any code path that treats a
-- warrant token as truth (e.g. an avec_fibre edit applied without checking
-- the receipt) is refuted by this term.
epi-does-not-give :
  ¬ ( (K : Set) (κ : K) (A : Set) (e : Epi {wℓ = lzero} K κ A) → A )
epi-does-not-give extract = ⊥-elim (extract ⊤ tt ⊥ trivial-epi)
  where
    trivial-warrant : Warrant {wℓ = lzero} ⊤ tt ⊥
    trivial-warrant = mkWarrant ⊤

    trivial-epi : Epi {wℓ = lzero} ⊤ tt ⊥
    trivial-epi = epi trivial-warrant tt

-- Forged acceptance stays forged: trivial evidence tokens can never be
-- exchanged for an uninhabited claim, no matter how the warrant is packaged.
no-sound-function-from-trivial-evidence : ¬ (⊤ → ⊥ {lzero})
no-sound-function-from-trivial-evidence f = f tt
