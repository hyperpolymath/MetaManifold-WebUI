# SPDX-License-Identifier: AGPL-3.0-only
# CI tooling lives in a temporary environment, separate from the app lockfile.
using Pkg
Pkg.activate(; temp=true)
Pkg.add(PackageSpec(name="CoverageTools", version="1.4.2"))
using CoverageTools
LCOV.writefile("lcov.info", process_folder("src"))

# Report which src/ files reached lcov.info, so a change of coverage mode is
# visible in the log: a file missing here is a file Codecov will not see.
let files = String[]
    for line in eachline("lcov.info")
        m = match(r"^SF:(.*)$", line)
        m === nothing || push!(files, String(m.captures[1]))
    end
    sort!(files)
    println("lcov.info covers ", length(files), " source files")
    foreach(f -> println("  ", f), files)
    on_disk = String[]
    for (root, _, names) in walkdir("src"), name in names
        endswith(name, ".jl") && push!(on_disk, replace(joinpath(root, name), "\\" => "/"))
    end
    absent = setdiff(sort!(on_disk), files)
    println("src/ files absent from lcov.info: ", length(absent))
    foreach(f -> println("  ", f), absent)
end
