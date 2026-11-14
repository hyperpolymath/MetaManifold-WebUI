# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: MPL-2.0

# Generates the R reference for the native ALDEx2 comparison test
# (test/unit/test_differential_native_reference.jl) by calling the Bioconductor
# ALDEx2 package directly, once for each committed count table. Next to each
# counts file it writes:
#
#   counts.tsv        -> reference_aldex2.tsv       + reference_meta.json
#   counts_zeros.tsv  -> reference_aldex2_zeros.tsv + reference_meta_zeros.json
#
# The reference .tsv has one row per taxon: ALDEx2's columns for the primary seed,
# and the same columns for each spread seed. The metadata records what produced
# them: R, ALDEx2 and Bioconductor versions, settings, seeds, the counts file's
# SHA-256, and the largest seed-to-seed difference per column.
#
# Run from the repository root, in a session with R, the Bioconductor ALDEx2
# package and BiocManager installed (nothing here installs them):
#
#   julia --project=. test/fixtures/native_da/generate_reference.jl
#
# Nothing is written unless every step succeeds, and a missing package is an
# error, never a default. The values are R's own output; this script computes
# nothing of its own beyond the seed-to-seed differences recorded in the
# metadata. Commit the files together, then run the test.

using CSV, DataFrames, JSON3, RCall, SHA

const DIR = @__DIR__
# (counts file, reference table, metadata) per table.
const TABLES = (("counts.tsv", "reference_aldex2.tsv", "reference_meta.json"),
                ("counts_zeros.tsv", "reference_aldex2_zeros.tsv", "reference_meta_zeros.json"))
const MC_SAMPLES = 512
const PRIMARY_SEED = 1
const SPREAD_SEEDS = Tuple(2:20)
# ALDEx2's own column names, and the names this repository uses for them.
const COLUMNS = ("we.ep" => "pvalue", "we.eBH" => "qvalue", "wi.ep" => "wi_pvalue",
                 "wi.eBH" => "wi_qvalue", "effect" => "effect", "diff.btw" => "diff_btw",
                 "diff.win" => "diff_win", "rab.all" => "rab_all")

for pkg in ("ALDEx2", "BiocManager")
    rcopy(Bool, R"requireNamespace($pkg, quietly = TRUE)") ||
        error("the R package $pkg is not installed; install it with " *
              "BiocManager::install(\"ALDEx2\") and rerun")
end

function run_aldex(reads, taxa, conds, seed)
    @rput reads taxa conds seed
    R"""
    set.seed(seed)
    rownames(reads) <- taxa
    colnames(reads) <- paste0("s", seq_len(ncol(reads)))
    res <- ALDEx2::aldex(reads, conds, mc.samples = $MC_SAMPLES, test = "t",
                         effect = TRUE, denom = "all", verbose = FALSE)
    res <- res[taxa, ]
    """
    res = rcopy(R"res")
    out = DataFrame(taxon = taxa)
    for (r_name, name) in COLUMNS
        out[!, name] = Float64.(res[:, Symbol(replace(r_name, "." => "_"))])
    end
    out
end

# Everything is computed for every table before anything is written.
outputs = Pair{String,Any}[]
for (counts_file, reference_file, meta_file) in TABLES
    counts_path = joinpath(DIR, counts_file)
    table = CSV.read(counts_path, DataFrame; delim = '\t')
    taxa = names(table)[3:end]
    reads = permutedims(Matrix{Float64}(table[:, 3:end]))  # taxa x samples, as ALDEx2 expects
    conds = String.(table.group)
    all(isinteger, reads) || error("$counts_file holds non-integer counts")

    # ALDEx2 puts the second sorted condition against the first: "treated" against
    # "control". The native adapter is called with reference "control", contrast
    # "treated" in the test, which is the same direction.
    runs = Dict(seed => run_aldex(reads, taxa, conds, seed)
                for seed in (PRIMARY_SEED, SPREAD_SEEDS...))

    versions = (r = rcopy(String, R"R.version.string"),
                aldex2 = rcopy(String, R"as.character(packageVersion('ALDEx2'))"),
                bioconductor = rcopy(String, R"as.character(BiocManager::version())"))

    spread = Dict(name => maximum(maximum(abs.(runs[s][!, name] .- runs[PRIMARY_SEED][!, name]))
                                  for s in SPREAD_SEEDS) for (_, name) in COLUMNS)

    reference = DataFrame(taxon = taxa)
    for (_, name) in COLUMNS
        reference[!, name] = runs[PRIMARY_SEED][!, name]
    end
    for s in SPREAD_SEEDS, (_, name) in COLUMNS
        reference[!, "$(name)_seed$s"] = runs[s][!, name]
    end

    meta = (generated_by = "test/fixtures/native_da/generate_reference.jl",
            counts_file = counts_file,
            versions = versions,
            julia = string(VERSION),
            call = "ALDEx2::aldex(reads, conds, mc.samples = $MC_SAMPLES, test = \"t\", effect = TRUE, denom = \"all\")",
            mc_samples = MC_SAMPLES, primary_seed = PRIMARY_SEED, spread_seeds = collect(SPREAD_SEEDS),
            contrast = "treated vs control",
            counts_sha256 = bytes2hex(open(sha256, counts_path)),
            max_seed_to_seed_difference = spread)
    push!(outputs, reference_file => reference, meta_file => meta)
end

for (file, content) in outputs
    path = joinpath(DIR, file)
    if content isa DataFrame
        CSV.write(path, content; delim = '\t')
    else
        open(path, "w") do io
            JSON3.pretty(io, content)
            println(io)
        end
    end
end
println("wrote ", join(first.(outputs), ", "))
