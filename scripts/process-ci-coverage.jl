# SPDX-License-Identifier: AGPL-3.0-only
# CI tooling lives in a temporary environment, separate from the app lockfile.
using Pkg
Pkg.activate(; temp=true)
Pkg.add(PackageSpec(name="CoverageTools", version="1.4.2"))
using CoverageTools
LCOV.writefile("lcov.info", process_folder("src"))

# Report which src/ files reached lcov.info, so a change of coverage mode is
# visible in the log: a file missing here is a file Codecov will not see.
let files = sort([m.captures[1] for l in eachline("lcov.info") if (m = match(r"^SF:(.*)$", l)) !== nothing])
    println("lcov.info covers ", length(files), " source files")
    foreach(f -> println("  ", f), files)
    on_disk = sort(replace.(filter(endswith(".jl"), [joinpath(r, f) for (r, _, fs) in walkdir("src") for f in fs]), "\\" => "/"))
    missing_files = setdiff(on_disk, files)
    println("src/ files absent from lcov.info: ", length(missing_files))
    foreach(f -> println("  ", f), missing_files)
end
