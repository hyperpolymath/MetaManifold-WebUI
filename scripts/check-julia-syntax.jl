#!/usr/bin/env julia
# Parse every tracked Julia source with the pinned runtime before CI spends time
# installing scientific/frontend dependencies. This checks syntax only; package
# loading and behavior remain covered by the test suite.
#
# Meta.parseall does not throw for every parser failure: an unterminated block
# can be returned as Expr(:incomplete), which a bare try/catch would accept.
# Parse each expression explicitly and reject both error and incomplete results.
files = sort(filter(f -> endswith(f, ".jl"),
                    split(read(`git ls-files -z`, String), '\0')))
failed = false
for file in files
    issue = nothing
    try
        source = read(file, String)
        position = 1
        while position <= ncodeunits(source)
            ex, next_position = Meta.parse(source, position; filename=file)
            if Meta.isexpr(ex, :error) || Meta.isexpr(ex, :incomplete)
                issue = ex
                break
            end
            if ex === :end
                issue = "stray `end` at top level (missing or duplicated opener in this file)"
                break
            end
            next_position > position ||
                error("Julia parser made no progress at code unit $position")
            position = next_position
        end
    catch err
        issue = err
    end
    if !isnothing(issue)
        failed = true
        println(stderr, "Julia parse failed in $file:")
        println(stderr, issue isa AbstractString ? issue : sprint(showerror, issue))
    end
end
failed && exit(1)
println("Julia parser accepted $(length(files)) tracked source files.")
