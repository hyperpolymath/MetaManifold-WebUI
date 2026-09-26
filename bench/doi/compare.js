// SPDX-License-Identifier: MPL-2.0
// Deliberately fail closed: never manufacture a baseline or silently ignore cases.
import { readFileSync } from 'node:fs'

export function compareReports(baseline, current) {
  if (baseline.schema_version !== 1 || current.schema_version !== 1) throw new Error('Unsupported DOI benchmark report version')
  for (const key of ['julia_version', 'cpu', 'os', 'arch', 'threads', 'samples', 'payload_bytes']) {
    if (baseline[key] === undefined || baseline[key] !== current[key]) throw new Error(`Incomparable benchmark environment/workload: ${key}`)
  }
  const keys = Object.keys(baseline.metrics ?? {}).sort()
  if (!keys.length || JSON.stringify(keys) !== JSON.stringify(Object.keys(current.metrics ?? {}).sort())) throw new Error('Missing or changed benchmark cases')
  const failures = []
  for (const key of keys) {
    for (const field of ['median_ns', 'median_bytes']) {
      const before = baseline.metrics[key][field], after = current.metrics[key][field]
      if (![before, after].every(x => typeof x === 'number' && Number.isFinite(x) && x >= 0)) throw new Error(`Invalid benchmark measurement: ${key}.${field}`)
      if (after > before * 1.10) failures.push(`${key}.${field}: ${before} -> ${after} (>10% regression)`)
    }
  }
  if (failures.length) throw new Error(failures.join('\n'))
  return keys.length
}

if (import.meta.main) {
  if (process.argv.length !== 4) throw new Error('Usage: bun bench/doi/compare.js BASELINE.json CURRENT.json; generate both with bench/doi/benchmark.jl on the same controlled host')
  const [baseline, current] = process.argv.slice(2).map(path => JSON.parse(readFileSync(path, 'utf8')))
  console.log(`DOI benchmark gate passed: ${compareReports(baseline, current)} cases, time and allocation <=10% regression`)
}
