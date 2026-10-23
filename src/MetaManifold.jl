module MetaManifold

# Core
include("core/types.jl")
include("core/epistemic.jl")
include("core/r_runtime.jl")
# Provenance probes R through the shared runtime lock, so it follows r_runtime.jl.
include("core/provenance.jl")
# Tools registers the children it starts with the probe, so it precedes pipeline/.
include("core/memory_probe.jl")
include("core/log.jl")
# DOI / Zenodo publication client. Publication is disabled by default
# (DOI_ENABLED=true + ZENODO_TOKEN required) and never rewrites scientific
# objects. See docs/doi-publication.md.
include("core/doi.jl")
include("core/config.jl")
include("core/databases.jl")
include("core/duckdb_store.jl")
include("core/validate.jl")
include("core/project.jl")
include("core/categories.jl")
include("core/composition_library.jl")
# Evidence Mode: the epistemic record of a run (claims, fibres, residuals).
# Reads existing results and provenance; writes only into evidence/.
include("core/evidence.jl")
include("core/primers_library.jl")
include("core/databases_library.jl")

# Annotation

# Pipeline
include("pipeline/tools.jl")
include("pipeline/remote_exec.jl")
include("pipeline/merge_taxa.jl")
include("pipeline/dada2.jl")
include("pipeline/swarm.jl")
include("pipeline/phylogeny.jl")

# Canonical JSON precedes validated analyses: exact values and derived records
# use deterministic bytes for hashing and content-addressing.
include("canonical.jl")

# Analysis
include("analysis/clade_cumulus.jl")
include("analysis/diversity.jl")
include("analysis/analysis.jl")
include("analysis/compositional.jl")
include("analysis/differential.jl")
# Opt-in validated descriptive statistics (issue #1). Ordinary workflows above
# remain unchanged; these modes must be selected explicitly.
include("analysis/numeric_policy.jl")
# The approved method catalogue is checked against NumericPolicy limits before
# the methods it describes are loaded.
include("analysis/method_catalogue.jl")
include("analysis/exact_summaries.jl")
include("analysis/high_precision.jl")
include("analysis/derived_analyses.jl")
include("analysis/ordination.jl")

# Web server
include("server/server.jl")

end
