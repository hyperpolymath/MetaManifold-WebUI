# SPDX-License-Identifier: AGPL-3.0-only
module MetaManifold

# Core
include("core/types.jl")
include("core/r_runtime.jl")
# Provenance probes R through the shared runtime lock, so it follows r_runtime.jl.
include("core/provenance.jl")
include("core/log.jl")
include("core/config.jl")
include("core/databases.jl")
include("core/duckdb_store.jl")
include("core/validate.jl")
include("core/project.jl")
include("core/categories.jl")
include("core/composition_library.jl")
include("core/primers_library.jl")
include("core/databases_library.jl")
include("core/epistemic.jl")

# Annotation
include("annotation/funcdb.jl")

# Pipeline
include("pipeline/tools.jl")
include("pipeline/merge_taxa.jl")
include("pipeline/dada2.jl")
include("pipeline/swarm.jl")

# DOI infrastructure is independent of the scientific/R runtime.
include("doi/Storage.jl")
include("doi/Zenodo.jl")
include("doi/Bundles.jl")
include("doi/Publications.jl")
include("doi/Web.jl")

# Analysis
include("analysis/numeric_policy.jl")
# Exact summaries are catalogue item 1 and are built on the numeric policy, so they follow it.
include("analysis/exact_summaries.jl")
include("analysis/diversity.jl")
include("analysis/analysis.jl")
include("analysis/AnalysisConfig.jl")
include("doi/AnalysisStore.jl")
include("analysis/clade_cumulus.jl")
# Zero replacement (issue #21): the exact multiplicative and Bayesian-multiplicative
# operators, the refusals that keep a zero from being reported as an observation, and the
# provenance a DOI bundle needs. Execution's zero_policy branches and AnalysisConfig's
# context help both use it, so it follows AnalysisConfig and precedes Execution.
include("analysis/zero_replacement.jl")
# Quasi-likelihood dispersion estimation for the negative binomial GLM (the pure-Julia port
# of glmGamPoi's dispersion pipeline, issue #21). Estimation dispatches to it for
# dispersion_method = "glmGamPoi", so it must be included before estimation.
include("analysis/dispersion.jl")
# Estimation fits what AnalysisConfig declares and Execution runs it, so it sits between them.
include("analysis/estimation.jl")
# Library-size scaling factors and the offsets count models are fitted with. Included
# before Execution, which is the only consumer: prepare_analysis_table decides what the
# response is and which offset it gets, and Scaling computes both under the conditions
# published in docs/statistics/method-conditions/scaling-and-offsets.md.
include("analysis/scaling.jl")
# ILR bases (issue #20): phylogenetic, SBP, balance dendrogram. Before Execution, which uses it.
include("analysis/ilr_basis.jl")
include("analysis/Execution.jl")

end
