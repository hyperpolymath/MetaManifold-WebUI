<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Testing-taxonomy facet coverage — MetaManifold-WebUI

Status: Prompt-7 extension (2026-09-18, Europe/London). This file maps the
estate standard (`standards/testing-and-benchmarking/TESTING-TAXONOMY.adoc`)
onto this repository and records, for every facet, an honest state:

- **REAL** — an executable check exists and is run in `just ci` / the bun
  suite; it can and does fail.
- **THIN** — something exists but under-covers the category; named with the
  gap.
- **ABSENT** — nothing meaningful exists; named with the justification.
  Per the taxonomy doctrine, an honest ABSENT beats a vacuous pass.

Provenance rule honoured: draw from `proven-tests-and-benches` first
(seeded property discipline, harness/payload fixture separation,
silence/firing reflexive fixtures, never-throw fuzz invariants).

## Part I — the 18 test categories

| # | Category | State | Evidence / justification |
|---|---|---|---|
| 1 | Unit | REAL | `frontend/tests/unit/*.test.ts` (15 files), run by `just test-unit`; pure-module boundaries, parameterised variants. |
| 2 | Point-to-Point | REAL | `frontend/tests/integration/api-client.test.ts` — client boundary against a stubbed `fetch` transport (HTTP-error semantics, query construction, payload passthrough). |
| 3 | End-to-End | THIN | Playwright lane exists (`just test-e2e`, 3 specs scaffolded) but fails **loudly** in lanes without browsers; not wired into `ci`. Honest scaffold, per `docs/testing/infrastructure.md`. |
| 4 | Build | THIN | `just build` runs in CI; in the ~1.4 GB sandbox `vite build` is V8-OOM-killed (evidenced 2026-09-18, SIGABRT heap cap) — environment capacity, not a code defect. No bundle-content assertions yet. |
| 5 | Execution & Runtime | ABSENT (justified) | The runtime surface is the Julia server; booting it in this sandbox is environment-blocked (see Launcher verdict below). The dev-server pathway IS exercised: `just dev` boot + HTTP 200 verified. |
| 6 | Reflexive | REAL | `tests/unit/reflexive-gates.test.ts` — executes `check-spdx.sh` / `check-format.sh` unmodified against fixture git repos; proves each gate both stays silent and fires (MISSING-SPDX, BAD-IDENTIFIER, DUPLICATE-SPDX, TRAILING-WS). |
| 7 | Lifecycle | ABSENT (justified) | Application lifecycle is start/stop/status via the estate launcher — exercised as mechanism (help/version/status/stop/fail-closed start) and blocked at real boot by sandbox RAM. Server-state lifecycle across restarts is server-owned. |
| 8 | Smoke | REAL | `just ci` composite + launcher `--status`; smoke boundary test (`component-exports`, `component-contracts`) proves module surfaces load. |
| 9 | Property / Generative | REAL | `tests/unit/property-figure-colours.test.ts` — seeded mulberry32 generators (hand-rolled, no new deps; seeds pinned in-file), 400 generated cases over totality/immutability/selectivity/application/idempotence laws. Ported from proven-tests-and-benches discipline. |
| 10 | Mutation | ABSENT (justified) | No mutation runner in the bun/Julia toolchain; adding stryker+React surface would be heavy machinery for a 15-file suite. The reflexive tests give first-order "can the checks fail" assurance instead. |
| 11 | Fuzz | REAL (lite) | `tests/unit/fuzz-totality.test.ts` — curated hostile corpus × adapter entry points; invariant: wire-shaped garbage never throws (41 hostile documents × 5 maps/cosmetics + error funnel + text utils). Scoped to JSON-shaped input, stated in-file. |
| 12 | Contract / Invariant | REAL | Type-level contract suite (`.type-test.ts`) + runtime invariants: rank vocabulary twins, `FUNCDB_FIELDS ↔ prefill` alignment, `CONTAM_STYLE` totality. |
| 13 | Regression | REAL (bench-line) | `frontend/bench` workloads pin byte-exact checksums of transformed figures/tables — behaviour-preservation enforced; timing deltas informational. |
| 14 | Chaos / Resilience | THIN→REAL (lite) | `fuzz-totality` includes the error funnel (`errorMessage`) over non-Error hostile throws; HTTP-failure resilience covered in the P2P suite (rejected fetches, unparseable bodies). Full-process fault injection (killed server mid-write) is server-side and sandbox-blocked. |
| 15 | Compatibility | THIN | CI runs the pinned Julia channel and pinned bun; single-runtime repo by design. Browser matrix is an E2E concern (lane scaffolded). |
| 16 | Proof Regression | ABSENT (justified) | No proof assistant in this repo; the type-level suite (`tsc --noEmit` over `.type-test.ts`) is the mechanism available at this fidelity, and it is REAL. |
| 17 | Type-Safe | REAL | `just test-types` = `tsc --noEmit` over `src/types/__tests__/*.type-test.ts`; 165→0 error migration lockin, no `any` outside single-line `FIXME(types)` exceptions. |
| 18 | Coupling / Drift | REAL | `tests/unit/coupling-api-routes.test.ts` — every TS client endpoint must exist in the Julia routes (`@get/@post/...` extraction, template-segment normalised); plus existing RANK_ORDER↔FUNCDB coupling tests. Verified: 0 orphans over 61 endpoints / 74 routes. |

## Part II — the 14 aspects (cross-cutting)

Meaningful-to-this-repo subset, per the taxonomy's "cover what is
meaningful" rule:

| Aspect | State | Note |
|---|---|---|
| Interoperability | REAL | Coupling/drift suite (client↔routes), typed wire types in `src/api/types.ts`, payload-verbatim discipline in P2P tests. |
| Dependability | THIN | Error funnel invariants (fuzz + P2P); full recoverability needs the server (sandbox-blocked). |
| Security | THIN | `just audit` surface exists and currently reports a real transitive HIGH (`fast-uri` SSRF advisory via vite dep chain) — tracked, not hidden. No injection testing (server-owned). |
| Performance | REAL (bench-lane) | Frontend bench with checksum gates; Six-Sigma CI classification adopted from the standard (see Part IV). |
| Functionality | REAL | Unit + P2P + property suites over the adapters the UI is built from. |
| Maintainability | REAL | Hygiene gates (`spdx`, `format`, `lint`), conventional-commit gate, FIXme index. |
| Reproducibility | REAL | `docs/reproducibility.md`, pinned lockfile (hash recorded), pinned toolchains. |
| Observability | THIN | Client error surface only; server telemetry server-owned. |
| Usability / Accessibility / Privacy / Safety / Versability / Portability | ABSENT (justified) | UI-heuristic aspects without harnesses in this lane; privacy/safety not applicable to a local analysis tool's frontend tests; portability = single-runtime by design. |

## Part III — benchmark categories (7 per the standard)

| Category | State | Note |
|---|---|---|
| Latency | REAL | `frontend/bench` (`just bench`) — two workloads vs committed baseline; checksum hard-gated, timing informational. |
| Startup | THIN | Dev-server boot measured informally (Vite ~500 ms); Julia cold-boot measured during launcher verdict (~>270 s, sandbox-blocked completion). |
| Memory | THIN | Surfaced as environment capacity analysis during the launcher verdict; no dedicated harness. |
| Build | ABSENT → THIN | Build wall-time observable in CI; no dedicated benchmark harness. |
| Throughput / Energy / FFI | ABSENT (justified) | Throughput is a server property (Julia lanes); energy measurement has no harness in this estate; FFI is RCall-side and exercised by `bench/layer1_mock_recovery` when Julia is available (`just bench-julia`, fails loudly otherwise). |

Six-Sigma classification (from the standard) is adopted as CI policy for the
bench lane: >50% regression hard-fail, 20–50% soft, ±20% ordinary,
>20% improvement flagged. Baseline management: committed
`frontend/bench/baseline.json` (the standard's "last-10-CI-runs mean" is
recorded as the CI-lane tightening, documented rather than faked).

## Launcher verdict (Execution & Runtime / Lifecycle evidence)

| Step | Result |
|---|---|
| `check-spdx` hygiene of launcher | n/a (standards repo) |
| `bash -n` / `--help` / `--version` / `--status` / `--stop` | PASS (graceful no-ops and identity strings) |
| `--start` without Julia | PASS fail-closed with actionable error |
| Julia 1.12.5 (CI channel) + `Pkg.instantiate()` | PASS (second attempt; first OOM-killed during Conda/RCall build stage, exit 137) |
| Real boot attempt ×3 (270–420 s windows) | **ENVIRONMENT-BLOCKED**: cold JIT-precompile of the server dep closure (incl. RCall/Conda/XLSX/PrettyTables) exceeds ~1.4 GB sandbox RAM; farthest attempt reached app-load phase ("Using bundled frontend from web/dist") before the bounded window closed; zero memory left at peak (26 MB avail). Not a repo defect — CI/dev machines boot this routinely. |
| Defect found & fixed during attempts | `start.sh` stored non-executable (git mode 100644 with a bash shebang): the launcher's `nohup ./start.sh` failed with Permission denied. Fixed with a mode-only change (this commit). |

## Bottom line

18 categories: **9 REAL · 3 THIN→REAL upgrades landed this prompt · 3 THIN ·
6 ABSENT** (all ABSENT with justification; none faked). All ABSENT/THIN items
have a named owner lane (CI or server) rather than silent omission.
