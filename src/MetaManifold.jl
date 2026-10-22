module MetaManifold

# Core
include("core/types.jl")
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

# Canonical JSON: deterministic bytes for hashing and content-addressing.
# Included before the analysis layer because the statistics records are
# content-addressed with it (their analysis id is the SHA-256 of their canonical
# bytes). It depends on SHA only, so nothing else moves.
include("canonical.jl")

# Analysis
include("analysis/diversity.jl")
include("analysis/analysis.jl")
include("analysis/differential.jl")

# Optional exact-arithmetic statistics layer (issue #1). Its own modules; the
# code above neither imports nor calls them, so every existing analysis and
# pipeline path is unchanged when the layer is not selected.
include("analysis/exact_numeric.jl")
include("analysis/exact_statistics.jl")

# Web server
include("server/server.jl")

end
