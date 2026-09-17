# SPDX-License-Identifier: AGPL-3.0-only
root = joinpath(@__DIR__, "..", "..")
include(joinpath(root, "src/core/types.jl"))
include(joinpath(root, "src/core/log.jl"))
include(joinpath(root, "src/core/config.jl"))
include(joinpath(root, "src/core/databases.jl"))
using .Databases
Databases.ensure_databases(joinpath(root, "config/ci/databases.yml"))
