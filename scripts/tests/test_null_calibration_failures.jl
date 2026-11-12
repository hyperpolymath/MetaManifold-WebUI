# SPDX-License-Identifier: MPL-2.0
# CSV parsing and annotation escaping for null-calibration package failures.
#
# Run: julia --startup-file=no scripts/tests/test_null_calibration_failures.jl
using Test

include(joinpath(@__DIR__, "..", "..", "bench", "null_calibration", "report_failures.jl"))

# One CSV field as Python's csv.writer (QUOTE_MINIMAL) writes it.
csv_field(v) = v === nothing ? "" : begin
    s = string(v)
    occursin(r"[\",\r\n]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s
end

write_rows(path, fields, rows) = open(path, "w") do io
    write(io, join(fields, ","), "\n")
    for row in rows
        write(io, join((csv_field(get(row, f, nothing)) for f in fields), ","), "\n")
    end
end

annotations_for(path, cell) = open(io -> failure_annotations(io, cell), path)

function result_row(; test, status, note = nothing)
    Dict("truth" => "null", "shape" => "original", "offset" => "tss", "n_per" => 4,
         "taxa" => 40, "sim" => 1, "taxon" => 1, "true_log2fc" => 0,
         "test" => test, "status" => status,
         "pvalue" => status == "failed" ? "NA" : 0.01, "note" => note)
end

@testset "failure annotations" begin
    @testset "distinct failures are CSV-aware, deduplicated and escaped" begin
        note_one = "comma, quote \" and newline\ncontinued"
        note_two = "second 50% and carriage\rreturn\ncontinued"
        mktempdir() do directory
            path = joinpath(directory, "pvalues_smoke.csv")
            write_rows(path, RESULT_FIELDS, [
                result_row(test = "duplicate_test", status = "failed", note = note_one),
                result_row(test = "duplicate_test", status = "failed", note = note_one),
                result_row(test = "duplicate_test", status = "failed", note = note_two),
                result_row(test = "missing_note", status = "failed", note = "NA"),
                result_row(test = "ok_test", status = "ok"),
            ])
            cell = "null_original_tss_n4_t40_smoke"
            @test annotations_for(path, cell) == [
                "::warning title=$cell: a requested test failed::duplicate_test :: " *
                "comma, quote \" and newline%0Acontinued",
                "::warning title=$cell: a requested test failed::duplicate_test :: " *
                "second 50%25 and carriage%0Dreturn%0Acontinued",
            ]
        end
    end

    @testset "an unsafe cell label is rejected" begin
        io = IOBuffer(join(RESULT_FIELDS, ",") * "\n")
        @test_throws ArgumentError("unsafe cell label for Actions annotation") failure_annotations(io, "bad\n::notice")
        @test_throws ArgumentError failure_annotations(IOBuffer(""), "trailing\n")
        @test_throws ArgumentError failure_annotations(IOBuffer(""), "")
    end

    @testset "a legacy header without notes yields nothing" begin
        mktempdir() do directory
            path = joinpath(directory, "legacy.csv")
            write_rows(path, LEGACY_FIELDS, [result_row(test = "old_test", status = "failed")])
            @test annotations_for(path, "legacy_cell") == String[]
        end
    end

    @testset "an extra CSV field is rejected" begin
        mktempdir() do directory
            path = joinpath(directory, "malformed.csv")
            write(path, join(RESULT_FIELDS, ",") * "\n" *
                        "null,original,tss,4,40,1,1,0,edger_ql,failed,NA,reason,extra\n")
            err = try annotations_for(path, "bad_cell"); nothing catch e; e end
            @test err isa ArgumentError
            @test occursin("malformed CSV record", err.msg)
        end
    end

    @testset "other boundaries" begin
        @test_throws ArgumentError failure_annotations(IOBuffer(""), "cell")
        @test_throws ArgumentError failure_annotations(IOBuffer("a,b\n1,2\n"), "cell")
        # Blank lines are skipped and do not shift the record numbers of real rows.
        text = join(RESULT_FIELDS, ",") * "\n\n" *
               "null,original,tss,4,40,1,1,0,edger_ql,failed,NA,reason\n\n"
        @test failure_annotations(IOBuffer(text), "c") ==
              ["::warning title=c: a requested test failed::edger_ql :: reason"]
        # CRLF files read the same as LF files.
        crlf = replace(text, "\n" => "\r\n")
        @test failure_annotations(IOBuffer(crlf), "c") == failure_annotations(IOBuffer(text), "c")
        # A short row is malformed.
        short = join(RESULT_FIELDS, ",") * "\nnull,original\n"
        @test_throws ArgumentError failure_annotations(IOBuffer(short), "c")
        # Invalid UTF-8 is an error, not a silent replacement.
        @test_throws ArgumentError failure_annotations(IOBuffer(UInt8[0xff, 0xfe]), "c")
    end
end
