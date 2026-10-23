# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Server-rendered, JavaScript-free surface for the validated statistics layer.
# The page is deliberately Julia-owned: there is no new application TypeScript,
# no client-side analysis logic, and no inline script. The form posts standard
# URL-encoded data and Julia renders an accessible result and provenance block.
#
# This is not a replacement for the React application; it is the validated
# statistics surface, linked from the documentation.

using ..MethodCatalogue
using ..NumericPolicy
using ..ExactSummaries
using ..HighPrecision
using ..DerivedAnalyses

const _STATISTICS_UI_TABLE_CELLS = 20_000
const _STATISTICS_UI_TITLE = "Validated statistics"

# `string`, not `String`: the storage dictionaries carry integers as JSON
# numbers, and `String(::Int)` is a MethodError. Every value that reaches the
# page is rendered, so accepting any printable value here is the contract.
function _html_escape(value)
    replace(string(value),
        '&' => "&amp;", '<' => "&lt;", '>' => "&gt;",
        '"' => "&quot;", '\'' => "&#39;")
end

_html(value) = _html_escape(value)

function _html_params(params, key::String, default::String="")
    _html_escape(get(params, key, default))
end

function _selected(params, key::String, value::String)
    get(params, key, "") == value ? " selected" : ""
end

function _checked(params, key::String)
    get(params, key, "") in ("on", "true", "1") ? " checked" : ""
end

function _form_int(params, key::String, default::Int; minimum::Int, maximum::Int)
    text = strip(get(params, key, string(default)))
    isempty(text) && return default
    value = tryparse(Int, text)
    isnothing(value) && throw(ArgumentError("$key must be an integer, got '$text'"))
    minimum <= value <= maximum || throw(ArgumentError(
        "$key must be in $minimum:$maximum, got $value"))
    value
end

function _split_labels(text::AbstractString)
    parts = split(replace(String(text), '\r' => ""), r"[\n,;]+"; keepempty=false)
    labels = String[strip(part) for part in parts if !isempty(strip(part))]
    isempty(labels) && throw(ArgumentError("at least one label is required"))
    labels
end

function _parse_counts_text(text::AbstractString, n_features::Int, n_samples::Int)
    lines = String[]
    for line in split(replace(String(text), '\r' => ""), '\n')
        stripped = strip(line)
        isempty(stripped) || push!(lines, String(stripped))
    end
    length(lines) == n_features || throw(ArgumentError(
        "counts has $(length(lines)) non-empty rows; feature_labels has $n_features"))
    counts = Matrix{BigInt}(undef, n_features, n_samples)
    for (i, line) in enumerate(lines)
        cells = split(line, r"[\s,]+"; keepempty=false)
        length(cells) == n_samples || throw(ArgumentError(
            "counts row $i has $(length(cells)) cells; sample_labels has $n_samples"))
        for (j, cell) in enumerate(cells)
            counts[i, j] = BigInt(parse_exact_count(cell))
        end
    end
    counts
end

function _parse_statistics_form(req)
    body = req.body isa AbstractString ? String(req.body) : String(copy(req.body))
    ncodeunits(body) <= MAX_REQUEST_BYTES || throw(ResourceLimitError(
        "request bytes", MAX_REQUEST_BYTES, ncodeunits(body)))
    params = Dict{String,String}()
    for pair in split(body, '&'; keepempty=false)
        parts = split(pair, '='; limit=2)
        key = try
            String(HTTP.URIs.unescapeuri(replace(parts[1], '+' => "%20")))
        catch
            throw(ArgumentError("form body contains an invalid percent escape"))
        end
        value = length(parts) == 2 ? try
            String(HTTP.URIs.unescapeuri(replace(parts[2], '+' => "%20")))
        catch
            throw(ArgumentError("form body contains an invalid percent escape"))
        end : ""
        haskey(params, key) && throw(ArgumentError(
            "form body repeats the field '$key'"))
        params[key] = value
    end
    params
end

function _ui_policy(params)
    mode = get(params, "mode", "exact_counts")
    mode in ("exact_counts", "high_precision") || throw(ArgumentError(
        "mode must be exact_counts or high_precision; ordinary mode is not offered here"))
    precision = _form_int(params, "precision_bits", DEFAULT_HIGH_PRECISION_BITS;
        minimum=ORDINARY_PRECISION_BITS + 1, maximum=MAX_PRECISION_BITS)
    max_denominator = _form_int(params, "max_denominator_bits",
        DEFAULT_MAX_DENOMINATOR_BITS; minimum=32, maximum=MAX_DENOMINATOR_BITS)
    digits = _form_int(params, "round_digits", 6; minimum=0, maximum=MAX_ROUND_DIGITS)
    numeric_policy(; mode=Symbol(mode),
        precision_bits=mode == "high_precision" ? precision : nothing,
        max_denominator_bits=max_denominator, round_digits=digits)
end

function _ui_cancellation(params)
    text = strip(get(params, "time_limit_seconds", ""))
    isempty(text) && return nothing
    value = tryparse(Float64, text)
    isnothing(value) && throw(ArgumentError("time_limit_seconds must be a number"))
    CancellationToken(; deadline_seconds=value)
end

function _ui_inputs(params)
    labels = _split_labels(get(params, "sample_labels", ""))
    features = _split_labels(get(params, "feature_labels", ""))
    length(labels) * length(features) <= MAX_CELLS || throw(ResourceLimitError(
        "table cells", MAX_CELLS, length(labels) * length(features)))
    counts = _parse_counts_text(get(params, "counts", ""), length(features), length(labels))
    groups_text = strip(get(params, "groups", ""))
    groups = isempty(groups_text) ? nothing : _split_labels(groups_text)
    !isnothing(groups) && length(groups) != length(labels) && throw(ArgumentError(
        "groups has $(length(groups)) labels; sample_labels has $(length(labels))"))
    ExactSummaries.validate_coordinates(counts, labels, features)
    counts, labels, features, groups
end

function _ui_run(params)
    policy = _ui_policy(params)
    cancellation = _ui_cancellation(params)
    counts, labels, features, groups = _ui_inputs(params)
    result = _run_statistics(counts, labels, features, groups, policy; cancellation)
    if get(params, "persist", "") in ("on", "true", "1")
        source = _direct_source(result, labels, features, groups, counts)
        config = Dict{String,Any}(
            "numeric_policy" => policy_to_storage(policy),
            "source_format" => "direct-json-form",
            "form_fields" => Dict{String,Any}(
                "orientation" => "features_by_samples",
                "groups_supplied" => !isnothing(groups),
            ),
        )
        directory = joinpath(ServerState.projects_dir(), "_derived", "direct")
        saved = persist_derived_analysis(directory; source, config, result)
        result = copy(result)
        result["analysis_id"] = saved.id
        result["derived_analysis"] = Dict{String,Any}(
            "id" => saved.id, "created" => saved.created, "immutable" => true)
    end
    (; result, policy, counts, labels, features, groups)
end

function _ui_status(err)
    err isa OperationCancelledError && return 408
    err isa ResourceLimitError && return 413
    err isa UnsupportedRepresentationError && return 422
    err isa CountOverflowError && return 422
    err isa DerivedAnalysisError && return err.code == "conflict" ? 409 : 500
    err isa ArgumentError && return 400
    500
end

function _ui_message(err)
    err isa OperationCancelledError && return sprint(showerror, err)
    err isa ResourceLimitError && return sprint(showerror, err)
    err isa UnsupportedRepresentationError && return sprint(showerror, err)
    err isa CountOverflowError && return sprint(showerror, err)
    err isa DerivedAnalysisError && return err.reason
    err isa ArgumentError && return sprint(showerror, err)
    "The validated statistics request failed. No result is claimed."
end

function _statistics_html_response(html::AbstractString; status::Int=200)
    HTTP.Response(status, [
        "Content-Type" => "text/html; charset=utf-8",
        "Cache-Control" => "no-store",
        "X-Content-Type-Options" => "nosniff",
        "Referrer-Policy" => "no-referrer",
        "Content-Security-Policy" =>
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    ]; body=String(html))
end

function _ui_header(io, title)
    print(io, "<!doctype html>\n<html lang=\"en\">\n<head>\n",
        "<meta charset=\"utf-8\">\n",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
        "<title>", _html(title), " · MetaManifold</title>\n",
        "<style>\n",
        ":root{color-scheme:light dark;--fg:#111;--bg:#fff;--muted:#4b5563;--line:#d1d5db;--accent:#1d4ed8;--warn:#92400e;--warnbg:#fffbeb;--err:#991b1b;--errbg:#fef2f2;--ok:#166534;--okbg:#f0fdf4}",
        "@media (prefers-color-scheme:dark){:root{--fg:#e5e7eb;--bg:#111827;--muted:#9ca3af;--line:#374151;--accent:#93c5fd;--warn:#fcd34d;--warnbg:#451a03;--err:#fca5a5;--errbg:#450a0a;--ok:#86efac;--okbg:#052e16}}",
        "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,-apple-system,Segoe UI,sans-serif}",
        "a{color:var(--accent)}a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible{outline:3px solid var(--accent);outline-offset:2px}",
        ".skip{position:absolute;left:-9999px;top:0;background:var(--bg);padding:.5rem 1rem;z-index:10}.skip:focus{left:0}",
        "header,main,footer{max-width:78rem;margin:0 auto;padding:1rem 1.25rem}h1{font-size:1.7rem;margin:.2rem 0 .4rem}h2{font-size:1.25rem;margin:2rem 0 .6rem}h3{font-size:1.05rem}",
        ".lead{color:var(--muted);max-width:80ch}.muted{color:var(--muted)}",
        ".card{border:1px solid var(--line);border-radius:.5rem;padding:1rem 1.1rem;margin:1rem 0}",
        "fieldset{border:1px solid var(--line);border-radius:.5rem;padding:.8rem 1rem;margin:0 0 1rem}legend{font-weight:600;padding:0 .35rem}",
        "label{display:block;font-weight:600;margin:.55rem 0 .2rem}input,select,textarea{width:100%;padding:.45rem .5rem;border:1px solid var(--line);border-radius:.3rem;background:var(--bg);color:var(--fg);font:inherit}",
        "textarea{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9rem}.help{font-size:.85rem;color:var(--muted);margin:.15rem 0 .35rem}",
        "button{font:inherit;padding:.6rem 1rem;border:1px solid var(--accent);border-radius:.35rem;background:var(--accent);color:#fff;cursor:pointer}",
        ".status{border-left:4px solid;padding:.7rem .9rem;margin:1rem 0;border-radius:.3rem}.status.ok{border-color:var(--ok);background:var(--okbg)}.status.warn{border-color:var(--warn);background:var(--warnbg)}.status.error{border-color:var(--err);background:var(--errbg)}",
        "table{border-collapse:collapse;width:100%;margin:.6rem 0 1.2rem;font-size:.92rem}caption{text-align:left;font-weight:600;padding:.3rem 0}th,td{border:1px solid var(--line);padding:.35rem .5rem;vertical-align:top;text-align:left}th{background:color-mix(in srgb,var(--line) 25%,transparent)}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-word}.display{color:var(--muted);font-size:.88rem}",
        "dl.provenance{display:grid;grid-template-columns:max-content 1fr;gap:.35rem .8rem;font-size:.9rem}dt{font-weight:600}dd{margin:0;overflow-wrap:anywhere}",
        "details{margin:.5rem 0}summary{cursor:pointer;font-weight:600}",
        "footer{border-top:1px solid var(--line);margin-top:2rem;color:var(--muted);font-size:.88rem}",
        "</style>\n</head>\n<body>\n",
        "<a class=\"skip\" href=\"#main\">Skip to main content</a>\n",
        "<header><p class=\"muted\">MetaManifold · validated statistics</p>",
        "<h1>", _html(title), "</h1>",
        "<p class=\"lead\">Descriptive summaries from exact integer counts. ",
        "Higher precision reduces arithmetic rounding error; it does not make a value exact, ",
        "and no hypothesis test, confidence interval, significance claim or estimator coverage guarantee is made here.</p>",
        "</header>\n<main id=\"main\">\n")
end

function _ui_footer(io)
    print(io, "</main>\n<footer><p>This page is generated by Julia. ",
        "The JSON endpoints remain the machine-readable contract: ",
        "<a href=\"/api/v1/statistics/catalogue\">catalogue</a>, ",
        "<code>POST /api/v1/statistics/summaries</code>. ",
        "See <code>VALIDATED_STATISTICS.md</code> for storage and boundary contracts.</p>",
        "<p>No client-side script runs on this page. No value is imported from a placeholder or a mock.</p>",
        "</footer>\n</body>\n</html>\n")
end

function _ui_catalogue_block(io, catalogue)
    if isnothing(catalogue)
        print(io, "<div class=\"status warn\" role=\"status\">",
            "The approved method catalogue could not be loaded, so this page cannot show the ",
            "catalogue fingerprint. The analysis form remains available; a request that would ",
            "rely on an unknown method will fail explicitly.</div>")
        return
    end
    document = catalogue.document
    info = document["catalogue"]
    print(io, "<div class=\"card\"><h2 style=\"margin-top:0\">Approved catalogue</h2>",
        "<p><strong>", _html(info["id"]), "</strong> — ",
        _html(info["status"]), " by ", _html(info["approved_by"]),
        " on ", _html(info["approved_on"]), ".</p>",
        "<p class=\"muted\">", _html(info["claim_language"]), "</p>",
        "<dl class=\"provenance\"><dt>Catalogue fingerprint</dt><dd><code>",
        _html(catalogue.fingerprint), "</code></dd>",
        "<dt>Supported methods</dt><dd>",
        _html(join(supported_method_ids(document), ", ")), "</dd>",
        "<dt>Approval record</dt><dd><a href=\"", _html(info["approval_reference"]),
        "\" rel=\"noreferrer\">", _html(info["approval_reference"]), "</a></dd></dl>",
        "<p class=\"muted\">Unsupported entries are published so that a missing method is ",
        "an explicit state, never a silent fallback.</p></div>")
end

function _ui_form(io, params, catalogue)
    print(io, "<section aria-labelledby=\"form-heading\"><h2 id=\"form-heading\">Analyse a count table</h2>",
        "<form method=\"post\" action=\"/statistics\">",
        "<fieldset><legend>Numeric policy</legend>",
        "<label for=\"mode\">Mode</label>",
        "<select id=\"mode\" name=\"mode\" aria-describedby=\"mode-help\">",
        "<option value=\"exact_counts\"", _selected(params, "mode", "exact_counts"),
        ">exact_counts — integers and exact rationals</option>",
        "<option value=\"high_precision\"", _selected(params, "mode", "high_precision"),
        ">high_precision — MPFR approximations at an explicit precision</option>",
        "</select><p class=\"help\" id=\"mode-help\">The ordinary Float64 workflows are not ",
        "offered here. Selecting a validated mode is explicit; it is never inferred from the data.</p>",
        "<label for=\"precision_bits\">MPFR precision (bits, high_precision only)</label>",
        "<input id=\"precision_bits\" name=\"precision_bits\" type=\"number\" min=\"",
        ORDINARY_PRECISION_BITS + 1, "\" max=\"", MAX_PRECISION_BITS, "\" step=\"1\" value=\"",
        _html_params(params, "precision_bits", string(DEFAULT_HIGH_PRECISION_BITS)),
        "\" aria-describedby=\"precision-help\"><p class=\"help\" id=\"precision-help\">",
        "Must be greater than 53. The achieved precision is recorded in the result.</p>",
        "<label for=\"max_denominator_bits\">Rational numerator/denominator bit budget</label>",
        "<input id=\"max_denominator_bits\" name=\"max_denominator_bits\" type=\"number\" min=\"32\" max=\"",
        MAX_DENOMINATOR_BITS, "\" step=\"1\" value=\"",
        _html_params(params, "max_denominator_bits", string(DEFAULT_MAX_DENOMINATOR_BITS)),
        "\"><p class=\"help\">Exceeding this budget is an explicit resource error, never a float fallback.</p>",
        "<label for=\"round_digits\">Display decimal places</label>",
        "<input id=\"round_digits\" name=\"round_digits\" type=\"number\" min=\"0\" max=\"",
        MAX_ROUND_DIGITS, "\" step=\"1\" value=\"",
        _html_params(params, "round_digits", "6"),
        "\"><p class=\"help\">Display only. Stored exact values and MPFR storage values stay distinct.</p>",
        "<label for=\"time_limit_seconds\">Optional time limit (seconds, 1–3600)</label>",
        "<input id=\"time_limit_seconds\" name=\"time_limit_seconds\" type=\"number\" min=\"1\" max=\"3600\" step=\"1\" value=\"",
        _html_params(params, "time_limit_seconds", ""),
        "\"><p class=\"help\">Cooperative cancellation between cells, samples and rows. Leave blank for no deadline.</p>",
        "</fieldset>",
        "<fieldset><legend>Count table</legend>",
        "<label for=\"sample_labels\">Sample labels (comma or newline separated)</label>",
        "<textarea id=\"sample_labels\" name=\"sample_labels\" rows=\"3\" required aria-describedby=\"sample-help\">",
        _html_params(params, "sample_labels", "A, B"), "</textarea>",
        "<p class=\"help\" id=\"sample-help\">Labels must be non-blank and unique.</p>",
        "<label for=\"feature_labels\">Feature labels (comma or newline separated)</label>",
        "<textarea id=\"feature_labels\" name=\"feature_labels\" rows=\"3\" required aria-describedby=\"feature-help\">",
        _html_params(params, "feature_labels", "taxon 1, taxon 2, taxon 3"), "</textarea>",
        "<p class=\"help\" id=\"feature-help\">One row of counts per feature; one column per sample.</p>",
        "<label for=\"counts\">Counts (features × samples)</label>",
        "<textarea id=\"counts\" name=\"counts\" rows=\"8\" required aria-describedby=\"counts-help\">",
        _html_params(params, "counts", "1, 2\n3, 1\n1, 1"), "</textarea>",
        "<p class=\"help\" id=\"counts-help\">Non-negative whole-number literals only. ",
        "Decimal or exponent notation is refused, even when its mathematical value is integral.</p>",
        "<label for=\"groups\">Optional groups (one label per sample)</label>",
        "<input id=\"groups\" name=\"groups\" type=\"text\" value=\"",
        _html_params(params, "groups", ""),
        "\" aria-describedby=\"groups-help\"><p class=\"help\" id=\"groups-help\">",
        "Groups are supported in exact_counts mode only. Leave blank for no group summaries.</p>",
        "<label><input type=\"checkbox\" name=\"persist\" value=\"on\"", _checked(params, "persist"),
        " style=\"width:auto\"> Persist an immutable derived analysis</label>",
        "<p class=\"help\">Persistence creates a content-addressed record beneath ",
        "<code>projects/_derived/direct</code> and never overwrites an existing result.</p>",
        "</fieldset>",
        "<button type=\"submit\">Run validated summary</button>",
        "</form></section>\n")
end

function _ui_warnings(io, warnings)
    isempty(warnings) && return
    print(io, "<h3>Warnings</h3><ul>")
    for warning in warnings
        print(io, "<li>", _html(warning), "</li>")
    end
    print(io, "</ul>")
end

function _ui_zero_state(value)
    isnothing(value) ? "undefined (zero total)" : _html(value)
end

function _ui_exact_proportion(raw, policy)
    isnothing(raw) && return "<span class=\"display\">undefined (zero total)</span>"
    text = string(raw)
    rational = parse_exact_rational(text; policy=policy)
    rendered = to_display(exact_value(rational); digits=policy.round_digits)
    return "<code>$( _html(text) )</code><br><span class=\"display\">$( _html(rendered) )</span>"
end

function _ui_high_precision_value(value)
    isnothing(value) && return "<span class=\"display\">undefined (zero total)</span>"
    value isa AbstractDict || return _html(value)
    print_value = get(value, "value", "")
    display = get(value, "display", "")
    bits = get(value, "precision_bits", "")
    kind = get(value, "kind", "approximate")
    string("<code>", _html(print_value), "</code><br><span class=\"display\">",
           _html(kind), " · ", _html(string(bits)), "-bit · display: ",
           _html(display), "</span>")
end

function _ui_sample_table(io, result, outcome)
    samples = get(result, "samples", [])
    isempty(samples) && return
    mode = string(get(result, "mode", outcome.policy.mode))
    print(io, "<h2 id=\"results-heading\">Result</h2>",
        "<table><caption>Per-sample descriptive summary</caption><thead><tr>",
        "<th scope=\"col\">Sample</th><th scope=\"col\">Status</th>",
        "<th scope=\"col\">Total</th><th scope=\"col\">Observed richness</th>")
    if mode == "exact_counts"
        print(io, "<th scope=\"col\">Defined proportions</th>")
    else
        print(io, "<th scope=\"col\">Shannon (approximate)</th>",
            "<th scope=\"col\">Gini–Simpson (approximate)</th>")
    end
    print(io, "<th scope=\"col\">Warnings</th></tr></thead><tbody>")
    for sample in samples
        total = get(sample, "total", "")
        richness = get(sample, "richness", nothing)
        print(io, "<tr><th scope=\"row\">", _html(get(sample, "label", "")),
            "</th><td>", _html(get(sample, "status", "")),
            "</td><td><code>", _ui_zero_state(total), "</code></td><td>")
        if isnothing(richness)
            print(io, "<span class=\"display\">not reported in exact_counts</span>")
        else
            print(io, _html(richness))
        end
        print(io, "</td>")
        if mode == "exact_counts"
            defined = get(sample, "proportions_defined", false)
            print(io, "<td>", defined ? "defined" : "<span class=\"display\">undefined (zero total)</span>", "</td>")
        else
            print(io, "<td>", _ui_high_precision_value(get(sample, "shannon", nothing)),
                "</td><td>", _ui_high_precision_value(get(sample, "gini_simpson", nothing)),
                "</td>")
        end
        warnings = get(sample, "warnings", [])
        print(io, "<td>", isempty(warnings) ? "—" : _html(join(warnings, "; ")), "</td></tr>")
    end
    print(io, "</tbody></table>")
end

function _ui_detail_tables(io, result, outcome)
    mode = string(get(result, "mode", outcome.policy.mode))
    mode == "exact_counts" || return
    n_cells = length(outcome.features) * length(outcome.labels)
    if n_cells > _STATISTICS_UI_TABLE_CELLS
        print(io, "<div class=\"status warn\" role=\"status\">The per-cell table is omitted ",
            "because this request has $n_cells cells (the display cap is ",
            _STATISTICS_UI_TABLE_CELLS, "). The summary, provenance and canonical JSON ",
            "remain authoritative; request the JSON endpoint for the full matrix.</div>")
        return
    end
    samples = get(result, "samples", [])
    for (index, sample) in enumerate(samples)
        index > length(outcome.labels) && break
        label = outcome.labels[index]
        print(io, "<details><summary>Exact counts and proportions for ",
            _html(label), "</summary><table><caption>Sample ",
            _html(label), " (features × exact proportion)</caption><thead><tr>",
            "<th scope=\"col\">Feature</th><th scope=\"col\">Count</th>",
            "<th scope=\"col\">Exact proportion and display</th></tr></thead><tbody>")
        counts = get(sample, "counts", [])
        proportions = get(sample, "proportions", [])
        for (i, feature) in enumerate(outcome.features)
            i > length(counts) && break
            raw = i <= length(proportions) ? proportions[i] : nothing
            print(io, "<tr><th scope=\"row\">", _html(feature),
                "</th><td><code>", _html(counts[i]), "</code></td><td>",
                _ui_exact_proportion(raw, outcome.policy), "</td></tr>")
        end
        print(io, "</tbody></table></details>")
    end
end

function _ui_group_table(io, result, outcome)
    groups = get(result, "groups", [])
    isempty(groups) && return
    print(io, "<h3>Group summaries</h3><table><caption>Exact group totals and proportions",
        "</caption><thead><tr><th scope=\"col\">Group</th><th scope=\"col\">Members</th>",
        "<th scope=\"col\">Total</th><th scope=\"col\">Status</th></tr></thead><tbody>")
    for group in groups
        members = get(group, "members", [])
        print(io, "<tr><th scope=\"row\">", _html(get(group, "label", "")),
            "</th><td>", _html(join(members, ", ")), "</td><td><code>",
            _ui_zero_state(get(group, "total", "")), "</code></td><td>",
            _html(get(group, "status", "")), "</td></tr>")
    end
    print(io, "</tbody></table>")
end

function _ui_provenance(io, result, outcome)
    policy = get(result, "numeric_policy", Dict{String,Any}())
    software = get(result, "software", Dict{String,Any}())
    print(io, "<h3>Provenance and reproducibility</h3><dl class=\"provenance\">",
        "<dt>Mode</dt><dd><code>", _html(get(result, "mode", outcome.policy.mode)), "</code></dd>",
        "<dt>Numeric policy fingerprint</dt><dd><code>",
        _html(get(policy, "fingerprint", get(result, "policy_fingerprint", ""))), "</code></dd>",
        "<dt>Input fingerprint</dt><dd><code>",
        _html(get(result, "input_sha256", "")), "</code></dd>",
        "<dt>Policy</dt><dd>precision_bits=", _html(get(policy, "precision_bits", "")),
        ", max_denominator_bits=", _html(get(policy, "max_denominator_bits", "")),
        ", round_digits=", _html(get(policy, "round_digits", "")),
        ", rounding=", _html(get(policy, "rounding", "")), "</dd>",
        "<dt>Software</dt><dd>", _html(join(["$key $(software[key])" for key in sort(collect(keys(software)))] , "; ")), "</dd>")
    if haskey(result, "analysis_id")
        id = string(result["analysis_id"])
        print(io, "<dt>Derived analysis ID</dt><dd><code>", _html(id),
            "</code><br><a href=\"/api/v1/statistics/derived/", _html(id),
            "\">Read the immutable record</a></dd>")
    else
        print(io, "<dt>Derived analysis</dt><dd class=\"display\">Not persisted (persist was unchecked).</dd>")
    end
    print(io, "</dl>")
end

function _ui_result(io, result, outcome)
    status = string(get(result, "status", "unknown"))
    status_class = status == "success" ? "ok" : status == "partial" ? "warn" : "error"
    role = status == "error" ? "alert" : "status"
    print(io, "<div class=\"status ", status_class, "\" role=\"", role, "\">",
        "<strong>Status: ", _html(status), ".</strong> ",
        _html(get(result, "claim", "No claim is made.")), "</div>")
    _ui_sample_table(io, result, outcome)
    _ui_group_table(io, result, outcome)
    _ui_detail_tables(io, result, outcome)
    _ui_warnings(io, get(result, "warnings", []))
    diagnostics = get(result, "diagnostics", Dict{String,Any}())
    if !isempty(diagnostics)
        print(io, "<h3>Diagnostics</h3><dl class=\"provenance\">")
        for key in sort(collect(keys(diagnostics)))
            print(io, "<dt>", _html(key), "</dt><dd>", _html(diagnostics[key]), "</dd>")
        end
        print(io, "</dl>")
    end
    _ui_provenance(io, result, outcome)
end

function _ui_limitations(io)
    print(io, "<section aria-labelledby=\"limits-heading\"><h2 id=\"limits-heading\">",
        "What this does not claim</h2><ul>",
        "<li>These are descriptive summaries. They do not test a hypothesis, estimate a ",
        "confidence interval, or report a p-value.</li>",
        "<li>Exact integer and rational arithmetic removes representation and arithmetic ",
        "rounding for those operations. It does not remove measurement error, sampling ",
        "uncertainty, model misspecification or biological bias.</li>",
        "<li>Higher precision is not exactness. MPFR values are labelled approximate and ",
        "their achieved precision is recorded.</li>",
        "<li>A zero-total sample has no defined relative-abundance distribution. Its ",
        "proportions and diversity values are undefined, not zero.</li>",
        "<li>The ordinary Float64 workflows and saved analyses are unchanged when this ",
        "page is not used.</li></ul></section>")
end

function _ui_error_block(io, error)
    print(io, "<div class=\"status error\" role=\"alert\"><strong>The request did not produce ",
        "a result.</strong><p>", _html(error), "</p><p>No plausible-looking partial result ",
        "was returned. Correct the input or resource setting and submit again.</p></div>")
end

function _statistics_page(; params::AbstractDict=Dict{String,String}(), outcome=nothing,
                          error::Union{Nothing,AbstractString}=nothing,
                          catalogue=nothing)
    io = IOBuffer()
    _ui_header(io, _STATISTICS_UI_TITLE)
    _ui_catalogue_block(io, catalogue)
    _ui_form(io, params, catalogue)
    !isnothing(error) && _ui_error_block(io, error)
    if !isnothing(outcome)
        print(io, "<section aria-labelledby=\"results-heading\">")
        _ui_result(io, outcome.result, outcome)
        print(io, "</section>")
    end
    _ui_limitations(io)
    _ui_footer(io)
    String(take!(io))
end

@get "/statistics" function(req)
    catalogue = try
        load_method_catalogue()
    catch err
        @error "statistics UI could not load the method catalogue" exception=(err, catch_backtrace())
        nothing
    end
    _statistics_html_response(_statistics_page(; catalogue))
end

@post "/statistics" function(req)
    params = try
        _parse_statistics_form(req)
    catch err
        err isa InterruptException && rethrow()
        message = err isa ArgumentError || err isa ResourceLimitError ?
            _ui_message(err) : "The submitted form could not be parsed."
        return _statistics_html_response(
            _statistics_page(; params=Dict{String,String}(), error=message);
            status=_ui_status(err))
    end
    try
        outcome = _ui_run(params)
        catalogue = try
            load_method_catalogue()
        catch
            nothing
        end
        _statistics_html_response(_statistics_page(; params, outcome, catalogue))
    catch err
        err isa InterruptException && rethrow()
        status = _ui_status(err)
        message = status == 500 ? "The validated statistics request failed unexpectedly. No result is claimed." :
                                  _ui_message(err)
        status == 500 && @error "statistics UI request failed" exception=(err, catch_backtrace())
        catalogue = try
            load_method_catalogue()
        catch
            nothing
        end
        _statistics_html_response(_statistics_page(; params, error=message, catalogue);
            status)
    end
end
