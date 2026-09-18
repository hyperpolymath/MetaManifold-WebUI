// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Reflexive gate self-tests — the hygiene gates must prove they can FAIL.
//
// Category (standards/testing-and-benchmarking/TESTING-TAXONOMY.adoc):
//   Reflexive / self-test. Doctrine (proven-tests-and-benches
//   TEST-DOCTRINE.adoc): a check that cannot fail is not a check. Each gate
//   script is executed UNMODIFIED against a throwaway git repo seeded from
//   on-disk silence payloads (harness/payload separation: payload files live
//   in tests/fixtures/gates/, this file is the harness). Firing variants are
//   produced by deterministic mutation at run time, so the real repo's own
//   gates never see a poisoned payload file.
import { describe, test, expect, afterAll } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dir, '../../..')
const SILENCE = readFileSync(join(import.meta.dir, '../fixtures/gates/spdx-silence.txt'), 'utf8')

const tmpDirs: string[] = []
afterAll(() => { for (const d of tmpDirs) rmSync(d, { recursive: true, force: true }) })

// Build a one-payload git repo containing an unmodified copy of the gate
// script, then run the gate inside it. Returns { rc, out }.
function runGate(scriptRel: string, payload: string): { rc: number; out: string } {
  const dir = mkdtempSync(join(tmpdir(), 'gate-'))
  tmpDirs.push(dir)
  mkdirSync(join(dir, 'scripts'))
  copyFileSync(join(ROOT, scriptRel), join(dir, 'scripts', scriptRel.split('/').pop() ?? 'gate.sh'))
  writeFileSync(join(dir, 'payload.ts'), payload)
  const init = spawnSync('git', ['init', '-q'], { cwd: dir })
  expect(init.status).toBe(0)
  const add = spawnSync('git', ['add', '-A'], { cwd: dir })
  expect(add.status).toBe(0)
  const run = spawnSync('bash', [join(dir, 'scripts', scriptRel.split('/').pop() ?? 'gate.sh')], {
    cwd: dir, timeout: 30_000, encoding: 'utf8',
  })
  return { rc: run.status ?? -1, out: `${run.stdout}${run.stderr}` }
}

describe('reflexive: check-spdx.sh can both stay silent and fire', () => {
  test('silence: a payload with a valid header passes', () => {
    const { rc } = runGate('scripts/check-spdx.sh', SILENCE)
    expect(rc).toBe(0)
  })

  test('firing: a payload with NO header fails with MISSING-SPDX', () => {
    const fired = SILENCE.split('\n').slice(2).join('\n')
    const { rc, out } = runGate('scripts/check-spdx.sh', fired)
    expect(rc).toBe(1)
    expect(out).toContain('MISSING-SPDX')
  })

  test('firing: a payload with a disallowed identifier fails with BAD-IDENTIFIER', () => {
    const fired = SILENCE.replace('MPL-2.0', 'MIT')
    const { rc, out } = runGate('scripts/check-spdx.sh', fired)
    expect(rc).toBe(1)
    expect(out).toContain('BAD-IDENTIFIER')
  })

  test('firing: a payload stacking two identifiers fails with DUPLICATE-SPDX', () => {
    const fired = '// SPDX-License-Identifier: MPL-2.0\n' + SILENCE
    const { rc, out } = runGate('scripts/check-spdx.sh', fired)
    expect(rc).toBe(1)
    expect(out).toContain('DUPLICATE-SPDX')
  })
})

describe('reflexive: check-format.sh can both stay silent and fire', () => {
  test('silence: a whitespace-clean payload passes', () => {
    const { rc } = runGate('scripts/check-format.sh', SILENCE)
    expect(rc).toBe(0)
  })

  test('firing: trailing whitespace fails the gate', () => {
    const fired = SILENCE + 'const hostile = true  \n'
    const { rc } = runGate('scripts/check-format.sh', fired)
    expect(rc).toBe(1)
  })
})
