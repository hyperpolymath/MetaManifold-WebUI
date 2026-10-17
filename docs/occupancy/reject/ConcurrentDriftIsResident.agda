{-# OPTIONS --safe --without-K #-}
-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-- A completed stage has released both tasks; retaining ASV is the wrong claim.
module ConcurrentDriftIsResident where
open import ResourceAlgebra.Prelude
open import GradedStages
import Data.Integer as Int
wrong : concurrent-completed-drift ≡ Int.+ 9176
wrong = refl
