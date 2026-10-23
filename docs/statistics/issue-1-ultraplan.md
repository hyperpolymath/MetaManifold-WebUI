<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Issue #1 ultraplan: completing the validated statistics layer

Status: working plan for the branch `arena/3d3fe618-metamanifold-webui`,
based on `95d484df8111f12b8e96c10922022ffaf6f024df` (the tip of `main` at
the start of the session). This document is a plan and an evidence map, not a
release certificate.

## 1. Reconnaissance

### 1.1 What already exists on `main`

The numeric half of issue #1 landed before this branch:

- `src/analysis/numeric_policy.jl` — immutable `NumericPolicySpec`, checked
  integer sums, exact `Rational{BigInt}` construction, scoped MPFR precision,
  exact/approximate/rounded value kinds, lossless text parsing.
- `src/analysis/exact_summaries.jl` — exact per-sample and per-group counts,
  rational proportions, observed richness, zero-total `nothing` states.
- `src/analysis/high_precision.jl` — MPFR Shannon and Gini–Simpson with exact
  rational intermediates and achieved-precision recording.
- `src/analysis/derived_analyses.jl` — content-addressed immutable records,
  canonical-JSON decoding, atomic hard-link publication, tamper refusal.
- `src/server/routes/validated_statistics.jl` — direct JSON and read-only
  DuckDB endpoints, strict input checks, explicit statuses.
- Unit and reference tests, a benchmark, and CI steps that run the focused
  suite and retain the benchmark artifact.

`VALIDATED_STATISTICS.md` and `VALIDATED_STATISTICS_VALIDATION.md` describe
the increment honestly and list what is still open. The issue comments record
that the bounded method catalogue was approved by the owner on 2026-09-22,
that catalogue item 1 (exact descriptive summaries) shipped, and that the
symbolic gate (#2) remains blocked.

### 1.2 The gaps this branch must close

| Issue #1 requirement | Current state | Gap |
| --- | --- | --- |
| Approve and publish the bounded method catalogue | Approval recorded in an issue comment; the catalogue document is absent from this checkout | Publish the approved scope and a machine-readable catalogue |
| Publish numeric conversion/storage contracts | Code implements the rules; the contract document is absent | Restore the boundary-by-boundary contract and test it |
| Known-answer and independent references | Python `fractions`/`decimal` references exist for two paths | Add cross-language boundary and round-trip evidence |
| Adversarial/precision stability | Some cases exist | Add a dedicated adversarial/precision suite |
| Property/generative tests and fuzzing | Some generative cases exist | Add invariants, metamorphic properties, config fuzzing |
| Negative controls and mutation evidence | Not retained | Add a mutation driver, CI evidence, and recorded commands |
| Simulation studies with pre-set tolerances | Not present | Add a numerical-accuracy simulation, and justify N/A for estimators |
| Representative biological data | Not present | Validate against the MiSeq SOP pipeline output |
| Reproducibility, concurrency, cancellation, limits, recovery | Publication/concurrency/limits partly covered; cancellation absent | Add cooperative cancellation/deadlines and tests |
| UI-to-backend-to-result, accessibility, provenance | API only | Add a Julia-owned, server-rendered UI and route tests |
| Existing behaviour unchanged | Source-level check exists | Add behavioural regression evidence |
| Benchmarks and retained artifacts | Benchmark exists; CI retains it | Extend evidence where needed |
| Standards gates | JSON/JCS partly migrated; new YAML must be KYAML | Make statistics responses JCS; add `.kyaml`; add a standards job |
| Independent review and release approval | Not obtainable by an agent | Prepare a review packet; leave the human gate explicit |

### 1.3 Standards constraints read from `hyperpolymath/standards`

- **JSON-POLICY J-1/J-2 (D306).** Every new or rewritten estate-authored
  `.json` is I-JSON (RFC 7493) and serialised by JCS (RFC 8785), with one
  trailing line feed for files. The reference tool is
  `hyperpolymath/ijson-jcs`. This branch therefore changes the statistics
  responses from `JSON3.write` to the repository's `jcs_json`/`jcs_bytes`
  writer, and tests the bytes.
- **YAML-POLICY Y-3 / D307.** New estate-owned configuration is `.kyaml` with
  KYAML content (flow style, double-quoted string values, two-space indent,
  `---` header). This branch adds the method catalogue as
  `config/defaults/validated_statistics.kyaml` and checks it with the
  standards formatter.
- **Gates.** `scripts/kyaml-format.sh --check` and
  `scripts/check-ijson-jcs.sh` come from `hyperpolymath/standards` at a pinned
  commit. The statistics UI adds no TypeScript; application logic stays in
  Julia. `CONTRIBUTING.md` requires a branch from current `main`, no merge
  commits, one logical change, and CI evidence.

### 1.4 Environment limits recorded honestly

The agent sandbox has no Julia, R, bun, cargo, Go, yq or `ijson-jcs` binary.
Local work can therefore run Python reference checks, static inspection and
JavaScript-runtime boundary probes only. Julia tests and the standards tools
must run in GitHub Actions; the branch is pushed and CI is iterated until the
required checks are green. No local Julia result is claimed.

## 2. Workstreams

### W0 — Publish the plan and the evidence map

- Add this document.
- Keep `VALIDATED_STATISTICS.md` as the numeric/storage contract and update it
  with the new UI, cancellation and JCS behaviour.
- Add a completion dossier (`docs/statistics/validation-evidence.md`) that maps
  every issue criterion to evidence and to any residual gate.

### W1 — Method catalogue, approved and machine-checked

- Add `config/defaults/validated_statistics.kyaml` with the approved v1 scope:
  exact descriptive summaries and high-precision descriptive diversity are
  supported; parametric fits and resampling methods are catalogued but
  unsupported in this release; exact tests are deferred (#3); symbolic work is
  out of scope (#2).
- Add `src/analysis/method_catalogue.jl` to load, validate and fingerprint the
  catalogue. Supported methods must name evidence; limits must match
  `NumericPolicy`; unsupported methods must state why.
- Add `GET /api/v1/statistics/catalogue` returning JCS.
- Add tests that fail if the catalogue and code drift.

### W2 — JCS at the statistics boundary

- Replace `_statistics_json`'s `JSON3.write` with `jcs_json`.
- Test response bytes are canonical JCS, including a value above `2^53` stored
  as a string, and that the response has no trailing newline.
- Test derived records remain canonical on read and on disk.
- Update `docs/ijson-jcs.md` only where this branch changes its subject; do not
  pre-empt the open format-readiness PR.

### W3 — Numeric contracts and boundary evidence

- Restore `docs/statistics/numeric-contracts.md`: JSON, CSV/text, R, DuckDB
  and browser boundaries; integer/rational round trips; explicit refusals;
  precision isolation; display vs storage.
- Add `test/unit/test_statistics_boundaries.jl`:
  - JSON token ranges and string forms;
  - CSV/text parse-and-render round trips;
  - rational round trips and zero denominators;
  - DuckDB integer types vs floating storage;
  - browser `JSON.parse` loss at `2^53 + 1` (Node, skipped loudly if absent);
  - R's 32-bit integer/double limits (Rscript, skipped loudly if absent);
  - JCS round trips.
- Add `docs/statistics/numeric-contracts.md` to the evidence map.

### W4 — Adversarial, property and fuzz coverage

- Add `test/unit/test_statistics_adversarial.jl`: huge counts, all-zero and
  sparse tables, tiny probabilities, boundary parameters, overflow/underflow,
  non-finite and malformed input, request and matrix limits, policy extremes.
- Add `test/unit/test_statistics_properties.jl`: proportion sums, scale
  invariance, feature/sample permutation, zero-feature insertion, group-total
  identities, Shannon/Gini bounds, exact-vs-high-precision agreement,
  precision-convergence, and deterministic JSON-config fuzzing that must never
  return 500.
- Keep every generator seeded; record the seed in failure messages.

### W5 — Cancellation, resource limits and recovery

- Add a cooperative `CancellationToken` with a monotonic deadline to the
  numeric layer.
- Thread it through count validation, sample/group loops, high-precision
  loops, and DuckDB row streaming.
- Map cancellation to HTTP 408 with an explicit unsuccessful state; never
  return a plausible partial result.
- Test pre-cancelled tokens, expired deadlines, precision restoration after
  cancellation, and temp-file recovery.
- Document the check granularity: cancellation is cooperative between cells
  and samples, not an interrupt of a single MPFR operation.

### W6 — Julia-owned UI with accessibility and provenance

- Add a server-rendered HTML page at `/statistics` (no new TypeScript, no
  client-side application logic).
- Form fields: numeric mode, precision bits, denominator budget, display
  digits, sample labels, feature labels, counts, optional groups, persist.
- Semantic HTML: labels, fieldsets/legends, descriptions, error `role="alert"`,
  success `role="status"`, table captions and column scopes, skip link, no
  scripts.
- Render exact/approximate/rounded values distinctly; zero totals as
  "undefined (zero total)", never 0; warnings; policy fingerprint; input
  fingerprint; analysis ID when persisted; software versions.
- Add route-level tests for GET, successful POST, zero-total partial state,
  invalid input, resource limit, cancellation and accessibility markers.
- Pass `/statistics` through the static-file middleware to the Julia route.

### W7 — Biological and simulation validation

- Extend the existing MiSeq SOP integration test, when the pipeline actually
  produced merged tables, to run the validated statistics layer on the real
  count matrix and compare exact totals/proportions with an independent
  reference.
- Add a seeded simulation study with pre-set tolerances. It evaluates numerical
  accuracy and precision convergence, not estimator bias or interval coverage;
  the latter is explicitly N/A because this increment implements no estimator
  with a confidence/coverage claim.
- Document where assumptions fail: descriptive counts say nothing about
  sampling error, detection, compositionality or differential abundance.

### W8 — Mutation/negative controls and reproducibility

- Add `scripts/statistics/mutation_check.py`, a driver that applies one
  mutation at a time, runs the focused test file, restores the source, and
  fails if a mutant survives.
- Mutants cover zero-total handling, overflow refusal, exact-rational storage,
  precision restoration, JCS key ordering, and immutable publication.
- Run a fast subset in CI, retain the log as an artifact, and record the
  commands in `docs/statistics/mutation-evidence.md`.
- Keep the full campaign runnable locally.

### W9 — Standards gates and merge readiness

- Add a standards job that:
  - checks out `hyperpolymath/standards` at a pinned commit;
  - installs pinned `yq` and `ijson-jcs`;
  - runs `kyaml-format.sh --check` on the new `.kyaml`;
  - runs `check-ijson-jcs.sh --enforce` on the first-party JSON files this
    branch owns.
- Run the repository's existing required checks, governance lanes and evidence
  uploads.
- Prepare the PR description with exact commands, what was and was not run,
  and the one residual human gate: independent statistical/scientific review
  and release approval.

## 3. Ordering and dependencies

1. W1 (catalogue) and W2 (JCS) are independent and land first.
2. W3–W5 build on the numeric layer and must precede the UI so the UI can
   display the final states and provenance.
3. W6 depends on W1, W2 and W5.
4. W7 depends on W3–W5 and on the existing integration pipeline.
5. W8 depends on W3–W6 (the tests it mutates must exist).
6. W9 is last and is iterative with CI.

## 4. Definition of done for this branch

A PR is mergeable when:

- the focused statistics suite and the full CI suite pass;
- the new standards job passes;
- the focused benchmark and mutation logs are retained;
- the evidence map names a command and a result for every criterion;
- no existing workflow or algorithm changes when the new modes are not
  selected;
- the only open item is the explicitly human gate: independent
  statistical/scientific review and release approval.

The issue should not be closed administratively by this branch. The review
packet and the issue comment ask the owner to record that approval.

## 5. Commands used by this plan

```bash
# focused unit/reference suite
julia --project=. -t2 test/runtests.jl numeric_policy exact_summaries \
  high_precision derived_analyses validated_statistics method_catalogue \
  statistics_boundaries statistics_adversarial statistics_properties \
  statistics_ui

# references
python3 test/references/check_high_precision_references.py --check \
  test/unit/test_high_precision.jl
python3 test/references/exact_summary_reference.py <input.json>

# benchmark (CI retains the JSON)
julia --project=. -t2 bench/validated_statistics.jl \
  --output validated-statistics-benchmark.json

# mutation subset / full campaign
python3 scripts/statistics/mutation_check.py --fast
python3 scripts/statistics/mutation_check.py --output mutation-evidence.json

# standards gates
bash .standards/scripts/kyaml-format.sh --check \
  config/defaults/validated_statistics.kyaml
bash .standards/scripts/check-ijson-jcs.sh --enforce \
  frontend/public/config.json
```

## 6. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| No local Julia runtime | Push early; use the existing CI job and a focused statistics job for feedback; do not claim unrun results |
| KYAML formatting drift | Generate/validate with the pinned standards formatter in CI; keep the file flow-style and quoted |
| JCS writer rejects a value that `JSON3.write` accepted | All persisted values are already strings or I-JSON-safe integers; add response-byte tests and fix at the storage layer, never by weakening JCS |
| Mutation job is slow or flaky | Run a small, targeted subset in CI; keep the full campaign manual; retain logs |
| UI conflicts with the settled React stack | Server-rendered page only, no new TypeScript; document that the Julia page is the validated-statistics surface and the React app remains the main UI |
| Independent review cannot be supplied by an agent | Publish a review packet and leave the gate explicit; do not claim sign-off |
