-- SPDX-License-Identifier: AGPL-3.0-only
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- The gate entry point.  Type-checking this one module type-checks every proof
-- in the tree, which is what `just proofs` and `.github/workflows/proofs.yml`
-- do.  A module that is not imported here is not checked, so adding a module
-- without adding it here is a silent gap: `proofs/tests/axiom-audit.sh`
-- reports every `.agda` file under this directory that `All.agda` does not
-- reach, and its control proves that the report can be non-empty.

{-# OPTIONS --without-K --safe #-}

module MetaManifold.All where

open import MetaManifold.Prelude public
open import MetaManifold.Proportions public
open import MetaManifold.ExactCounts public
open import MetaManifold.PermutationTest public
open import MetaManifold.BenjaminiHochberg public
open import MetaManifold.DecimalRounding public
