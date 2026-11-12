# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Publish distinct native-calibration failure notes as Actions warnings.
#
# Usage: julia --startup-file=no report_failures.jl CELL < RESULTS.csv
# Standard library only. The CSV reader follows the rules of the Python csv module
# (default dialect) that this replaces: quoted fields may hold commas, quotes
# and line breaks, a quote inside an unquoted field is literal, and blank lines
# are skipped.

const RESULT_FIELDS = [
    "truth", "shape", "offset", "n_per", "taxa", "sim", "taxon",
    "true_log2fc", "test", "status", "pvalue", "note",
]
const LEGACY_FIELDS = RESULT_FIELDS[1:end-1]
const CELL_LABEL = r"^[A-Za-z0-9][A-Za-z0-9_.-]*$"

# Escape data characters reserved by the GitHub Actions command protocol.
escape_annotation(text::AbstractString) =
    replace(text, "%" => "%25", "\r" => "%0D", "\n" => "%0A")

# Keep untrusted cell labels from injecting extra Actions commands. The label
# is matched as a whole: a trailing newline must not slip past an end anchor.
function validate_cell_label(cell::AbstractString)
    (occursin(CELL_LABEL, cell) && !endswith(cell, "\n")) ||
        throw(ArgumentError("unsafe cell label for Actions annotation"))
    String(cell)
end

"""
    parse_csv(text) -> Vector{Vector{String}}

Split `text` into records of fields. Blank records come back as empty vectors.
"""
function parse_csv(text::AbstractString)
    records = Vector{Vector{String}}()
    fields = String[]
    field = IOBuffer()
    # :start_record, :start_field, :in_field, :in_quoted, :quote_in_quoted, :eat_newlines
    state = :start_record
    finish_field!() = (push!(fields, String(take!(field))); nothing)
    finish_record!() = (push!(records, fields); fields = String[]; nothing)
    for c in text
        if state === :eat_newlines
            (c == '\n' || c == '\r') && continue
            state = :start_record
        end
        if state === :start_record
            if c == '\n' || c == '\r'
                finish_record!()          # a blank line: an empty record
                state = :eat_newlines
                continue
            end
            state = :start_field
        end
        if state === :start_field
            if c == '\n' || c == '\r'
                finish_field!(); finish_record!(); state = :eat_newlines
            elseif c == '"'
                state = :in_quoted
            elseif c == ','
                finish_field!()
            else
                write(field, c); state = :in_field
            end
        elseif state === :in_field
            if c == '\n' || c == '\r'
                finish_field!(); finish_record!(); state = :eat_newlines
            elseif c == ','
                finish_field!(); state = :start_field
            else
                write(field, c)
            end
        elseif state === :in_quoted
            if c == '"'
                state = :quote_in_quoted
            else
                write(field, c)
            end
        elseif state === :quote_in_quoted
            if c == '"'
                write(field, '"'); state = :in_quoted
            elseif c == ','
                finish_field!(); state = :start_field
            elseif c == '\n' || c == '\r'
                finish_field!(); finish_record!(); state = :eat_newlines
            else
                write(field, c); state = :in_field   # lenient, as Python's default
            end
        end
    end
    # End of input: a field still open is closed, as the Python reader does.
    if state === :in_field || state === :in_quoted || state === :quote_in_quoted
        finish_field!(); finish_record!()
    elseif state === :start_field
        finish_field!(); finish_record!()
    end
    records
end

# Python's repr of a list of strings, as the header error message showed it.
function py_repr(values)
    quote_one(s) = begin
        q = occursin('\'', s) && !occursin('"', s) ? '"' : '\''
        body = replace(s, "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")
        q == '\'' && (body = replace(body, "'" => "\\'"))
        string(q, body, q)
    end
    "[" * join(quote_one.(values), ", ") * "]"
end

"""
    failure_annotations(io, cell) -> Vector{String}

Warnings for each distinct non-empty (test, failure-note) pair of the failed rows.
"""
function failure_annotations(io::IO, cell::AbstractString)
    cell = validate_cell_label(cell)
    text = read(io, String)
    isvalid(text) || throw(ArgumentError("input is not valid UTF-8"))
    records = parse_csv(text)
    annotations = String[]
    # The header is the very first record, blank or not, as with Python's DictReader.
    isempty(records) && throw(ArgumentError("unexpected CSV header None"))
    header = records[1]
    header == RESULT_FIELDS || header == LEGACY_FIELDS ||
        throw(ArgumentError("unexpected CSV header $(py_repr(header))"))
    seen = Set{Tuple{String,String}}()
    for (offset, row) in enumerate(filter(!isempty, records[2:end]))
        record_number = offset + 1   # the header is record 1; the first data record is 2
        length(row) == length(header) ||
            throw(ArgumentError("malformed CSV record $record_number"))
        values = Dict(zip(header, row))
        get(values, "status", nothing) == "failed" || continue
        note = get(values, "note", nothing)
        (note === nothing || isempty(note) || note == "NA") && continue
        key = (get(values, "test", ""), note)
        key in seen && continue
        push!(seen, key)
        message = escape_annotation("$(key[1]) :: $(key[2])")
        push!(annotations, "::warning title=$(cell): a requested test failed::$(message)")
    end
    annotations
end

function main(args = ARGS)
    if length(args) != 1
        println(stderr, "usage: ", basename(PROGRAM_FILE), " CELL < RESULTS.csv")
        return 2
    end
    cell = args[1]
    try
        for annotation in failure_annotations(stdin, cell)
            println(annotation)
        end
    catch err
        err isa ArgumentError && (println(stderr, cell, ": ", err.msg); return 2)
        err isa Union{SystemError,Base.IOError} && (println(stderr, cell, ": ", sprint(showerror, err)); return 2)
        rethrow()
    end
    0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
