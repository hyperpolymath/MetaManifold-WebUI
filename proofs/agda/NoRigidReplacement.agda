------------------------------------------------------------------------
-- SPDX-License-Identifier: CC-BY-SA-4.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- The impossibility statement behind the warning that every zero replacement is biased
-- (issue #21). The Julia provenance carries the sentence
--
--     "a replaced value is not a measurement: no rule determined by the observed data can be
--      faithful for both of two datasets that agree on which entries are zero"
--
-- and `src/analysis/zero_replacement.jl` cites this file for it. This is that sentence as a
-- theorem.
--
-- The setting. A sample is a world with two components: the part that is observed, and the
-- value a masked (zero) part would have carried had the sequencing depth been higher. The
-- pipeline only ever computes with the observed component — `observe` is the map from worlds
-- to data. A "replacement rule" is any function of the observed data at all: a pseudocount,
-- the multiplicative policy, the GBM posterior mean, a neural network, or a human being
-- looking at the table. The theorem says none of them can be faithful.
--
-- The reason is one fibre. Two worlds `(x , 0)` and `(x , 1)` are indistinguishable to every
-- function of `observe`, because `observe` maps both to `x`. A function's value is decided by
-- its argument, so any rule gives the same answer in both worlds; at most one of those
-- answers is right. This is the "echo" of information loss made concrete: it is what
-- `echo-types` calls a proof-relevant fibre, and it is why the replacement policy is an
-- assumption to be declared (delta, alpha, threshold: all three are in the provenance), not
-- a measurement to be validated.
--
-- Nothing here is negative about the policies: the laws the operators do satisfy are proved
-- in proofs/agda/ZeroReplacement.agda. The two files together say the useful thing —
-- *replacement preserves what you can check from the observed data (the total and the ratios
-- among observed parts) and cannot recover what you cannot check (the values that were not
-- observed)*.
--
-- What is deliberately NOT here: the corresponding statements for a real-valued model with
-- noise (the countable fibre above is enough for the impossibility), and any claim about
-- which policy is "best" — that is a modelling question, and docs/statistics/zero-handling.md
-- says so in the same words.
------------------------------------------------------------------------
module NoRigidReplacement where

open import Data.Rational using (ℚ)
open import Data.Rational.Base using (0ℚ; 1ℚ)
open import Data.Rational.Properties using (1≢0)
open import Data.Product using (Σ; _×_; _,_)
open import Relation.Nullary.Negation using (¬_)
open import Relation.Binary.PropositionalEquality using (_≡_; _≢_; refl; sym; trans)

------------------------------------------------------------------------
-- Worlds and the data they leave behind
------------------------------------------------------------------------

-- A sample, as far as this theorem is concerned: what was observed, and what the masked
-- entries would have carried. `observed` is the whole summary of the data — everything the
-- pipeline can compute with is a function of it.
record World : Set where
  constructor _,_
  field observed masked : ℚ

open World

-- The data: the observed component only. Non-injective, and that is the point.
observe : World → ℚ
observe = observed

-- The truth a replacement rule would have to reproduce for a masked part.
truth : World → ℚ
truth = masked

-- `0ℚ` and `1ℚ` are distinct, in the direction this file needs.
0≢1 : 0ℚ ≢ 1ℚ
0≢1 h = 1≢0 (sym h)

------------------------------------------------------------------------
-- The loss is a fibre with two elements
------------------------------------------------------------------------

-- One observation, two worlds: identical data, different masked values. The observation map
-- does not separate them, and no analysis of the data can.
two-worlds-one-observation :
  Σ World (λ w → Σ World (λ v → (observe w ≡ observe v) × (masked w ≢ masked v)))
two-worlds-one-observation = (0ℚ , 0ℚ) , ((0ℚ , 1ℚ) , (refl , 0≢1))

------------------------------------------------------------------------
-- No rule computed from the data can be faithful
------------------------------------------------------------------------

-- Any replacement rule at all — any function from observed tables to replacement values —
-- fails on one of the two worlds above: it returns the same number in both, and the two
-- worlds need different numbers. This is the formal content of
-- `zero_replacement_is_biased` in the Julia provenance.
no-faithful-rule :
  (rule : ℚ → ℚ) → ¬ (∀ w → rule (observe w) ≡ masked w)
no-faithful-rule rule faithful =
  0≢1 (trans (sym (faithful (0ℚ , 0ℚ))) (faithful (0ℚ , 1ℚ)))
