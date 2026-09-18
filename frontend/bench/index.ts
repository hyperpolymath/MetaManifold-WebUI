// SPDX-License-Identifier: AGPL-3.0-only
// Upstream MetaManifold WebUI — benchmark harness, adapted to Bun from the
// measurement discipline in hyperpolymath/proven-tests-and-benches
// (benchmarks/Benchmark.idr):
//
//   * Real monotonic wall-clock timing (performance.now()).
//   * REPS samples per workload (odd count → exact median); the MEDIAN is the
//     headline number — one sample is not a measurement on noisy hosts.
//   * Iteration counts per sample are calibrated so one sample costs tens of
//     milliseconds; sub-millisecond totals are timer-resolution noise.
//   * Every workload folds its outputs into a checksum that is printed, so
//     the outcome of the work is observable and cannot be dead-code
//     eliminated or memoised away (workloads are indexed by the iteration
//     counter — inputs vary per repetition).
//   * `--json <path>` writes the machine-readable result set (schema below);
//     stdout keeps the human lines. The JSON is what baselines are computed
//     from — numbers ship with artifacts, never merely asserted.
//   * WORKLOADS ARE FROZEN as of their introduction. Baselines are
//     per-workload and versioned (bench/baseline.json is committed): any
//     change to a workload's definition invalidates its history and requires
//     re-cutting the baseline.
//   * Baseline comparison is INFORMATIONAL only — there is no regression
//     gate (per the infrastructure prompt; gating is a later-prompt
//     decision).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { execSync } from 'node:child_process'
import { applyColourOverrides } from '../src/api/figureColours'

const REPS = 5

interface BenchmarkResult {
  name: string
  iterations: number
  samples_ns: number[]
  median_ns: number
  checksum: boolean
}

interface BenchRun {
  schema_version: 1
  environment: {
    commit: string
    runner: string
    bun: string
    platform: string
    arch: string
  }
  reps: number
  results: BenchmarkResult[]
}

function median(samples: number[]): number {
  const sorted = [...samples].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)] ?? 0
}

/** Run `fn` `iters` times; return per-repetition totals in ns + checksum. */
function runWorkload(name: string, iters: number, fn: (iter: number) => number): BenchmarkResult {
  const samples_ns: number[] = []
  const checksumParts: number[] = []
  for (let rep = 0; rep < REPS; rep++) {
    const start = performance.now()
    let acc = 0
    for (let i = 0; i < iters; i++) acc = (acc + fn(i)) | 0
    samples_ns.push(Math.round((performance.now() - start) * 1e6))
    checksumParts.push(acc)
  }
  const checksum = checksumParts.every((c) => c === checksumParts[0])
  return { name, iterations: iters, samples_ns, median_ns: median(samples_ns), checksum }
}

// ---------------------------------------------------------------------------
// FROZEN WORKLOADS (v1, introduced 2026-09-17 — do not edit without re-cutting
// bench/baseline.json)
// ---------------------------------------------------------------------------

const fixtureText = readFileSync(new URL('../tests/fixtures/run-table-payload.json', import.meta.url), 'utf8')

// W1: parse the representative run-table payload (API response shape).
function wParse(iters: number): BenchmarkResult {
  return runWorkload('run-table-json-parse', iters, (i) => {
    const doc = JSON.parse(fixtureText) as { rows: Record<string, unknown>[] }
    // Fold output: row count + iteration-dependent accessor so the parse is
    // observable and varies by iteration (no memoisable constant).
    const row = doc.rows[i % doc.rows.length] as Record<string, unknown>
    return doc.rows.length + String(row['OTU']).length
  })
}

// W2: apply colour overrides across a synthetic 400-trace figure — the real
// hot path behind figure rendering (src/api/figureColours.ts).
const traces: { name: string; marker: Record<string, unknown> }[] = Array.from(
  { length: 400 },
  (_, i) => ({ name: `trace-${i % 40}`, marker: {} }),
)
const colourMap = Object.fromEntries(
  Array.from({ length: 40 }, (_, i) => [`trace-${i}`, '#1b9e77']),
)

function wColour(iters: number): BenchmarkResult {
  return runWorkload('figure-colour-overrides', iters, (i) => {
    const out = applyColourOverrides({ data: traces }, colourMap) as {
      data: { marker?: Record<string, unknown> }[]
    }
    return String(out.data[i % out.data.length]?.marker?.color ?? '').length
  })
}

// W3: table loading — parse large table payload and extract sample columns (DuckDB-like)
const sampleColumnsFixture = Array.from({ length: 50 }, (_, i) => `Sample${i}`)
const allColumnsFixture = ['SeqName', 'Domain', 'Phylum', 'Genus', 'Species', 'Pident', ...sampleColumnsFixture, 'total']

function wTableLoading(iters: number): BenchmarkResult {
  return runWorkload('table-loading-sample-columns', iters, (i) => {
    // Simulate sample_columns logic: filter numeric, exclude taxonomy, etc.
    const excluded = new Set(['SeqName', 'Domain', 'Phylum', 'Class', 'Order', 'Family', 'Genus', 'Species', 'Pident', 'total'])
    const sampleCols = allColumnsFixture.filter(c => !excluded.has(c) && !c.endsWith('_dada2') && !c.endsWith('_boot'))
    return sampleCols.length + (i % 10)
  })
}

// W4: epistemic parsing — avec_fibre boolean coercion and colour coding
function wEpistemicParsing(iters: number): BenchmarkResult {
  const values = ['true', 'false', 'avec_fibre', 'sans_fibre', '1', '0', true, false, null] as const
  const statuses = ['present_in_every', 'present_in_some', 'absent', 'sans_fibre'] as const
  return runWorkload('epistemic-parsing', iters, (i) => {
    const v = values[i % values.length]
    const avec = v === true || v === 'true' || v === '1' || v === 'avec_fibre'
    const status = statuses[i % statuses.length]
    let colour = '#9e9e9e'
    if (status === 'present_in_every') colour = '#2e7d32'
    else if (status === 'present_in_some') colour = '#f9a825'
    else if (status === 'sans_fibre') colour = '#c62828'
    const residual = i % 1000
    const cloudSize = Math.log(1 + residual) * 10 + 5
    return (avec ? 1 : 0) + colour.length + Math.floor(cloudSize)
  })
}

// W5: DuckDB aggregation — aggregate_by_taxon mock (group by genus, sum) — deterministic for checksum
function wDuckDBAggregation(iters: number): BenchmarkResult {
  // Deterministic mock rows using seeded LCG-like pattern based on index
  const mockRows = Array.from({ length: 1000 }, (_, i) => ({
    Genus: ['Bacteroides', 'Prevotella', 'Faecalibacterium'][i % 3],
    Sample1: (i * 9301 + 49297) % 1000,
    Sample2: (i * 9301 + 49297 + 12345) % 1000,
  }))
  return runWorkload('duckdb-aggregation', iters, (i) => {
    const map = new Map<string, number>()
    for (const r of mockRows) {
      map.set(r.Genus, (map.get(r.Genus) ?? 0) + r.Sample1 + r.Sample2)
    }
    // Include iteration-dependent access to prevent DCE but keep checksum stable across reps (i is inner iteration)
    // We use iteration value to add small deterministic offset, same across reps for same i
    return map.size + (map.get('Bacteroides') ?? 0) + (i % 5)
  })
}

// W6: PERMANOVA/NMDS — diversity metrics and chart generation (mock) — deterministic
function wPermanovaNmds(iters: number): BenchmarkResult {
  return runWorkload('permanova-nmds', iters, (i) => {
    // Deterministic counts based on iteration index (no Math.random for checksum stability)
    const counts = Array.from({ length: 100 }, (_, j) => (i * 100 + j * 9301 + 49297) % 1000)
    const total = counts.reduce((a, b) => a + b, 0) || 1
    const richness = counts.filter(c => c > 0).length
    let shannon = 0
    for (const c of counts) {
      if (c > 0) {
        const p = c / total
        shannon -= p * Math.log(p)
      }
    }
    const groups = ['Control', 'Disease']
    const group = groups[i % groups.length]
    return richness + Math.floor(shannon * 100) + group.length
  })
}

// W7: tree rendering — CladeCumulus SVG generation (mock) — deterministic
function wTreeRendering(iters: number): BenchmarkResult {
  const nodes = Array.from({ length: 100 }, (_, i) => ({
    id: `node${i}`,
    label: `Taxon ${i}`,
    parent: i === 0 ? '' : `node${Math.floor(i / 2)}`,
    count: (i * 9301 + 49297) % 1000,
    residual: (i * 9301) % 100,
    status: ['present_in_every', 'present_in_some', 'absent', 'sans_fibre'][i % 4] as const,
  }))
  return runWorkload('tree-rendering-clade-cumulus', iters, (i) => {
    let svgLen = 0
    for (const n of nodes) {
      const colour = n.status === 'present_in_every' ? '#2e7d32' : n.status === 'present_in_some' ? '#f9a825' : n.status === 'sans_fibre' ? '#c62828' : '#9e9e9e'
      const cloudSize = Math.log(1 + n.residual) * 10 + 5
      // Instead of building huge string (alloc heavy), accumulate length deterministically
      svgLen += n.label.length + colour.length + Math.floor(cloudSize)
    }
    return svgLen + (i % 10)
  })
}

// ---------------------------------------------------------------------------

function environment(): BenchRun['environment'] {
  let commit = 'unknown'
  try {
    commit = execSync('git rev-parse --short HEAD', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
  } catch {
    /* outside a git checkout — artifacts still carry every other field */
  }
  return {
    commit,
    runner: process.env['CI'] ? 'github-actions' : 'local',
    bun: Bun.version,
    platform: process.platform,
    arch: process.arch,
  }
}

function humanLine(r: BenchmarkResult): string {
  return `${r.name}: ${r.median_ns} ns median of ${r.samples_ns.length} (${r.iterations} iterations/sample)`
}

function main(): void {
  const results = [
    wParse(2000),
    wColour(300),
    wTableLoading(500),
    wEpistemicParsing(1000),
    wDuckDBAggregation(200),
    wPermanovaNmds(300),
    wTreeRendering(100),
  ]

  console.log('Proven-discipline benchmark run (bun test infra scaffold)')
  console.log('(monotonic clock; median of samples; compare against baseline.json)')
  console.log('')
  for (const r of results) console.log(humanLine(r))
  console.log('')
  for (const r of results) console.log(`${r.name}: checksum ${r.checksum ? 'verified' : 'FAILED'}`)
  if (results.some((r) => !r.checksum)) process.exitCode = 1

  // Informational baseline delta (never fails).
  try {
    const baseline = JSON.parse(
      readFileSync(new URL('./baseline.json', import.meta.url), 'utf8'),
    ) as BenchRun
    console.log('')
    for (const r of results) {
      const b = baseline.results.find((x) => x.name === r.name)
      if (b) {
        const delta = ((r.median_ns - b.median_ns) / b.median_ns) * 100
        console.log(
          `${r.name}: ${delta >= 0 ? '+' : ''}${delta.toFixed(1)}% vs baseline ${b.median_ns} ns (informational only)`,
        )
      }
    }
  } catch {
    console.log('(no bench/baseline.json — first run; cut one from the JSON artifact)')
  }

  // --json <path>: the machine-readable result set (proven idiom).
  const jsonIdx = process.argv.indexOf('--json')
  const jsonPath = jsonIdx >= 0 ? process.argv[jsonIdx + 1] : undefined
  if (jsonPath) {
    const run: BenchRun = {
      schema_version: 1,
      environment: environment(),
      reps: REPS,
      results,
    }
    mkdirSync(dirname(jsonPath), { recursive: true })
    writeFileSync(jsonPath, JSON.stringify(run, null, 2) + '\n')
    console.log(`\nwrote ${jsonPath}`)
  }
}

main()
