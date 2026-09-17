<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Test & benchmark infrastructure

Established 2026-09-17 from the patterns in **hyperpolymath/proven-tests-and-benches**
(pattern source — no patterns invented here; deviations enumerated at the
bottom) and checked against **hyperpolymath/rsr-template-repo**.

## Test runner and version

- **Runner:** `bun:test` — the Bun built-in, driven by `bun test`.
- **Version:** Bun **1.3.10**, pinned at the repo root (`.bun-version`; CI
  installs the pinned toolchain via its existing tool-version pins).
- **Type gate (unchanged):** `tsc --noEmit` via `bun run test:types`;
  scope is the application sources (`src/`), exactly as the strict
  foundation defines it.

## Directory conventions

```
frontend/
├── tests/
│   ├── manifest.a2ml          # battery manifest (proven corpus-unit idiom)
│   ├── fixtures/              # hand-authored, committed on-disk fixtures
│   │   └── run-table-payload.json   # shared with bench (recorded in both manifests)
│   ├── unit/                  # *.test.ts — pure-module + import-graph smokes
│   │                          #   and Prompt-5 type-boundary behaviour suites
│   │                          #   (inventory: docs/testing/coverage.md)
│   ├── integration/           # *.test.ts — fetch-stubbed api-client wiring
│   ├── e2e/                   # *.e2e.ts — playwright lane (opt-in, see below)
│   ├── results/               # junit.xml  (gitignored; CI artifact)
│   └── coverage/              # lcov.info  (gitignored; CI artifact)
└── bench/
    ├── manifest.a2ml          # harness manifest (frozen-workload declaration)
    ├── index.ts               # the harness (see Discipline below)
    ├── fixtures →             # reuses tests/fixtures/run-table-payload.json
    ├── baseline.json          # COMMITTED — per-workload, versioned baseline
    └── results/               # per-run results.json (gitignored; CI artifact)
```

File-suffix rule: `bun test` discovers `*.test.*` / `*.spec.*` only; the
playwright lane therefore uses `*.e2e.ts` so the two runners never collide
(`playwright.config.ts` sets `testDir`/`testMatch` to match).

## How to run locally

```bash
cd frontend
bun install
bun run check          # = test:types && bun test && bench — the full gate
bun run test           # whole battery
bun run test:unit      # tests/unit only
bun run test:integration
bun run test:e2e       # OPT-IN playwright lane (not in `check`; needs
                       # `bunx playwright install` for browser binaries)
bun run bench          # human-readable medians
bun run bench -- --json bench/results/results.json
```

## How CI runs them

Inside the existing CI job, after `bun install --frozen-lockfile` and the
`bun run typecheck` gate:

1. **Test frontend** — `bun test --coverage --coverage-reporter=lcov
   --coverage-dir tests/coverage --reporter=junit --reporter-outfile
   tests/results/junit.xml`
2. **Benchmark frontend** — `bun run bench -- --json bench/results/results.json`
3. **Upload artifacts** (`if: always()`) — `frontend-tests-benchmarks`:
   the JUnit XML, `lcov.info`, and benchmark `results.json`.

Machine-parseable results: **JUnit XML** (`bun test --reporter=junit`,
native to Bun 1.3). Coverage: **lcov** — *reported, never asserted* (no
coverage gate yet; that is a later-prompt decision once real domain tests
exist).

## Where results live

| Artefact | Local path | Committed? | CI artifact? |
|---|---|---|---|
| JUnit XML | `frontend/tests/results/junit.xml` | no | yes |
| Coverage (lcov) | `frontend/tests/coverage/lcov.info` | no | yes |
| Benchmark run | `frontend/bench/results/results.json` | no | yes |
| Benchmark **baseline** | `frontend/bench/baseline.json` | **yes** | n/a |
| Fixtures | `frontend/tests/fixtures/` | **yes** | n/a |
| Manifests | `frontend/{tests,bench}/manifest.a2ml` | **yes** | n/a |

## Benchmark discipline (transferred from proven-tests-and-benches)

`bench/index.ts` is a Bun port of `benchmarks/Benchmark.idr`'s stated rules:

- monotonic clock (`performance.now()`); **REPS = 5** samples (odd → exact
  median); **median is the headline** (a single sample is not a measurement);
- per-sample iteration counts calibrated so one sample costs **tens of ms**
  (measured: ~27 ms and ~14 ms medians at introduction);
- every workload folds outputs into a printed **checksum** — work is
  observable, iteration-dependent, un-memoisable;
- **workloads are FROZEN** (`manifest.a2ml` declares them); editing a
  workload definition invalidates its history and requires re-cutting
  `baseline.json` in the same change;
- `--json <path>` writes the machine-readable set (`schema_version`,
  environment identity — commit/bun/platform/runner, per-result samples +
  median); stdout keeps the human lines; **baseline comparison is
  informational only — never a gate**.

The two representative workloads: `run-table-json-parse` (API payload
parsing) and `figure-colour-overrides` (the real hot path in
`src/api/figureColours.ts`).

## What the scaffolds deliberately do not test

- **No component rendering** — a DOM harness would be needed, and neither
  pattern-source repo defines one. The five plotly-chain modules
  (`PlotlyChart`, `ComparisonPanel`, `ChartEditorInner`, `AnnotationPanel`,
  `RunView`) cannot even be *imported* DOM-less: the minified plotly bundle
  touches `document` at module initialisation. They are filed as
  machine-visible `test.todo` entries in
  `tests/unit/plotly-chain.todo.test.ts`
  (**TODO(tests/prompt-5): plotly-chain modules need a DOM-capable lane** —
  happy-dom/jsdom unit lane or the playwright e2e lane), with no
  application-code changes made to work around it, per the constraint.
- **No domain-complete assertions** — each scaffold imports the module,
  calls one function (or asserts one export-shape property), and checks one
  known value. Prompt 5+ grows this.
- **No coverage gate, no bench regression gate** — see tables above.

## Alignment notes with proven-tests-and-benches and rsr-template-repo

Carried over: hand-authored committed fixtures; AAA-style one-purpose tests;
`manifest.a2ml` batteries (corpus-unit idiom: `[identity]`,
`[subject_shape]`, `[shared_dependencies]` — taxonomy/proof fields are
Idris2-specific and deliberately absent rather than fabricated); frozen
workloads + versioned committed baselines + checksum + median-of-REPS +
machine-readable JSON with environment identity; numbers shipped as CI
artifacts rather than merely asserted; result locations matched to
rsr-template's `tests/` + `benches/` split (frontend-scoped as
`tests/` + `bench/` since the application under test is `frontend/`).

Deviation ledger (explicit, by constraint):

1. **`test:unit` / `test:integration` use path scopes, not `--filter`** —
   Bun 1.3's test runner has no `--filter` flag; lanes are directory-scoped
   (`bun test tests/unit`). Script names kept per the infrastructure prompt.
2. **Manifests are `.a2ml`, not `.yaml`** — the estate/proven manifest
   format is A2ML; no `test-manifest.yaml`/`bench-manifest.yaml` exists in
   the pattern sources to imitate, so `tests/manifest.a2ml` +
   `bench/manifest.a2ml` carry that role with the same intent
   (reproducibility metadata).
3. **E2E lane defined but not provisioned** — `test:e2e` +
   `playwright.config.ts` + one shell-mount spec exist, but browser
   binaries are not installed in the sandbox or CI yet (a heavyweight CI
   provisioning decision reserved for a later prompt); `check` excludes e2e
   by the prompt's own definition.
4. **No `.machine_readable/` estate metadata added** — this repo is a
   third-party fork; the reproducibility role those files play is carried
   by the two `manifest.a2ml` batteries instead.
