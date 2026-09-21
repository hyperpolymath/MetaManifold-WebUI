# SPDX-License-Identifier: AGPL-3.0-only
# CI helper: ensure PR2 databases are present via MetaManifold.Databases
# Fixed from manual includes which broke due to `module` not at top level
# (src/core/*.jl are submodules of MetaManifold, using ..PipelineTypes)

import Pkg
# Activate project from repo root (this file is in config/ci/)
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using MetaManifold
using MetaManifold.Databases

root = joinpath(@__DIR__, "..", "..")
config_path = joinpath(root, "config/ci/databases.yml")
# Fallback to defaults if ci config missing
if !isfile(config_path)
    config_path = joinpath(root, "config/defaults/databases.yml")
end

println("Ensuring databases from $config_path")
dbs = Databases.ensure_databases(config_path)
println("Resolved databases: $dbs")
