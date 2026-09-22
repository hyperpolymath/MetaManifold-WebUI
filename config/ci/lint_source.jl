#!/usr/bin/env julia
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# ---------------------------------------------------------------------------
# Static source lint for the bug classes that this repository has actually
# shipped. Every check below corresponds to a defect that reached CI and cost
# a full ~26 minute run to discover. They are cheap to catch in seconds.
#
# Run:  julia --project=. config/ci/lint_source.jl
# Exit: 0 clean, 1 if any check fails.
#
# Deliberately dependency-free (Base only) so it can run before Pkg.instantiate
# and cannot itself be broken by a dependency problem.
# ---------------------------------------------------------------------------

const ROOT = dirname(dirname(dirname(abspath(@__FILE__))))
const failures = String[]

function note(check::AbstractString, file::AbstractString, line::Int, msg::AbstractString)
    push!(failures, "$check: $(relpath(file, ROOT)):$line — $msg")
end

src_files() = [joinpath(dp, f) for (dp, _, fs) in walkdir(joinpath(ROOT, "src"))
               for f in fs if endswith(f, ".jl")]
test_files() = [joinpath(dp, f) for (dp, _, fs) in walkdir(joinpath(ROOT, "test"))
                for f in fs if endswith(f, ".jl")]

# ---------------------------------------------------------------------------
# Check 1 — module/struct name collision.
#
# `module AnalysisConfig` containing `struct AnalysisConfig` means
# `using MetaManifold.AnalysisConfig` binds the *struct*, not the module, and
# every qualified reference through it dies with a FieldError. This single
# design decision caused four separate CI failures.
# ---------------------------------------------------------------------------
# Known, deliberately deferred collisions. Each entry is a real hazard that is
# currently worked around rather than fixed, kept here so the debt is visible and
# so the gate still fails on any NEW collision.
const KNOWN_NAME_COLLISIONS = Set{Tuple{String,Symbol}}([
    # `module AnalysisConfig` contains `struct AnalysisConfig`. Renaming either is
    # a breaking change to the public API, so call sites use
    # `using MetaManifold: AnalysisConfig` instead. See the comment in runtests.jl.
    ("src/analysis/AnalysisConfig.jl", :AnalysisConfig),
])

function check_name_collisions()
    # Uses Julia's own parser rather than counting `end` tokens: naive line
    # scanning pops the module stack at the first function's `end` and misses
    # the collision entirely.
    struct_names(ex, acc) = acc
    function collect_structs(ex::Expr, acc::Vector{Symbol})
        if ex.head === :struct
            sig = ex.args[2]
            # `struct Foo{T}` parses to Expr(:call, :Foo, ...); anything else we skip.
            nm = sig isa Symbol ? sig : (sig isa Expr && sig.args[1] isa Symbol ? sig.args[1] : nothing)
            nm === nothing || push!(acc, nm)
        end
        for a in ex.args
            a isa Expr && collect_structs(a, acc)
        end
        return acc
    end
    function walk(ex::Expr, file::AbstractString, enclosing::Vector{Symbol})
        if ex.head === :module && length(ex.args) >= 3
            name = ex.args[2]::Symbol
            body = ex.args[3]
            structs = body isa Expr ? collect_structs(body, Symbol[]) : Symbol[]
            if name in structs && !((relpath(file, ROOT), name) in KNOWN_NAME_COLLISIONS)
                ln = findfirst(l -> occursin(Regex("^\\s*struct\\s+$name\\b"), l), collect(eachline(file)))
                note("module-struct-collision", file, something(ln, 0),
                     "module `$name` contains `struct $name`; `using MetaManifold.$name` binds the " *
                     "struct, not the module, and every qualified reference through it fails with a " *
                     "FieldError. Import with `using MetaManifold: $name`, or rename one of them.")
            end
            push!(enclosing, name)
            body isa Expr && walk(body, file, enclosing)
            pop!(enclosing)
            return
        end
        for a in ex.args
            a isa Expr && walk(a, file, enclosing)
        end
    end
    for file in src_files()
        ex = Meta.parseall(read(file, String))
        ex isa Expr && walk(ex, file, Symbol[])
    end
end

# ---------------------------------------------------------------------------
# Check 2 — `\$identifier` inside an interpolating string.
#
# In a normal Julia string `\$x` is a literal backslash-dollar, so
# "metadata_columns '\$col' not found" prints `$col` verbatim. That silently
# degraded ~50 diagnostics and broke two tests that matched on the value.
# Raw strings and comments are exempt: there `\$` is intentional.
# ---------------------------------------------------------------------------
function check_escaped_interpolation()
    for file in vcat(src_files(), test_files())
        in_raw = false
        in_r = false
        for (i, line) in enumerate(eachline(file))
            s = strip(line)
            startswith(s, '#') && continue
            # R source embedded in Julia: `\$` there is R's list accessor and is
            # correct, e.g. `wilcox.test(x)$p.value` inside RCall.reval.
            if in_r
                occursin("\"\"\"", line) && (in_r = false)
                continue
            end
            if occursin("reval(\"\"\"", line) || occursin("R\"\"\"", line)
                in_r = true
                continue
            end
            # crude raw-string tracking: raw""" ... """ and raw"..."
            in_raw ⊻= occursin("raw\"\"\"", line)
            in_raw && continue
            occursin("raw\"", line) && continue
            if occursin(r"\\\$[A-Za-z_]", line)
                note("escaped-interpolation", file, i,
                     "`\\\$` in an interpolating string prints a literal backslash-dollar. " *
                     "Use `\$` to interpolate, or a raw string if the backslash is intended.")
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Check 3 — two adjacent docstrings.
#
# A docstring followed immediately by another docstring makes Julia try to
# document the *first* one, producing
# "ERROR: cannot document the following expression" at load time. This is the
# same lowering trap as the module-docstring bug that opened this whole chain.
# ---------------------------------------------------------------------------
function check_adjacent_docstrings()
    for file in vcat(src_files(), test_files())
        lines = readlines(file)
        closing = 0
        for (i, line) in enumerate(lines)
            s = strip(line)
            startswith(s, '#') && continue
            if s == "\"\"\""
                if closing == i - 1
                    note("adjacent-docstrings", file, i,
                         "two docstring blocks are adjacent; the earlier one has nothing to " *
                         "attach to and loading fails with `cannot document the following expression`.")
                end
                closing = i
            elseif !isempty(s)
                closing = 0
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Check 4 — packages `using`'d in src/ but not declared in Project.toml.
#
# `using Statistics` in Execution.jl with Statistics missing from [deps] made
# precompilation fail outright.
#
# The first version of this check had two false negatives, and `import Printf`
# walked through both of them: it passed this gate locally and failed
# precompilation in CI with "Package MetaManifold does not have Printf in its
# dependencies" -- precisely the failure the check exists to prevent.
#
#   1. It exempted a list of "stdlibs that need no [deps] entry", Printf among
#      them. There is no such class of name. A stdlib used by a package must be
#      declared like any other dependency; only Base, Core and Main are bound
#      without a declaration. Verified by experiment against every name the old
#      list contained: each one fails with "does not have X in its dependencies"
#      when undeclared.
#   2. It matched one name per line, so `using JSON3, YAML` checked JSON3 and
#      never looked at YAML.
#
# Both are fixed by parsing the statement rather than pattern-matching its text:
# the AST has already resolved comma lists, relative imports and `using A: b, c`
# selection, none of which need guessing at. `self_test_declared_deps` below
# replays the exact input that defeated the old version, so a future rewrite that
# reintroduces either blind spot fails the gate instead of silently passing it.
# ---------------------------------------------------------------------------

# Bound in every module without a declaration. This list is deliberately tiny,
# and deliberately not a list of stdlibs: a stdlib is an ordinary dependency.
const ALWAYS_BOUND = Set(["Base", "Core", "Main"])

"""Root module of one `using`/`import` target, or `nothing` if it is relative."""
function imported_root(x)::Union{Symbol,Nothing}
    x isa Symbol && return x === :. ? nothing : x
    x isa QuoteNode && return imported_root(x.value)
    x isa Expr || return nothing
    # `using A`, `using A.B`, `using A, B` -- first arg is the root, except for
    # `using .A` / `using ..A`, which are relative and name no dependency.
    x.head === :. && return isempty(x.args) ? nothing : imported_root(x.args[1])
    x.head === :(:) && return imported_root(x.args[1])   # `using A: b, c`
    return nothing
end

"""Package names `source` imports that `project_text` does not declare."""
function undeclared_deps(project_text::AbstractString, source::AbstractString)::Vector{String}
    declared = Set{String}(m.captures[1] for m in eachmatch(r"^([A-Za-z0-9_]+)\s*=\s*\""m, project_text))
    # A package refers to itself by name inside its own source; that is not a dep.
    self_name = match(r"^name\s*=\s*\"([A-Za-z0-9_]+)\""m, project_text)
    self_name !== nothing && push!(declared, self_name.captures[1])

    found = String[]
    function walk(node)
        node isa Expr || return nothing
        if node.head === :using || node.head === :import
            for arg in node.args
                root = imported_root(arg)
                root === nothing && continue
                name = String(root)
                (name in declared || name in ALWAYS_BOUND || name in found) && continue
                push!(found, name)
            end
        end
        for a in node.args
            walk(a)
        end
        return nothing
    end
    walk(Meta.parseall(source))
    return found
end

function check_declared_deps()
    project = read(joinpath(ROOT, "Project.toml"), String)
    for file in src_files()
        lines = readlines(file)
        for pkg in undeclared_deps(project, read(file, String))
            # Point at the statement, not at the top of the file.
            ln = findfirst(l -> occursin(r"^\s*(?:using|import)\b", l) && occursin(pkg, l), lines)
            note("undeclared-dependency", file, something(ln, 0),
                 "`$pkg` is used but absent from Project.toml [deps]; precompilation will fail.")
        end
    end
end

# ---------------------------------------------------------------------------
# Check 4b — check 4, tested against the input that defeated it.
#
# A gate that cannot fail is decoration. Each case below is a defect that
# actually reached CI (the first two) or its inverse, which would be a false
# positive and just as damaging to trust in the gate.
# ---------------------------------------------------------------------------
function self_test_declared_deps()
    fixture = """
    name = "Fixture"

    [deps]
    JSON3 = "0f8b85d8-7281-11e9-16c2-39a750bddbf1"
    Statistics = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
    """
    cases = [
        # 1. The defect that motivated this rewrite: an undeclared STDLIB.
        #    `import Printf` passed the old check and failed CI precompilation.
        ("using JSON3\nimport Printf\n", ["Printf"], "an undeclared stdlib"),
        # 2. The second name in a comma list -- never examined by the old check.
        ("using JSON3, YAML\n", ["YAML"], "a name after the first in a using list"),
        # 3. Inverses: none of these is a dependency.
        ("using ..Sibling\nusing .Local\nusing Fixture: Thing\nusing Fixture.Child\n",
         String[], "relative and self imports"),
        # 4. A declared stdlib is fine, and must not be reported.
        ("import Statistics\n", String[], "a declared stdlib"),
    ]
    for (source, expected, what) in cases
        got = sort(undeclared_deps(fixture, source))
        got == sort(expected) && continue
        note("lint-self-test", joinpath("config", "ci", "lint_source.jl"), 0,
             "the declared-dependency check is wrong about $what: expected $(sort(expected)), " *
             "got $got. Fix the check before trusting it.")
    end
end

# ---------------------------------------------------------------------------
# Check 5 — every `Module.member` referenced in test/ is actually imported.
#
# runtests.jl forgot `Statistics` and `SHA`, so tests raised UndefVarError
# instead of testing anything. Purely textual on purpose: loading the package
# to resolve names would make this gate as slow and as fragile as the thing it
# is meant to pre-empt.
# ---------------------------------------------------------------------------

"""Strip `#` comments and string literals so qualifiers inside text are ignored."""
function strip_noise(line::AbstractString)::String
    out = IOBuffer()
    i = firstindex(line)
    in_str = false
    in_char = false
    while i <= ncodeunits(line)
        c = line[i]
        ni = nextind(line, i)
        if in_str
            if c == '\\'
                i = nextind(line, ni); continue
            end
            c == '"' && (in_str = false)
            i = ni; continue
        end
        if in_char
            if c == '\\'
                i = nextind(line, ni); continue
            end
            c == '\'' && (in_char = false)
            i = ni; continue
        end
        if c == '"'; in_str = true; i = ni; continue; end
        if c == '\''; in_char = true; i = ni; continue; end
        c == '#' && break
        write(out, c)
        i = ni
    end
    return String(take!(out))
end

"""Module names brought into scope by the test harness's using/import lines."""
function harness_imports(harness::AbstractString)::Set{String}
    mods = Set{String}()
    for line in eachline(harness)
        s = strip(line)
        (startswith(s, "using ") || startswith(s, "import ")) || continue
        for stmt in split(replace(s, r"^(using|import)\s+" => ""), ",")
            stmt = strip(stmt)
            # `using A: x, y` brings A and the listed names
            if occursin(':', stmt)
                head, tail = split(stmt, ":"; limit=2)
                for part in split(head, "."); push!(mods, strip(part)); end
                for name in split(tail, ","); push!(mods, strip(name)); end
            else
                push!(mods, strip(split(stmt, ".")[end]))
                for part in split(stmt, "."); push!(mods, strip(part)); end
            end
        end
    end
    return mods
end

"""
Module names a test file pulls in via `include`, e.g.
`include(joinpath(@__DIR__, "..", "scripts", "migrate_composition.jl"))`, which
defines `module MigrateComposition`.
"""
function included_modules(file::AbstractString)::Set{String}
    names = Set{String}()
    for line in eachline(file)
        # No need to match the quotes: a non-file false match is harmless because
        # the `target in fs` check below only accepts real files in this repo.
        for m in eachmatch(r"([A-Za-z0-9_\-]+\.jl)", line)
            target = m.captures[1]
            for (dp, _, fs) in walkdir(ROOT)
                target in fs || continue
                cand = joinpath(dp, target)
                for l2 in eachline(cand)
                    mm = match(r"^\s*module\s+([A-Z][A-Za-z0-9_]*)", l2)
                    mm !== nothing && push!(names, mm.captures[1])
                end
            end
        end
    end
    return names
end

"""Names a test file defines for itself (structs, modules, local bindings)."""
function local_definitions(file::AbstractString)::Set{String}
    names = Set{String}()
    for line in eachline(file)
        s = strip(strip_noise(line))
        for pat in (r"^(?:mutable\s+)?struct\s+([A-Z][A-Za-z0-9_]*)",
                    r"^module\s+([A-Z][A-Za-z0-9_]*)",
                    r"^abstract type\s+([A-Z][A-Za-z0-9_]*)",
                    r"^const\s+([A-Z][A-Za-z0-9_]*)",
                    r"^([A-Z][A-Za-z0-9_]*)\s*=")
            m = match(pat, s)
            m !== nothing && push!(names, m.captures[1])
        end
    end
    return names
end

function check_test_imports()
    harness = joinpath(ROOT, "test", "runtests.jl")
    isfile(harness) || return
    imported = harness_imports(harness)
    # Resolvable without any import at all.
    always = Set(["Base", "Core", "Main", "Sys", "Threads", "Test", "Docs", "Meta",
                  "Dates", "Printf", "Markdown", "VERSION", "PROGRAM_FILE"])
    for file in test_files()
        local_defs = local_definitions(file)
        # Test files carry their own `using` lines as well as inheriting the harness's.
        in_scope = union(imported, harness_imports(file), included_modules(file))
        for (i, line) in enumerate(eachline(file))
            code = strip_noise(line)
            isempty(strip(code)) && continue
            # The lookbehind matters: in `SV.ServerState.set_root!` only `SV` is a
            # qualifier that has to be imported; `ServerState` is its member.
            for m in eachmatch(r"(?<![\.\w])([A-Z][A-Za-z0-9_]*)\s*\.\s*[a-z_(]", code)
                mod = m.captures[1]
                (mod in always || mod in in_scope || mod in local_defs) && continue
                note("test-imports", file, i,
                     "`$mod` is referenced but not imported by test/runtests.jl and not defined " *
                     "locally; these tests raise UndefVarError instead of running.")
                break   # one report per line is enough
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Check 6 — every top-level source file parses.
#
# Cheapest possible guard, and it catches the mis-nested definitions that a
# syntax-only read of a diff will not reveal.
# ---------------------------------------------------------------------------
function check_parses()
    for file in vcat(src_files(), test_files())
        ex = Meta.parseall(read(file, String))
        if ex.head == :toplevel && any(a isa Expr && a.head == :error for a in ex.args)
            for a in ex.args
                a isa Expr && a.head == :error &&
                    note("parse", file, 0, "does not parse: $a")
            end
        end
    end
end

for (name, f) in [("parse", check_parses),
                  ("module/struct collisions", check_name_collisions),
                  ("escaped interpolation", check_escaped_interpolation),
                  ("adjacent docstrings", check_adjacent_docstrings),
                  ("declared dependencies", check_declared_deps),
                  ("dependency check self-test", self_test_declared_deps),
                  ("test imports", check_test_imports)]
    n = length(failures)
    try
        f()
    catch e
        push!(failures, "lint crashed in check `$name`: $e")
    end
    println(rpad("  $name", 30), length(failures) == n ? "ok" : "$(length(failures) - n) problem(s)")
end

println()
if isempty(failures)
    println("source lint: clean")
    exit(0)
else
    println("source lint: $(length(failures)) problem(s)")
    for f in failures; println("  ✗ $f"); end
    exit(1)
end
