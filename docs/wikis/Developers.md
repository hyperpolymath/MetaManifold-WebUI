<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000030
parent: null
position: 30
kind: page
tags:
  - developers
  - overview
archived: false
-->

# Developers

This section is for people changing the code: where things live, why the
types are the way they are, how the statistics layer is wired, and how to
add to the pipeline without breaking the honesty contract.

Read this section with the repository open. Every claim here names its file;
the deep *why* is in [Deep Dives](Deep-Dives).

## Learning path

1. [Architecture Tour](Developers--Architecture-Tour) — the moving parts and
   the typed stage spine.
2. [Type System](Developers--Type-System) — the frontend type estate, the
   Julia type spine, and the rules for adding either.
3. [Statistics Internals](Developers--Statistics-Internals) — numeric
   policy, estimation, exact summaries, scaling/offsets, AnalysisConfig, and
   the epistemic layer.
4. [Extending the Pipeline](Developers--Extending-the-Pipeline) — adding a
   stage, a method, a filter; the gate that keeps refusals honest.
5. [Testing and Benchmarks](Developers--Testing-and-Benchmarks) — lanes,
   fixtures, baselines, the guard tests that matter most.
6. [REST API](Developers--REST-API) — endpoint groups, SSE, Plotly JSON.

## Before your first commit

- `just ci` must pass (it is what CI runs). `CONTRIBUTING.md` has commit and
  branch conventions (the commit gate is real and grades every non-merge
  commit).
- Three invariants this fork will not trade away:
  1. **No placeholder ever returns as a result.** Unsuccessful states carry
     names; numbers carry provenance. A guard test enforces this.
  2. **Method conditions are published before implementation.** If you add a
     statistical method and there is no conditions document, you are doing it
     in the wrong order (`docs/statistics/method-conditions/`).
  3. **Never `any`, never `@ts-ignore`.** `unknown` and narrow; the two
     ambient stubs are the only exception and they are marked
     `FIXME(types)`.

## Here now vs coming (developer view)

**IN PLACE:** the Julia engine (typed stages, config cascade, DuckDB store,
REST+SSE), the analysis layer (diversity, estimation, exact summaries,
numeric policy, scaling, AnalysisConfig, epistemic), the strict-typed React
frontend, tests/benchmarks/CI, the compliance estate.

**COMING:** exact tests and the milestone-3 analysis suite (#3, #17–21) —
each gated on pre-published conditions; CladeCumulus frontend (#6); Evidence
Mode UI (#7); Zenodo integration (#8, a recoverable publication slice is in
draft PR #74); Stipple UI parity (`ui/`, `docs/migration/STATUS.md`).

**BLOCKED:** the symbolic engine (#2) — by policy, until the numeric layer
passes real-data validation. If you want formula manipulation, you want #1's
review first.
