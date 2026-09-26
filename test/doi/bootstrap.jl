# SPDX-License-Identifier: MPL-2.0
# Load the actual publication implementation without importing the scientific/R stack.
module DOIIsolated
const SOURCE = joinpath(@__DIR__, "..", "..", "src", "doi")
include(joinpath(SOURCE, "Storage.jl"))
include(joinpath(SOURCE, "Zenodo.jl"))
include(joinpath(SOURCE, "Bundles.jl"))
include(joinpath(SOURCE, "Publications.jl"))
include(joinpath(SOURCE, "Web.jl"))
end
