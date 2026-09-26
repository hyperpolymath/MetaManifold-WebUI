-- SPDX-License-Identifier: AGPL-3.0-only
------------------------------------------------------------------------
-- Entry point: type-checking this module checks the whole suite.
-- See docs/formal/verification-plan.md for scope and residue.
------------------------------------------------------------------------
{-# OPTIONS --safe --without-K #-}

module MetaManifold.All where

-- Shared compositional vocabulary (also for issue #21).
import MetaManifold.Composition.Tree
import MetaManifold.Composition.Node
import MetaManifold.Composition.Sum

-- Issue #20: ILR bases from trees, SBPs and dendrograms.
import MetaManifold.ILR.SBP
import MetaManifold.ILR.Contrast
import MetaManifold.ILR.Kernel
import MetaManifold.ILR.Invariance
import MetaManifold.ILR.Orthonormal
import MetaManifold.ILR.Comb
import MetaManifold.ILR.Integer
