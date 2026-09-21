// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/api/index.ts — public facade for every REST boundary type.
//
// Endpoint → source map (Julia server route files):
//   /api/v1/studies*, /api/v1/db                        src/server/routes/studies.jl, config.jl
//   /api/v1/studies/*/runs*, runs/pipeline              src/server/routes/runs.jl, pipeline.jl
//   /api/v1/studies/*/runs/*/results/**, filters/presets src/server/routes/results.jl
//   /api/v1/config*, /api/v1/primers*                    src/server/routes/config.jl
//   /api/v1/jobs*, /api/v1/events (SSE)                  src/server/routes/jobs.jl, events.jl
//   /api/v1/analysis*, charts, chart-cosmetics           src/server/routes/analysis.jl
//   /api/v1/annotations*, /api/v1/contamination          src/server/routes/annotations.jl
//   /api/v1/compositions*, /api/v1/category-sets         src/server/routes/composition.jl
//   /api/v1/databases*, composition libraries            src/server/routes/databases.jl
//
// Canonical response/request interfaces live in `src/api/types.ts` (upstream
// location; moving them is out of scope). The leaf files here own the
// boundary details that file previously left as tracked placeholders.
export * from './tables'
export * from './cosmetics'
export * from '../../api/types'
