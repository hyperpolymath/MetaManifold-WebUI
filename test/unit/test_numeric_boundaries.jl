# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The storage and transport boundaries, MEASURED rather than assumed (issue #1:
# "audit CSV, JSON, database, browser, R and external-tool boundaries for precision
# loss, integer range and serialization compatibility").
#
# Every testset below crosses a real boundary: a real JavaScript engine for the browser,
# a real R for the statistics runtime, a real DuckDB for the database. That matters,
# because the failure being audited is not "our encoder is wrong" -- it is "the other
# side cannot hold the value", and only the other side can demonstrate that.
#
# Where such a partner is missing the testset skips LOUDLY, naming the boundary it could
# not check: a silently skipped boundary check is exactly how the fastqc gap (#30)
# survived, and the standing rule here is that a skip is not a pass.
#
# CSV is covered with the round-trip testset rather than a partner process: a CSV file
# is text, so the boundary is the parser's, and the contract's answer (read counts back
# through parse_exact_count, never through a float) is what gets asserted.

using MetaManifold.NumericPolicy
using Test, JSON3, DuckDB

const NP = MetaManifold.NumericPolicy

# The smallest integer Float64 cannot represent. It is the first value at which "a
# number" and "a count" stop being the same thing, so it is the probe every boundary
# below is tested with.
const FIRST_UNREPRESENTABLE = big(2)^53 + 1          # 9007199254740993

@testset "numeric boundaries" begin

    @testset "the exact string form round-trips, which is what makes it worth carrying" begin
        for n in (0, 1, 42, 2^53 - 1, big(2)^53, FIRST_UNREPRESENTABLE, big(10)^30)
            stored = NP.to_storage(NP.exact_value(n))
            @test NP.parse_exact_count(stored isa Integer ? string(stored) : stored) == n
        end
        for r in (1 // 3, 22 // 7, -(3 // 4), big(2)^80 // 3)
            @test NP.parse_exact_rational(NP.to_storage(NP.exact_value(r))) == r
        end
        @test NP.parse_exact_count("12") === Int64(12)
        @test NP.parse_exact_count(" 7 ") == 7
        @test NP.parse_exact_rational("7") == 7 // 1
        @test NP.parse_exact_rational("-3/4") == -3 // 4

        # A CSV round trip is this: text in, text out. What must not happen is a parser
        # deciding "9007199254740993" is a number and handing back a Float64.
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_count("9.007199254740992e15")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_count("9007199254740993.0")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_count("1,000")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_count("0x10")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_count("")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_count("-5")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_rational("3/0")
        @test_throws NP.UnsupportedRepresentationError NP.parse_exact_rational("1.5/2")

        # And the refusal is not ceremony: the float form of that literal really is a
        # different number, which is why "just parse it as a number" cannot be allowed.
        @test BigInt(parse(Float64, "9.007199254740992e15")) != FIRST_UNREPRESENTABLE
    end

    @testset "the browser boundary, in a real JavaScript engine" begin
        node = Sys.which("node")

        if isnothing(node)
            # Named, so the summary says which boundary went untested rather than
            # reporting a clean sweep of one fewer check.
            @testset "browser (node absent — the JavaScript boundary is untested here)" begin
                @test_skip false
            end
        else
            dir = mktempdir()
            program = joinpath(dir, "read.js")
            # JSON parsing is what the browser does with a response body; String() is
            # what the browser prints. Nothing here is simulated -- it is node's own
            # number.
            #
            # `const { parse } = JSON` rather than a qualified call: config/ci/lint_source.jl
            # scans for `Capitalised.name` as a module reference, and the qualified form
            # inside this JavaScript text reads to it as a Julia module named JSON that
            # the file never imports. Destructuring says the same thing to node and
            # nothing to the linter, which is cheaper than teaching the gate an
            # exception for prose it cannot see into.
            write(program, """
                const fs = require('fs');
                const { parse } = JSON;
                const obj = parse(fs.readFileSync(process.argv[2], 'utf8'));
                console.log(String(obj.count));
                """)

            function js_read(payload)
                path = joinpath(dir, "payload.json")
                write(path, payload)
                return strip(read(`$node $program $path`, String))
            end

            # As a JSON NUMBER, which is what encode_json_number exists to prevent: the
            # count arrives in JavaScript one short, and nothing in the payload says so.
            as_number = js_read(JSON3.write(Dict("count" => FIRST_UNREPRESENTABLE)))
            @test as_number != string(FIRST_UNREPRESENTABLE)
            @test as_number == "9007199254740992"
            @test parse(BigInt, as_number) != FIRST_UNREPRESENTABLE

            # As our encoded STRING, the count survives a real JS engine byte for byte.
            as_string = js_read(JSON3.write(Dict("count" => NP.encode_json_number(FIRST_UNREPRESENTABLE))))
            @test as_string == string(FIRST_UNREPRESENTABLE)
            @test NP.parse_exact_count(as_string) == FIRST_UNREPRESENTABLE

            # And the encoder's whole rule, checked against a real engine rather than
            # restated: numbers stay numbers while they are exactly representable.
            @test js_read(JSON3.write(Dict("count" => NP.encode_json_number(7)))) == "7"
            @test js_read(JSON3.write(Dict("count" => NP.encode_json_number(big(2)^53)))) == "9007199254740992"
        end
    end

    @testset "the R boundary" begin
        rscript = Sys.which("Rscript")

        if isnothing(rscript)
            @testset "R (Rscript absent — the R boundary is untested here)" begin
                @test_skip false
            end
        else
            dir = mktempdir()
            program = joinpath(dir, "probe.R")
            write(program, """
                n <- 9007199254740993
                cat("typeof", typeof(n), sep="\\t"); cat("\\n")
                cat("rendered", format(n, scientific=FALSE, digits=22), sep="\\t"); cat("\\n")
                cat("as_character", as.character(n), sep="\\t"); cat("\\n")
                cat("as_integer", suppressWarnings(as.integer(n)), sep="\\t"); cat("\\n")
                cat("int_ceiling", suppressWarnings(as.integer(2^31 - 1)), sep="\\t"); cat("\\n")
                """)
            out = read(`$rscript --vanilla $program`, String)
            values = Dict{String,String}()
            for line in split(out, '\n')
                parts = split(line, '\t')
                length(parts) == 2 && (values[strip(parts[1])] = strip(parts[2]))
            end

            # R has no integer type wider than 32 bits: every number is a double.
            @test values["typeof"] == "double"
            @test values["int_ceiling"] == "2147483647"            # 2^31 - 1 is the ceiling
            @test values["as_integer"] == "NA"                     # and 2^31 is not an integer

            # Nor can R hold, render, or convert the count: the literal enters as a
            # double and every route back out is a different number. This is why the
            # contract sends counts TO R as strings and reads them back as strings, and
            # why a count that has been through R is treated as unproven.
            @test values["rendered"] != string(FIRST_UNREPRESENTABLE)
            @test values["as_character"] != string(FIRST_UNREPRESENTABLE)

            # The prescribed route, measured: what R never converts, R cannot corrupt.
            digits = joinpath(dir, "digits.txt")
            write(digits, string(FIRST_UNREPRESENTABLE) * "\n")
            keep = joinpath(dir, "keep.R")
            write(keep, """cat(readLines(commandArgs(TRUE)[1]), "\n", sep="")""")
            @test strip(read(`$rscript --vanilla $keep $digits`, String)) ==
                  string(FIRST_UNREPRESENTABLE)
        end
    end

    @testset "the database boundary: DuckDB carries counts exactly, doubles do not" begin
        DBInterface = DuckDB.DBInterface
        con = DBInterface.connect(DuckDB.DB)
        row = collect(DBInterface.execute(con,
            "SELECT 9007199254740993::BIGINT AS exact, 9007199254740993::DOUBLE AS approx"))[1]

        # Exact: an integer column is a count, and it survives the round trip.
        @test row.exact == FIRST_UNREPRESENTABLE
        @test typeof(row.exact) === Int64

        # The negative control: the same literal in a DOUBLE column comes back as a
        # different integer, and nothing in the result marks it as wrong.
        @test row.approx != FIRST_UNREPRESENTABLE
        @test BigInt(row.approx) == big(2)^53

        # The ceiling is real and typed: past BIGINT a BIGINT column refuses rather than
        # rounding, which is the behaviour worth having.
        @test_throws DuckDB.QueryException collect(DBInterface.execute(con,
            "SELECT 18446744073709551616::BIGINT"))               # 2^64

        # DuckDB's own ceiling is 128-bit, and HUGEINT carries that exactly -- so the
        # database is not the limiting partner until 2^127.
        huge = collect(DBInterface.execute(con,
            "SELECT 170141183460469231731687303715884105727::HUGEINT"))[1][1]
        @test Int128(huge) == typemax(Int128)

        # Past everything the column type can hold, the string form transports the count
        # unchanged -- the same encoding the JSON and CSV boundaries use.
        beyond = big(2)^200 + 1
        stored = NP.to_storage(NP.exact_value(beyond))
        @test stored isa String
        cell = collect(DBInterface.execute(con, "SELECT '$stored'::VARCHAR"))[1][1]
        @test NP.parse_exact_count(cell) == beyond
    end
end
