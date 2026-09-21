# SPDX-License-Identifier: AGPL-3.0-only
include(joinpath(@__DIR__, "src", "MetaManifoldUI.jl"))
using .MetaManifoldUI, Genie
MetaManifoldUI.configure!()
port = parse(Int, get(ENV, "METAMANIFOLD_UI_PORT", "8081"))
host = get(ENV, "METAMANIFOLD_UI_HOST", "127.0.0.1")
Genie.up(; port, ws_port=port, host, async=false)
