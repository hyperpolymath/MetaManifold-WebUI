{-# OPTIONS --safe --without-K #-}
-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Residual evidence — the ordinary evidence-refined preimage fibre, following
-- hyperpolymath/residual-evidence-types (MPL-2.0), restated here so the
-- MetaManifold Evidence Mode has its semantics in one self-contained library.
--
--   Candidate observe r E = Σ World (observe w ≡ r × E w)
--
-- A claim warranted by a case must hold for EVERY admissible candidate, never
-- merely for a chosen inhabitant.  Applying it to the actual world needs both
-- premises (observation match and evidence).  Nothing here is MetaManifold- or
-- microbiome-specific: the finite signed model instantiating it lives in
-- Signed.agda, and the decision procedures the server runs are proved correct
-- against these definitions in Decision.agda.

module MetaManifold.Evidence.Residual where

open import MetaManifold.Evidence.Prelude

-- The evidence-refined preimage fibre.
Candidate : ∀ {w o e} {W : Set w} {O : Set o} →
  (W → O) → O → (W → Set e) → Set (w ⊔ o ⊔ e)
Candidate {W = W} observe r E = Σ W (λ world → (observe world ≡ r) × E world)

-- A case must carry a witness of consistency (inhabitedness).  Claims still
-- quantify over ALL candidates, not merely this chosen inhabitant.
record Case {w o e} {W : Set w} {O : Set o}
  (observe : W → O) (r : O) (E : W → Set e) : Set (w ⊔ o ⊔ e) where
  constructor inhabited
  field
    witness : Candidate observe r E

-- A claim holds for a case when it holds of every admissible candidate's world.
Holds : ∀ {w o e p} {W : Set w} {O : Set o}
  {observe : W → O} {r} {E : W → Set e} →
  Case observe r E → (W → Set p) → Set (w ⊔ o ⊔ e ⊔ p)
Holds {observe = observe} {r} {E} c P = (x : Candidate observe r E) → P (fst x)

-- A query is identified when every admissible candidate agrees on its value.
Identified : ∀ {w o e q} {W : Set w} {O : Set o} {Q : Set q}
  {observe : W → O} {r} {E : W → Set e} →
  Case observe r E → (W → Q) → Set (w ⊔ o ⊔ e ⊔ q)
Identified {Q = Q} c query = Σ Q (λ value → Holds c (λ world → query world ≡ value))

-- Applying a conditional claim to an actual world needs BOTH premises.  This
-- is the honesty boundary of the whole Evidence Mode: a warranted claim about
-- candidate worlds says nothing about reality until the actual world is shown
-- to be one of those candidates.
actual-world-sound : ∀ {w o e p} {W : Set w} {O : Set o}
  {observe : W → O} {r} {E : W → Set e} {P : W → Set p}
  (c : Case observe r E) → Holds c P →
  (actual : W) → observe actual ≡ r → E actual → P actual
actual-world-sound c claim actual observed evidence = claim (actual , observed , evidence)

-- Two admissible worlds that disagree on a query refute identification.
different-candidates-refute-identification :
  ∀ {w o e q} {W : Set w} {O : Set o} {Q : Set q}
  {observe : W → O} {r} {E : W → Set e}
  (c : Case observe r E) (query : W → Q)
  (x y : Candidate observe r E) →
  ¬ (query (fst x) ≡ query (fst y)) → ¬ Identified c query
different-candidates-refute-identification c query x y disagree (value , agrees) =
  ⊥-elim (disagree (trans (agrees x) (sym (agrees y))))

-- Evidence strengthening alone does not promise a consistent new case, but it
-- does transport claims from the weaker case to the stronger one.
refine-candidate : ∀ {w o e f} {W : Set w} {O : Set o}
  {observe : W → O} {r} {E : W → Set e} {F : W → Set f} →
  ((world : W) → F world → E world) → Candidate observe r F → Candidate observe r E
refine-candidate entails (world , observed , evidence) = world , observed , entails world evidence

refine-claim : ∀ {w o e f p} {W : Set w} {O : Set o}
  {observe : W → O} {r} {E : W → Set e} {F : W → Set f} {P : W → Set p} →
  (old : Case observe r E) (new : Case observe r F) →
  ((world : W) → F world → E world) → Holds old P → Holds new P
refine-claim old new entails claim x = claim (refine-candidate entails x)

-- Claims do NOT transfer from a stronger case to a weaker one for free
-- (dropping evidence constraints can invalidate a claim).  Concrete
-- countermodel: two worlds, observation constant, strong evidence admits only
-- world `true`, weak evidence admits both.  "w ≡ true" holds for the strong
-- case and fails for the weak one.  This is the kernel anti-cherry-picking
-- fact: keeping a claim while discarding the evidence that supported it is
-- unsound, so the avec_fibre editor must never let a *label* edit bypass the
-- candidate set (see EvidenceMode.agda for the row-level statement).
module NoFreeWeakening where
  obs-const : Bool → ⊤
  obs-const w = tt

  strong-E : Bool → Set
  strong-E w = w ≡ true

  weak-E : Bool → Set
  weak-E w = ⊤

  strong-case : Case obs-const tt strong-E
  strong-case = inhabited (true , refl , refl)

  weak-case : Case obs-const tt weak-E
  weak-case = inhabited (true , refl , tt)

  strong-holds : Holds strong-case (λ w → w ≡ true)
  strong-holds x = snd (snd x)

no-free-weakening :
  ¬ ( (P : Bool → Set) →
      Holds NoFreeWeakening.strong-case P →
      Holds NoFreeWeakening.weak-case P )
no-free-weakening transfer = ⊥-elim (false≢true impossible-eq)
  where
    open NoFreeWeakening

    false≢true : ¬ (false ≡ true)
    false≢true ()

    weak-claim : Holds weak-case (λ w → w ≡ true)
    weak-claim = transfer (λ w → w ≡ true) strong-holds

    impossible-eq : false ≡ true
    impossible-eq = weak-claim (false , refl , tt)
