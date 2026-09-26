// SPDX-License-Identifier: MPL-2.0
import { test, expect } from 'bun:test'
import { compareReports } from '../../bench/doi/compare.js'

const report = (time = 100, bytes = 100) => ({
  schema_version: 1, julia_version: '1.12.5', cpu: 'fixture', os: 'Linux', arch: 'x86_64',
  threads: 1, samples: 31, payload_bytes: 8388608,
  metrics: { fixture: { median_ns: time, median_bytes: bytes } },
})

test('performance comparator permits improvements and exactly 10%, rejects >10% in either metric', () => {
  expect(compareReports(report(), report(90, 80))).toBe(1)
  expect(compareReports(report(), report(110, 110))).toBe(1)
  expect(() => compareReports(report(), report(111))).toThrow('>10% regression')
  expect(() => compareReports(report(), report(100, 111))).toThrow('>10% regression')
  expect(() => compareReports(report(0, 0), report(0, 1))).toThrow('>10% regression')
})

test('a missing case, nonfinite measurement or different host cannot create a vacuous benchmark pass', () => {
  expect(() => compareReports({}, report())).toThrow('Unsupported')
  expect(() => compareReports(report(), { ...report(), metrics: {} })).toThrow('Missing')
  expect(() => compareReports(report(), { ...report(), cpu: 'different' })).toThrow('Incomparable')
  expect(() => compareReports(report(), report(Number.NaN))).toThrow('Invalid')
  expect(() => compareReports(report(), report(-1))).toThrow('Invalid')
})
