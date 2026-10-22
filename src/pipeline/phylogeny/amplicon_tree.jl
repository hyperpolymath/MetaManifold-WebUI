# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

using Random
import ..Provenance

const DEFAULT_MAX_ASVS = 500
const SHORT_AMPLICON_BP_WARN = 600

struct AmpliconPhylogenyResult
    newick                 :: String
    method                 :: String
    aligner                :: String
    total_input_asvs       :: Int
    retained_asvs          :: Int
    excluded_asvs          :: Int
    retained_read_fraction :: Float64
    alignment_length       :: Int
    median_raw_length      :: Float64
    subsampled             :: Bool
    warnings               :: Vector{String}
    tool_records           :: Vector{OrderedDict{String,Any}}
end

function _resolve_executable(tool_key::AbstractString, fallbacks::Vector{String})::Union{String,Nothing}
    configured = tool_bin(tool_key)
    for cand in vcat([configured], fallbacks)
        isempty(cand) && continue
        if isfile(cand)
            return abspath(cand)
        end
        found = Sys.which(cand)
        found !== nothing && return found
    end
    return nothing
end

function _probe_record_dict(tool_key::AbstractString, resolved_path::AbstractString)::OrderedDict{String,Any}
    if haskey(Provenance.TOOL_PROBES, tool_key)
        try
            rec = Provenance.probe_tool(Provenance.TOOL_PROBES[tool_key]; bin_resolver = _ -> resolved_path)
            return OrderedDict{String,Any}(
                "name"      => rec.name,
                "version"   => rec.version,
                "path"      => rec.path,
                "sha256"    => rec.sha256,
                "probed_by" => rec.probed_by,
            )
        catch err
            return OrderedDict{String,Any}(
                "name"      => String(tool_key),
                "version"   => "unprobed ($(sprint(showerror, err)))",
                "path"      => String(resolved_path),
                "sha256"    => isfile(resolved_path) ? bytes2hex(open(sha256, resolved_path)) : "",
                "probed_by" => "fallback-sha256",
            )
        end
    end
    OrderedDict{String,Any}(
        "name"      => String(tool_key),
        "version"   => "builtin",
        "path"      => String(resolved_path),
        "sha256"    => isfile(resolved_path) ? bytes2hex(open(sha256, resolved_path)) : "",
        "probed_by" => "builtin",
    )
end

function _sanitize_dna(seq::AbstractString)::String
    uppercase(replace(seq, r"[^ACGTURYKMSWBDHVN-]"i => ""))
end

"""
    select_asv_subset(sequences; abundances, max_asvs=500, selection=:top_abundance, seed=42)

Bound the ASV set prior to quadratic O(n^2) distance/alignment and tree inference.
Returns `(retained_pairs, retained_read_fraction, subsampled)`.
"""
function select_asv_subset(
    sequences::AbstractVector{<:Pair{<:AbstractString,<:AbstractString}};
    abundances::AbstractDict = Dict{String,Float64}(),
    max_asvs::Int = DEFAULT_MAX_ASVS,
    selection::Symbol = :top_abundance,
    seed::Int = 42,
)
    max_asvs >= 1 || throw(ArgumentError("max_asvs must be >= 1, got $max_asvs"))
    seen = Set{String}()
    cleaned = Pair{String,String}[]
    for (id_raw, seq_raw) in sequences
        id = String(id_raw)
        id in seen && continue
        s = _sanitize_dna(seq_raw)
        isempty(s) && continue
        push!(seen, id)
        push!(cleaned, id => s)
    end

    total_reads = sum((Float64(get(abundances, id, 1.0)) for (id, _) in cleaned); init = 0.0)
    if length(cleaned) <= max_asvs
        return (cleaned, 1.0, false)
    end

    selected = if selection === :subsample
        rng = MersenneTwister(seed)
        perm = randperm(rng, length(cleaned))[1:max_asvs]
        sort!(perm)
        cleaned[perm]
    else
        # Deterministic top-N by read abundance, breaking ties lexicographically by ID.
        ordered = sort(
            cleaned;
            by = p -> (-Float64(get(abundances, p.first, 0.0)), p.first),
        )
        ordered[1:max_asvs]
    end

    kept_reads = sum((Float64(get(abundances, id, 1.0)) for (id, _) in selected); init = 0.0)
    frac = total_reads > 0.0 ? clamp(kept_reads / total_reads, 0.0, 1.0) : 1.0
    return (selected, frac, true)
end

## Pure-Julia progressive Needleman-Wunsch center-star alignment fallback
function _nw_pairwise(ref::Vector{UInt8}, qry::Vector{UInt8})::Tuple{Vector{UInt8},Vector{UInt8}}
    m = length(ref)
    n = length(qry)
    score = Matrix{Int32}(undef, m + 1, n + 1)
    trace = Matrix{UInt8}(undef, m + 1, n + 1) # 1 = diag, 2 = up (gap in qry), 3 = left (gap in ref)
    gap = Int32(-2)
    score[1, 1] = Int32(0)
    trace[1, 1] = 0x00
    for i in 1:m
        score[i + 1, 1] = Int32(-2 * i)
        trace[i + 1, 1] = 0x02
    end
    for j in 1:n
        score[1, j + 1] = Int32(-2 * j)
        trace[1, j + 1] = 0x03
    end
    for j in 1:n
        qj = qry[j]
        for i in 1:m
            ri = ref[i]
            sub = (ri == qj && ri != UInt8('-')) ? Int32(2) : Int32(-1)
            d = score[i, j] + sub
            u = score[i, j + 1] + gap
            l = score[i + 1, j] + gap
            if d >= u && d >= l
                score[i + 1, j + 1] = d
                trace[i + 1, j + 1] = 0x01
            elseif u >= l
                score[i + 1, j + 1] = u
                trace[i + 1, j + 1] = 0x02
            else
                score[i + 1, j + 1] = l
                trace[i + 1, j + 1] = 0x03
            end
        end
    end
    ar = UInt8[]
    aq = UInt8[]
    i = m + 1
    j = n + 1
    while i > 1 || j > 1
        t = trace[i, j]
        if t == 0x01
            push!(ar, ref[i - 1])
            push!(aq, qry[j - 1])
            i -= 1
            j -= 1
        elseif t == 0x02
            push!(ar, ref[i - 1])
            push!(aq, UInt8('-'))
            i -= 1
        else
            push!(ar, UInt8('-'))
            push!(aq, qry[j - 1])
            j -= 1
        end
    end
    reverse!(ar)
    reverse!(aq)
    return (ar, aq)
end

function _builtin_align(seqs::Vector{Pair{String,String}})::Vector{Pair{String,String}}
    isempty(seqs) && return Pair{String,String}[]
    lengths = [ncodeunits(s) for (_, s) in seqs]
    if minimum(lengths) == maximum(lengths)
        return seqs
    end
    # Progressive center-star MSA anchored at the first (highest-abundance) sequence.
    master = Vector{UInt8}(codeunits(seqs[1].second))
    rows = Vector{Vector{UInt8}}(undef, length(seqs))
    rows[1] = copy(master)
    for k in 2:length(seqs)
        ar, aq = _nw_pairwise(master, Vector{UInt8}(codeunits(seqs[k].second)))
        if length(ar) > length(master)
            # Propagate newly inserted master gaps into earlier aligned rows.
            old_len = length(master)
            for prev in 1:(k - 1)
                expanded = Vector{UInt8}(undef, length(ar))
                old_idx = 1
                for col in eachindex(ar)
                    if old_idx <= old_len && ar[col] == master[old_idx]
                        expanded[col] = rows[prev][old_idx]
                        old_idx += 1
                    else
                        expanded[col] = UInt8('-')
                    end
                end
                rows[prev] = expanded
            end
            master = ar
        end
        rows[k] = aq
    end
    [seqs[i].first => String(rows[i]) for i in eachindex(seqs)]
end

## Pure-Julia Jukes-Cantor + Saitou-Nei Neighbor-Joining with column bootstrap
function _jc69_distance_matrix(
    aln_bytes::Vector{Vector{UInt8}},
    cols::AbstractVector{Int},
)::Matrix{Float64}
    n = length(aln_bytes)
    D = zeros(Float64, n, n)
    gap = UInt8('-')
    ambig = UInt8('N')
    for i in 1:(n - 1)
        si = aln_bytes[i]
        for j in (i + 1):n
            sj = aln_bytes[j]
            compared = 0
            diffs = 0
            @inbounds for c in cols
                bi = si[c]
                bj = sj[c]
                (bi == gap || bj == gap || bi == ambig || bj == ambig) && continue
                compared += 1
                bi != bj && (diffs += 1)
            end
            d = if compared == 0
                0.5
            else
                p = diffs / compared
                p >= 0.74 ? 3.0 : max(0.0, -0.75 * log(1.0 - (4.0 / 3.0) * p))
            end
            D[i, j] = d
            D[j, i] = d
        end
    end
    D
end

mutable struct _NJNode
    id       :: Int
    label    :: String
    children :: Vector{Tuple{_NJNode,Float64}}
    tips     :: BitSet
end

function _neighbor_joining_tree(labels::Vector{String}, D_in::Matrix{Float64})::_NJNode
    n = length(labels)
    n == 1 && return _NJNode(1, labels[1], Tuple{_NJNode,Float64}[], BitSet([1]))
    if n == 2
        half = max(0.0, 0.5 * D_in[1, 2])
        c1 = _NJNode(1, labels[1], Tuple{_NJNode,Float64}[], BitSet([1]))
        c2 = _NJNode(2, labels[2], Tuple{_NJNode,Float64}[], BitSet([2]))
        return _NJNode(3, "", [(c1, half), (c2, half)], BitSet([1, 2]))
    end

    active = collect(1:n)
    nodes = [_NJNode(i, labels[i], Tuple{_NJNode,Float64}[], BitSet([i])) for i in 1:n]
    dist = copy(D_in)
    next_id = n + 1

    while length(active) > 3
        m = length(active)
        row_sums = zeros(Float64, m)
        for a in 1:m
            s = 0.0
            for b in 1:m
                a == b && continue
                s += dist[active[a], active[b]]
            end
            row_sums[a] = s
        end

        best_q = Inf
        best_a = 1
        best_b = 2
        for a in 1:(m - 1)
            for b in (a + 1):m
                q = (m - 2) * dist[active[a], active[b]] - row_sums[a] - row_sums[b]
                if q < best_q
                    best_q = q
                    best_a = a
                    best_b = b
                end
            end
        end

        ia = active[best_a]
        ib = active[best_b]
        dab = dist[ia, ib]
        delta = (row_sums[best_a] - row_sums[best_b]) / (2.0 * (m - 2))
        la = max(0.0, 0.5 * dab + delta)
        lb = max(0.0, dab - la)

        merged_tips = union(nodes[ia].tips, nodes[ib].tips)
        u_node = _NJNode(next_id, "", [(nodes[ia], la), (nodes[ib], lb)], merged_tips)
        next_id += 1

        # Expand distance matrix by one row/column for the merged cluster.
        old_sz = size(dist, 1)
        new_dist = zeros(Float64, old_sz + 1, old_sz + 1)
        new_dist[1:old_sz, 1:old_sz] = dist
        push!(nodes, u_node)
        iu = old_sz + 1
        for k_idx in 1:m
            ik = active[k_idx]
            (ik == ia || ik == ib) && continue
            duk = max(0.0, 0.5 * (dist[ia, ik] + dist[ib, ik] - dab))
            new_dist[iu, ik] = duk
            new_dist[ik, iu] = duk
        end
        dist = new_dist
        deleteat!(active, best_b)
        active[best_a] = iu
    end

    # Join the final 3 clusters at an unrooted trifurcation.
    i1, i2, i3 = active[1], active[2], active[3]
    l1 = max(0.0, 0.5 * (dist[i1, i2] + dist[i1, i3] - dist[i2, i3]))
    l2 = max(0.0, 0.5 * (dist[i1, i2] + dist[i2, i3] - dist[i1, i3]))
    l3 = max(0.0, 0.5 * (dist[i1, i3] + dist[i2, i3] - dist[i1, i2]))
    all_tips = union(nodes[i1].tips, nodes[i2].tips, nodes[i3].tips)
    _NJNode(next_id, "", [(nodes[i1], l1), (nodes[i2], l2), (nodes[i3], l3)], all_tips)
end

function _canon_split(tips::BitSet, n_tips::Int)::BitSet
    # Canonical bipartition identifies the side NOT containing tip 1 (or the smaller side).
    1 in tips || return copy(tips)
    comp = BitSet()
    for i in 1:n_tips
        i in tips || push!(comp, i)
    end
    comp
end

function _collect_internal_splits!(out::Vector{BitSet}, node::_NJNode, n_tips::Int, is_root::Bool)
    if !is_root && !isempty(node.children)
        sp = _canon_split(node.tips, n_tips)
        if 1 < length(sp) < n_tips - 1
            push!(out, sp)
        end
    end
    for (ch, _) in node.children
        _collect_internal_splits!(out, ch, n_tips, false)
    end
end

function _quote_newick_label(s::AbstractString)::String
    if occursin(r"^[A-Za-z0-9_.\-]+$", s)
        return String(s)
    end
    "'" * replace(s, "'" => "''") * "'"
end

function _emit_nj_newick(
    node::_NJNode,
    n_tips::Int,
    split_support::Dict{BitSet,Float64},
    is_root::Bool,
)::String
    if isempty(node.children)
        return _quote_newick_label(node.label)
    end
    parts = String[]
    for (ch, len) in node.children
        sub = _emit_nj_newick(ch, n_tips, split_support, false)
        push!(parts, string(sub, ":", repr(round(len; digits=9))))
    end
    sup_str = if !is_root
        sp = _canon_split(node.tips, n_tips)
        haskey(split_support, sp) ? repr(round(split_support[sp]; digits=3)) : ""
    else
        ""
    end
    string("(", join(parts, ","), ")", sup_str)
end

function _infer_nj_newick(
    aligned::Vector{Pair{String,String}};
    n_boot::Int = 100,
    seed::Int = 42,
)::String
    labels = [p.first for p in aligned]
    aln_bytes = [Vector{UInt8}(codeunits(p.second)) for p in aligned]
    L = isempty(aln_bytes) ? 0 : length(aln_bytes[1])
    D = _jc69_distance_matrix(aln_bytes, 1:L)
    tree = _neighbor_joining_tree(labels, D)
    n_tips = length(labels)
    support_counts = Dict{BitSet,Int}()
    if n_tips >= 4 && L > 0 && n_boot > 0
        rng = MersenneTwister(seed)
        cols = Vector{Int}(undef, L)
        splits_buf = BitSet[]
        for _ in 1:n_boot
            for c in 1:L
                cols[c] = rand(rng, 1:L)
            end
            Db = _jc69_distance_matrix(aln_bytes, cols)
            tb = _neighbor_joining_tree(labels, Db)
            empty!(splits_buf)
            _collect_internal_splits!(splits_buf, tb, n_tips, true)
            for sp in splits_buf
                support_counts[sp] = get(support_counts, sp, 0) + 1
            end
        end
    end
    split_support = Dict{BitSet,Float64}(
        sp => cnt / max(1, n_boot) for (sp, cnt) in support_counts
    )
    _emit_nj_newick(tree, n_tips, split_support, true) * ";"
end

function _median_float(vals::Vector{Int})::Float64
    isempty(vals) && return 0.0
    s = sort(vals)
    n = length(s)
    mid = fld(n, 2)
    isodd(n) ? Float64(s[mid + 1]) : 0.5 * (s[mid] + s[mid + 1])
end

"""
    build_amplicon_phylogeny(sequences; abundances, method=:auto, max_asvs=500, selection=:top_abundance, seed=42, threads=1, n_boot=100)

Align short amplicon ASV sequences and infer a phylogenetic Newick tree with
branch lengths, support values, subsampling safeguards, tool provenance records,
and explicit short-amplicon scientific warnings.
"""
function build_amplicon_phylogeny(
    sequences::AbstractVector{<:Pair{<:AbstractString,<:AbstractString}};
    abundances::AbstractDict = Dict{String,Float64}(),
    method::Symbol = :auto,
    max_asvs::Int = DEFAULT_MAX_ASVS,
    selection::Symbol = :top_abundance,
    seed::Int = 42,
    threads::Int = 1,
    n_boot::Int = 100,
)::AmpliconPhylogenyResult
    method in (:auto, :fasttree, :iqtree, :nj) ||
        throw(ArgumentError("Unsupported tree builder method: $(repr(method))"))

    total_n = length(sequences)
    retained, retained_frac, subsampled = select_asv_subset(
        sequences;
        abundances = abundances,
        max_asvs = max_asvs,
        selection = selection,
        seed = seed,
    )
    isempty(retained) && throw(ArgumentError("Cannot build phylogeny from 0 valid DNA sequences"))

    warnings = String[]
    tool_records = OrderedDict{String,Any}[]

    raw_lengths = [ncodeunits(s) for (_, s) in retained]
    med_len = _median_float(raw_lengths)
    if med_len < SHORT_AMPLICON_BP_WARN
        push!(warnings,
            "Short amplicon sequences (median $(round(Int, med_len)) bp) carry limited deep-branch " *
            "phylogenetic signal; treat deep internal splits as approximate hypotheses rather than " *
            "true evolutionary history.")
    end
    if subsampled
        push!(warnings,
            "Input ASV count ($total_n) exceeded max_asvs ($max_asvs); retained $(length(retained)) " *
            "ASVs covering $(round(retained_frac * 100; digits=2))% of reads.")
    end

    # Remap arbitrary sequence headers (including vsearch/swarm semicolons) onto safe tokens.
    token_to_id = Dict{String,String}()
    tokenized = Pair{String,String}[]
    for (idx, (orig_id, seq)) in enumerate(retained)
        tok = string("MMTIP_", lpad(idx, 6, '0'))
        token_to_id[tok] = orig_id
        push!(tokenized, tok => seq)
    end

    mafft_path = _resolve_executable("mafft", ["mafft"])
    aligned_tokens = Pair{String,String}[]
    aligner_used = "builtin-nw"
    mktempdir() do workdir
        raw_fa = joinpath(workdir, "input.fasta")
        write_fasta(raw_fa, tokenized)
        aln_fa = joinpath(workdir, "aligned.fasta")

        if mafft_path !== nothing
            out_buf = IOBuffer()
            err_buf = IOBuffer()
            proc = run(pipeline(ignorestatus(Cmd([
                mafft_path, "--auto", "--quiet", "--thread", string(max(1, threads)), raw_fa
            ])); stdout = out_buf, stderr = err_buf))
            if proc.exitcode == 0
                write(aln_fa, take!(out_buf))
                aligned_tokens = [String(k) => uppercase(String(v)) for (k, v) in parse_fasta(read(aln_fa, String))]
                aligner_used = "mafft"
                push!(tool_records, _probe_record_dict("mafft", mafft_path))
            end
        end

        if isempty(aligned_tokens)
            aligned_tokens = _builtin_align(tokenized)
            write_fasta(aln_fa, aligned_tokens)
            push!(warnings,
                "External aligner mafft was not configured; aligned $(length(aligned_tokens)) amplicon " *
                "sequences with the built-in progressive Needleman-Wunsch aligner.")
        end

        aln_len = isempty(aligned_tokens) ? 0 : ncodeunits(aligned_tokens[1].second)

        chosen = method
        ft_path = _resolve_executable("fasttree", ["FastTree", "fasttree"])
        iq_path = _resolve_executable("iqtree", ["iqtree3", "iqtree"])
        if chosen === :auto
            chosen = ft_path !== nothing ? :fasttree :
                     (iq_path !== nothing ? :iqtree : :nj)
        end

        raw_newick = ""
        method_used = ""

        if length(aligned_tokens) < 3
            raw_newick = _infer_nj_newick(aligned_tokens; n_boot = 0, seed = seed)
            method_used = "exact_small_tree"
        elseif chosen === :fasttree
            ft_path === nothing &&
                error("FastTree binary not found; install via install.jl or select method=:nj")
            out_tree = joinpath(workdir, "fasttree.nwk")
            err_buf = IOBuffer()
            cmd = addenv(
                Cmd([ft_path, "-nt", "-gtr", "-gamma", "-seed", string(seed), "-quiet", "-out", out_tree, aln_fa]),
                "OMP_NUM_THREADS" => string(max(1, threads)),
            )
            proc = run(pipeline(ignorestatus(cmd); stderr = err_buf))
            proc.exitcode == 0 && isfile(out_tree) ||
                error("FastTree exited with code $(proc.exitcode): $(String(take!(err_buf)))")
            raw_newick = strip(read(out_tree, String))
            method_used = "fasttree"
            push!(tool_records, _probe_record_dict("fasttree", ft_path))
            push!(warnings,
                "FastTree infers approximate maximum-likelihood topologies with SH-like local supports; " *
                "treat borderline internal branches with caution.")
        elseif chosen === :iqtree
            iq_path === nothing &&
                error("IQ-TREE binary not found; install via install.jl or select method=:nj")
            prefix = joinpath(workdir, "iq")
            args = [iq_path, "-s", aln_fa, "-m", "GTR+G", "-T", string(max(1, threads)),
                    "--seed", string(seed), "--prefix", prefix, "-redo"]
            length(aligned_tokens) >= 4 && append!(args, ["-B", "1000"])
            err_buf = IOBuffer()
            proc = run(pipeline(ignorestatus(Cmd(args)); stdout = devnull, stderr = err_buf))
            treefile = prefix * ".treefile"
            proc.exitcode == 0 && isfile(treefile) ||
                error("IQ-TREE exited with code $(proc.exitcode): $(String(take!(err_buf)))")
            raw_newick = strip(read(treefile, String))
            method_used = "iqtree"
            push!(tool_records, _probe_record_dict("iqtree", iq_path))
        else
            raw_newick = _infer_nj_newick(aligned_tokens; n_boot = n_boot, seed = seed)
            method_used = "nj_jc69"
            if method === :auto
                push!(warnings,
                    "External tree builders (FastTree, IQ-TREE) were not configured; built JC69 " *
                    "Neighbor-Joining phylogeny with $n_boot bootstrap replicates.")
            end
        end

        # Substitute clean internal tokens back to exact Newick-escaped ASV identifiers.
        restored_newick = replace(raw_newick, r"MMTIP_\d{6}" => tok -> _quote_newick_label(token_to_id[String(tok)]))

        return AmpliconPhylogenyResult(
            restored_newick,
            method_used,
            aligner_used,
            total_n,
            length(retained),
            total_n - length(retained),
            retained_frac,
            aln_len,
            med_len,
            subsampled,
            warnings,
            tool_records,
        )
    end
end
