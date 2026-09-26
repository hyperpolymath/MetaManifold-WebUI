# SPDX-License-Identifier: MPL-2.0
# Julia-authored progressive-enhancement UI. The tiny JS adapter does transport
# and DOM updates only; scientific, metadata and lifecycle decisions stay in Julia.
module DOIWeb

using JSON3, Dates

export render_page, html_escape
html_escape(text) = replace(string(text), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")

function render_page(study, csrf, environment, enabled; selected_config="")
    bootstrap = replace(JSON3.write(Dict("study" => study, "csrf" => csrf, "environment" => environment,
        "enabled" => enabled, "selected_config" => selected_config)), '<' => "\\u003c", '>' => "\\u003e", '&' => "\\u0026")
    example = JSON3.write(Dict("method" => "nb_glm", "formula" => "~ group", "metadata_columns" => ["group"],
        "normalization" => Dict("method" => "size_factors"), "created_by" => "Replace with your name"))
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Publish an analysis · MetaManifold</title>
  <link rel="stylesheet" href="/api/v1/doi/assets/publication.css">
  <script src="/api/v1/doi/assets/publication.js" defer></script>
</head>
<body>
<main>
  <a href="/studies">← Back to studies</a>
  <header><p class="eyebrow">METAMANIFOLD · EVIDENCE &amp; REPRODUCIBILITY</p>
    <h1>Make an analysis citable</h1><p>Study: <strong>$(html_escape(study))</strong></p>
    <p>Create a private Zenodo draft, review the exact archive, then explicitly publish its DOI.</p>
    <p class="environment $(environment == "production" ? "production" : "sandbox")">$(environment == "production" ? "PRODUCTION — real, permanent DOI publication" : "SANDBOX — test records, not production citations")</p>
  </header>
  <p id="disabled-notice" $(enabled ? "hidden" : "")>Publication is disabled or no server token is configured. An operator must configure Zenodo on the server. Never paste a token into this page.</p>
  <div id="message" role="status" aria-live="polite"></div>
  <div id="error" role="alert" hidden></div>
  <label class="evidence"><input id="evidence-mode" type="checkbox"> Enable Evidence Mode to prepare or publish a DOI</label>
  <section id="advanced" hidden aria-labelledby="prepare-title">
    <h2 id="prepare-title">1. Prepare a draft</h2>
    <p>Files leave this machine when you prepare a draft. After publication, all files are public and the DOI cannot be unminted. Review personal/sample information, host paths, licences, and scientific limitations first.</p>
    <p>Configuration-only bundles are labelled as such. Empty or mock analysis results cannot be published. Raw inputs and reference databases are <strong>not</strong> included.</p>
    <form id="prepare-form">
      <fieldset id="prepare-fields" $(enabled ? "" : "disabled")>
        <label>Saved AnalysisConfig <select id="config-id" required><option value="">Loading configurations…</option></select></label>
        <p id="config-summary"></p>
        <label>Explicit payload <select id="result-id" required><option value="">Choose a configuration first</option></select></label>
        <label>Publication title <input id="title" required maxlength="250"></label>
        <label>Description and reproducibility limitations <textarea id="description" required maxlength="10000" rows="4"></textarea></label>
        <label>Creators — one name per line, preferably “Family, Given” <textarea id="creators" required rows="3" placeholder="Jewell, Jonathan"></textarea></label>
        <div class="columns">
          <label>Licence <select id="license" required><option value="">Choose explicitly</option><option>CC-BY-4.0</option><option>CC-BY-SA-4.0</option><option>CC0-1.0</option></select></label>
          <label>Resource version <input id="version" value="1.0.0" required maxlength="100"></label>
          <label>Publication date <input id="publication-date" type="date" value="$(Date(now(UTC)))" required></label>
        </div>
        <label>GitHub release URL (optional) <input id="release-url" type="url" placeholder="https://github.com/owner/repo/releases/tag/v1.0.0"></label>
        <label>GitHub Projects v2 URL (optional) <input id="project-url" type="url" placeholder="https://github.com/users/owner/projects/1"></label>
        <label class="ack"><input id="upload-ack" type="checkbox" required> I have reviewed the config/provenance and consent to uploading these files to Zenodo as a private draft.</label>
        <button type="submit">Prepare Zenodo draft — does not publish</button>
      </fieldset>
    </form>
    <details><summary>No saved config? Save an explicit configuration</summary>
      <p>This saves a new, immutable configuration, not an analysis result. Edit the JSON before saving. Scientific execution is a separate step; this screen never invokes the scaffold run endpoint.</p>
      <form id="config-form"><label>AnalysisConfig request JSON<textarea id="config-json" rows="8" required>$(html_escape(example))</textarea></label><button type="submit">Save configuration</button></form>
    </details>
  </section>
  <section aria-labelledby="publications-title"><div class="section-heading"><h2 id="publications-title">2. Review &amp; publish</h2><button id="reload" type="button" class="secondary">Reload saved publications</button></div>
    <p>Only a <strong>published</strong> record has a DOI badge. A reserved identifier or accepted request is not proof of publication. Refreshing never retries publication.</p>
    <div id="publications" aria-live="polite">Loading saved publications…</div>
  </section>
  <aside><h2>After publication</h2><p>Download the receipt and citation. The receipt binds the DOI to SHA-256 hashes of the exact config, selected result and uploaded archive, without changing the scientific objects.</p>
    <p>To update a GitHub release and its project board, use <code>scripts/link-doi.sh</code> with the downloaded receipt: review its dry run, then explicitly use <code>--apply</code>. A GitHub failure never causes a second DOI to be minted.</p>
    <p>Back up the study’s private <code>.analysis</code> and <code>.doi</code> directories. This is a local, single-user feature, not an authenticated public upload service.</p>
  </aside>
</main>
<dialog id="publish-dialog" aria-labelledby="confirm-title">
  <h2 id="confirm-title">DANGER — irreversible public publication</h2>
  <p>Publishing registers a permanent DOI and makes every archived file public. Removing a local config will not retract the Zenodo record.</p>
  <p id="confirm-summary"></p><pre id="confirm-hash"></pre>
  <form id="publish-form">
    <label class="ack"><input id="public-ack" type="checkbox" required> I reviewed the downloaded archive, have permission to publish it under its licence, checked privacy, and will disclose scientific DANGER warnings.</label>
    <label>Type <strong id="expected-phrase"></strong><input id="confirmation" autocomplete="off" spellcheck="false" required></label>
    <div class="actions"><button id="cancel-publish" type="button" class="secondary">Cancel — keep draft</button><button id="confirm-publish" type="submit" class="danger" disabled>Publish &amp; mint DOI</button></div>
  </form>
</dialog>
<script id="doi-bootstrap" type="application/json">$bootstrap</script>
</body></html>
"""
end

end # module DOIWeb
