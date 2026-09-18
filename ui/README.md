# MetaManifold Stipple/Vue UI

First implementation slice of the frontend migration. The move to Stipple/Vue is the architectural direction; stronger Julia contracts are an accompanying improvement, not a condition of migration.

## Implemented

- Independent Julia environment with resolved Manifest (Julia 1.12.5).
- Genie 6 / Stipple 1 / StippleUI 1 browser UI, with no application TS/React build.
- Read-only study cards, counts, detail pages listing direct runs/groups, manual refresh.
- Loading, empty, missing-study, backend-error and malformed-contract states.
- Concrete StudySummary/Study DTOs and strict boundary decoding; these are runtime checks, not Elm-like static guarantees.
- Fixed-origin backend adapter with bounded HTTP timeouts, no redirects and encoded path segments.
- Fresh per-window reactive models, private route selection, no import of scientific modules.

Not yet ported: study mutations, group/run detail/navigation, jobs/events, config editors, results tables, annotations, charts, exports. The legacy app remains the default. `/studies/:study` is the pilot's explicit route, not yet the legacy `/:study` URL scheme.

## Run with your existing backend

From the repository root, start the original backend/application as usual, then:

```sh
julia --project=ui -e 'using Pkg; Pkg.instantiate()'
METAMANIFOLD_API_ORIGIN=http://127.0.0.1:8080 julia --project=ui ui/serve.jl
```

Open http://127.0.0.1:8081/studies. Backend URL is server configuration; the browser never calls it directly. The new app only issues GET requests. Stop this UI to return to the existing app; no backend config or data migration is involved.

Environment variables:
- `METAMANIFOLD_API_ORIGIN`: backend HTTP(S) origin (default `http://127.0.0.1:8080`).
- `METAMANIFOLD_UI_HOST`: default `127.0.0.1`; use `0.0.0.0` only in a controlled proxy/development environment.
- `METAMANIFOLD_UI_PORT`: default `8081`.
- `METAMANIFOLD_UI_FIXTURES=1`: visible demo-data banner for fixture testing; never set for real data.

This phase is local/single-user. Remote authentication, exact WebSocket origin policy and hardened deployment remain work items. Do not expose an unauthenticated UI/backend publicly. Framework JS/CSS is still required; no application-owned JavaScript build is needed. HTML/Vue template expressions are authored inside Julia; a small CSS file supplies styling.

## Tests

```sh
julia --project=ui ui/test/runtests.jl
```

For adapter/browser integration, start the disposable Julia fixture API separately:

```sh
julia --project=ui ui/test/fixture_server.jl
# In another terminal:
UI_TEST_API=http://127.0.0.1:18080 julia --project=ui ui/test/runtests.jl
# For the UI:
METAMANIFOLD_API_ORIGIN=http://127.0.0.1:18080 METAMANIFOLD_UI_FIXTURES=1 \
  julia --project=ui ui/serve.jl
```

`fixture_server.jl` listens on loopback port 18080, serves synthetic responses only and does not import MetaManifold or read/write studies.

Optional browser regression: install Playwright/Chromium in your test tooling and run `node ui/test/browser.cjs` (`UI_TEST_URL` defaults to `http://127.0.0.1:8081`). If installed outside this repository, set NODE_PATH to that tooling's node_modules. This JS file is test automation, not part of the delivered browser application or its runtime/build dependencies.

On constrained machines where dependency precompilation is too expensive, the development fallback is:

```sh
julia --compiled-modules=no --compile=min -O0 --project=ui ui/serve.jl
```

This starts more slowly and is not a production performance recommendation. The implementation was exercised with these flags after default precompilation exceeded the sandbox's command time budgets.

See `docs/migration/` for remaining feature-parity work. Do not remove the existing frontend until that work is accepted.
