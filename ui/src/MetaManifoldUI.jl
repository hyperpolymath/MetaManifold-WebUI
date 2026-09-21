# SPDX-License-Identifier: AGPL-3.0-only
module MetaManifoldUI
using Genie, Stipple, Stipple.ReactiveTools, StippleUI, HTTP
include("Contracts.jl")
include("BackendClient.jl")
using .Contracts, .BackendClient

const BACKEND = Ref{Backend}()

# Public output is a deliberately small presentation projection, not internal state.
card(s::StudySummary) = (name=s.name, run_count=s.run_count, group_count=s.group_count,
    active_job_count=s.active_job_count, href="/studies/" * HTTP.URIs.escapeuri(s.name))

@app BrowserModel begin
    @private selected_study = ""
    @out study_title = "Studies"
    @out fixture_mode = get(ENV, "METAMANIFOLD_UI_FIXTURES", "0") == "1"
    @out studies = NamedTuple[]
    @out runs = String[]
    @out groups = String[]
    @out detail = false
    @out loading = true
    @out error_message = ""
    @out active_jobs = 0
    @in refresh = false

    @onchange isready begin
        isready && load!(__model__)
    end
    @onbutton refresh begin
        load!(__model__)
    end
end

function load!(model)
    model.loading[] = true
    model.error_message[] = ""
    # Remove old data on failure rather than presenting stale results as current.
    model.studies[] = NamedTuple[]
    model.runs[] = String[]
    model.groups[] = String[]
    try
        name = model.selected_study[]
        # Send route-derived state after the client subscribes; post-render setup
        # alone is not sufficient to initialise every browser model field.
        model.detail[] = !isempty(name)
        model.study_title[] = isempty(name) ? "Studies" : name
        if isempty(name)
            model.studies[] = NamedTuple[card(s) for s in list_studies(BACKEND[])]
        else
            study = get_study(BACKEND[], name)
            model.study_title[] = study.summary.name
            model.active_jobs[] = study.summary.active_job_count
            model.runs[] = study.runs
            model.groups[] = study.groups
        end
    catch e
        if e isa BackendError
            model.error_message[] = e.message
        elseif e isa ContractError
            model.error_message[] = "Backend data does not match the study contract. Please report this error."
            @warn "Study response contract failed" exception=e
        else
            e isa InterruptException && rethrow()
            model.error_message[] = "Unable to load this page. Please retry."
            @error "UI load failed" exception=(e, catch_backtrace())
        end
    finally
        model.loading[] = false
    end
    nothing
end

function ui()
    [Genie.Renderer.Html.style(read(joinpath(@__DIR__, "style.css"), String)),
    """
    <main class="mm-shell">
      <header class="mm-brand"><a href="/studies">MetaManifold</a><span>JULIA WORKSPACE · MIGRATION PREVIEW</span></header>
      <section class="mm-heading"><div><a v-if="detail" href="/studies" class="mm-back">← All studies</a>
      <h1>{{ study_title }}</h1><p>Explore your studies and sequencing runs.</p></div>
    """,
    btn("Refresh", @click(:refresh), color="primary", loading=:loading, disable=:loading),
    """
      </section>
      <aside v-if="fixture_mode" class="mm-note"><strong>DEMO DATA — disposable test fixtures, not your studies.</strong></aside>
      <aside class="mm-note">Read-only migration preview. Pipeline controls, editing and results remain in the existing application.</aside>
      <div v-if="error_message" role="alert" class="mm-error">{{ error_message }}</div>
      <p v-if="loading" role="status">Loading from MetaManifold…</p>
      <section v-if="!loading && !error_message && !detail">
        <p v-if="studies.length === 0" class="mm-empty">No studies found. Create one in the existing application or add data to the backend.</p>
        <div class="mm-grid"><a v-for="study in studies" :key="study.name" :href="study.href" class="mm-card">
          <h2>{{ study.name }}</h2><div class="mm-stats"><span><strong>{{ study.run_count }}</strong> Runs</span>
          <span><strong>{{ study.group_count }}</strong> Groups</span></div>
          <p>{{ study.active_job_count }} active jobs <span class="mm-arrow">→</span></p>
        </a></div>
      </section>
      <section v-if="!loading && !error_message && detail">
        <p>{{ active_jobs }} active jobs</p><div class="mm-grid">
          <article class="mm-card"><h2>Runs</h2><p v-if="!runs.length">No direct runs.</p>
          <ul><li v-for="run in runs" :key="run">{{ run }}</li></ul></article>
          <article class="mm-card"><h2>Groups</h2><p v-if="!groups.length">No groups.</p>
          <ul><li v-for="group in groups" :key="group">{{ group }}</li></ul></article>
        </div>
      </section>
      <footer>Stipple + Vue · Julia-owned application state · Existing scientific backend</footer>
    </main>
    """]
end

function configure!(; backend=get(ENV, "METAMANIFOLD_API_ORIGIN", "http://127.0.0.1:8080"))
    BACKEND[] = Backend(backend)
    # Route selection is page-local. Session model restoration would otherwise
    # carry a detail model into /studies, even with separate websocket channels.
    Stipple.enable_model_storage(false)
    Stipple.SHARE_CHANNELS_ACROSS_WINDOWS[] = false
    @page("/", ui, model=BrowserModel)
    @page("/studies", ui, model=BrowserModel)
    @page("/studies/:study#[\\p{L}\\p{N}_ .%+\\-]+", ui, model=BrowserModel, post=model -> begin
        model.selected_study[] = String(Genie.Router.params(:study))
        model.study_title[] = model.selected_study[]
        model.detail[] = true
        nothing
    end)
end
end
