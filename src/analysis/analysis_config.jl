# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Backwards-compatibility shim. The canonical implementation is AnalysisConfig.jl
# (capital A): immutable struct, validators, Nickel/DEED schemas, DANGER banner,
# DOI bundles.
#
# ⚠ NO LONGER ON THE LOAD PATH. src/MetaManifold.jl now includes AnalysisConfig.jl
# directly, so this file is loaded only by an external caller that still says
# `include("analysis/analysis_config.jl")`. Including it *in addition to* the
# canonical file would define module AnalysisConfig twice — include one or the
# other, never both.
include("AnalysisConfig.jl")
