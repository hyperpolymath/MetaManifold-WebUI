#!/usr/bin/env julia
# Parse every tracked Julia source with the pinned runtime before CI spends time
# installing scientific/frontend dependencies. This checks syntax only; package
# loading and behavior remain covered by the test suite.
files = sort(filter(f -> endswith(f, ".jl"),
                    split(read(`git ls-files -z`, String), '\0')))
failed = false
for file in files
    try
        Meta.parseall(read(file, String))
    catch err
        failed = true
        println(stderr, "Julia parse failed in $file:")
        println(stderr, sprint(showerror, err))
    end
end
failed && exit(1)
println("Julia parser accepted $(length(files)) tracked source files.")
