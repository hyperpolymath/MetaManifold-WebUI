# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): regression test for 01_select.jl.  See ../README.md, section 8.
#
# usage: julia test_select.jl
#
# 01_select.jl tests eligibility (240 bases in the V4 window) on whole rows, then drops every
# column filled in fewer than two selected rows.  A row can lose a V4 base that way.  It must
# then stop with an error and write nothing, because 03_prep.jl needs 240 V4 bases in each row.
# Two synthetic two-row alignments: one where both rows keep 240 V4 bases, one where each row
# loses one.
const V4S = 11894; const LEN = 25400
const SELECT = joinpath(@__DIR__, "01_select.jl")

function row(v4_columns)
    s = fill('-', LEN)
    s[1:960] .= 'A'                        # 960 bases outside the V4 window
    for k in v4_columns; s[k] = 'C'; end   # 240 bases inside it: 1,200 in all
    String(s)
end

function select(dir, rows)
    fasta = joinpath(dir, "in.fasta"); out = joinpath(dir, "out")
    open(fasta, "w") do io
        for (i, r) in enumerate(rows); println(io, ">row", i); println(io, r); end
    end
    log = joinpath(dir, "log.txt")
    p = run(pipeline(ignorestatus(`$(Base.julia_cmd()) $SELECT $fasta $out 2 1`); stdout = log, stderr = log))
    p.exitcode, out, read(log, String)
end

failures = String[]
check(ok, what) = (println(ok ? "ok    " : "FAIL  ", what); ok || push!(failures, what))

mktempdir() do dir
    shared = collect(V4S:V4S+239)
    code, out, log = select(dir, [row(shared), row(shared)])
    check(code == 0, "both rows keep 240 V4 bases: exit status 0")
    check(isfile(joinpath(out, "ref_full.fasta")) && isfile(joinpath(out, "names.tsv")), "both rows keep 240 V4 bases: output written")
    v4 = isfile(joinpath(out, "v4cols.txt")) ? length(split(strip(read(joinpath(out, "v4cols.txt"), String)), ",")) : 0
    check(v4 == 240, "both rows keep 240 V4 bases: 240 V4 columns kept (got $v4)")
end

mktempdir() do dir
    a = collect(V4S:V4S+239)                       # last column is filled in this row only
    b = vcat(collect(V4S:V4S+238), V4S + 300)      # one column filled in this row only
    code, out, log = select(dir, [row(a), row(b)])
    check(code != 0, "each row loses one V4 base: non-zero exit status (got $code)")
    check(occursin("has only 239 V4 bases after column filtering", log), "each row loses one V4 base: error names the count")
    check(!isdir(out), "each row loses one V4 base: no output written")
end

isempty(failures) || (println(length(failures), " check(s) failed"); exit(1))
println("all checks passed")
