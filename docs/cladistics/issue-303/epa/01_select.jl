# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: julia 01_select.jl silva.fasta outdir N seed
# Same eligibility / column rule as placement_evidence.jl load_alignment.
using Random
const V4S = 11894; const V4E = 25319; const FRAG = 240
code(c::UInt8) = c == UInt8('A') ? 0x01 : c == UInt8('C') ? 0x02 : c == UInt8('G') ? 0x03 : (c == UInt8('T') || c == UInt8('U')) ? 0x04 : 0x00
path, out, N, seed = ARGS[1], ARGS[2], parse(Int, ARGS[3]), parse(Int, ARGS[4])
rng = MersenneTwister(seed)
eligible = Int[]; idx = 0
open(path) do io
    while !eof(io)
        readline(io); s = codeunits(readline(io)); global idx += 1
        tot = 0; v4 = 0
        @inbounds for (k, c) in enumerate(s)
            if code(c) != 0x00; tot += 1; (V4S <= k <= V4E) && (v4 += 1); end
        end
        (tot >= 1200 && v4 >= FRAG) && push!(eligible, idx)
    end
end
chosen = sort(shuffle(rng, eligible)[1:N]); cs = Set(chosen)
names = String[]; rows = Vector{Vector{UInt8}}(); idx = 0; orig = String[]
open(path) do io
    while !eof(io)
        h = readline(io); s = readline(io); global idx += 1
        if idx in cs; push!(orig, h[2:end]); push!(rows, UInt8[code(c) for c in codeunits(s)]); end
    end
end
# shuffle order so names s001.. are not in file order
perm = shuffle(rng, 1:N); orig = orig[perm]; rows = rows[perm]
names = ["s" * lpad(i, 3, '0') for i in 1:N]
L = length(rows[1]); keep = [k for k in 1:L if count(r -> r[k] != 0x00, rows) >= 2]
v4cols = [j for (j, k) in enumerate(keep) if V4S <= k <= V4E]
A = zeros(UInt8, N, length(keep)); for i in 1:N, (j, k) in enumerate(keep); A[i, j] = rows[i][k]; end
# Fail loudly: eligibility was tested on whole rows, but dropping columns that are filled in fewer
# than two chosen rows can take a V4 base away.  03_prep.jl needs FRAG V4 bases in every row.
for i in 1:N
    nv4 = count(j -> A[i, j] != 0x00, v4cols)
    nv4 >= FRAG || error("selected row $(names[i]) ($(orig[i])) has only $nv4 V4 bases after column filtering, need $FRAG; no output written")
end
ch = ['-', 'A', 'C', 'G', 'T']
mkpath(out)
open(joinpath(out, "ref_full.fasta"), "w") do io
    for i in 1:N; println(io, ">", names[i]); println(io, String([ch[A[i, j] + 1] for j in 1:size(A, 2)])); end
end
open(joinpath(out, "names.tsv"), "w") do io; for i in 1:N; println(io, names[i], "\t", orig[i]); end; end
open(joinpath(out, "v4cols.txt"), "w") do io; println(io, join(v4cols, ",")); end
println("eligible=$(length(eligible)) N=$N kept_columns=$(size(A,2)) v4_columns=$(length(v4cols)) seed=$seed")
