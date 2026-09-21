// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Scaffold smoke test — api client wiring against a stubbed fetch
// (integration battery). Verifies the request path end-to-end in-process:
// URL shape, HTTP method, response parsing. The backend is NOT contacted —
// the module is unchanged, fetch is replaced for the duration of the run.
import { test, expect, beforeEach, afterEach } from 'bun:test'
import { api } from '../../src/api/client'

const PAYLOAD = {
  page: 1,
  per_page: 25,
  columns: ['OTU', 'S1_r1'],
  sample_count_columns: ['S1_r1'],
  rows: [{ OTU: 'OTU_1', S1_r1: 42 }],
}

const realFetch = globalThis.fetch
let lastRequest: { url: string; init: RequestInit } | undefined

beforeEach(() => {
  lastRequest = undefined
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    lastRequest = { url: String(url), init: init ?? {} }
    return new Response(JSON.stringify(PAYLOAD), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  }) as typeof fetch
})

afterEach(() => {
  globalThis.fetch = realFetch
})

test('api.results.runTables: GETs the run tables list endpoint', async () => {
  await api.results.runTables('study-a', 'run-1')
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/runs/run-1/results/tables')
  // Plain GET: the client passes no explicit method for list calls.
  expect(lastRequest?.init.method).toBeUndefined()
})

test('api.config.patchStudy: PATCHes the study config path with a JSON body', async () => {
  await api.config.patchStudy('study-a', { some: 'body' })
  expect(lastRequest?.init.method).toBe('PATCH')
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/config')
})

// ===== Prompt 5: boundary behaviour beyond the smoke scaffolds =============
// Contracts: HTTP error semantics, optional body fields, query-string
// encoding, group parameter encoding, and TableQuery pass-through — all
// observable through the stubbed wire.

test('error responses reject with the server message and numeric status', async () => {
  // Arrange: 404 with a JSON {error, message} body (the ApiError contract).
  globalThis.fetch = (async () =>
    new Response(JSON.stringify({ error: 'not_found', message: 'run missing' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
    })) as typeof fetch
  // Act + Assert: the thrown value must surface message + status so the UI
  // can render and branch on both.
  try {
    await api.studies.get('ghost')
    throw new Error('should have rejected')
  } catch (e) {
    const err = e as Error & { status?: number }
    expect(err.message).toBe('run missing')
    expect(err.status).toBe(404)
  }
})

test('unparseable error bodies fall back to the HTTP status text', async () => {
  globalThis.fetch = (async () =>
    new Response('<html>proxy error</html>', {
      status: 502,
      statusText: 'Bad Gateway',
    })) as typeof fetch
  try {
    await api.studies.list()
    throw new Error('should have rejected')
  } catch (e) {
    const err = e as Error & { status?: number }
    expect(err.message).toBe('Bad Gateway')
    expect(err.status).toBe(502)
  }
})

test('the group parameter is URI-encoded and omitted when empty/null', async () => {
  // One concept: gq() encodes only real groups.
  await api.results.runTables('study-a', 'run-1', 'soil batch/2')
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/runs/run-1/results/tables?group=soil%20batch%2F2')
  await api.results.runTables('study-a', 'run-1', null)
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/runs/run-1/results/tables')
  await api.results.runTables('study-a', 'run-1', '')
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/runs/run-1/results/tables')
})

test('results.runTable passes the TableQuery through as the JSON body verbatim', async () => {
  // Boundary: TableQuery (page/perPage/filter/colFilters per src/api/types.ts)
  // must reach the wire untouched — the server owns query semantics.
  const q = {
    page: 2,
    perPage: 50,
    filter: 'fungi',
    sortBy: 'S1_r1',
    sortDir: 'desc' as const,
    colFilters: {
      Genus: { include: ['Malassezia', 'Candida'] },
      S1_r1: { min: 10, max: 999 },
    },
  }
  await api.results.runTable('study-a', 'run-1', 'merged', q)
  expect(lastRequest?.init.method).toBe('POST')
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/runs/run-1/results/tables/merged/query')
  expect(JSON.parse(String(lastRequest?.init.body))).toEqual(q)
})

test('distinctValues emits only present optional fields (never explicit undefined)', async () => {
  // exactOptionalPropertyTypes discipline verified at the boundary: absent
  // optionals must be ABSENT in the serialised body, not null/undefined.
  await api.results.distinctValues('study-a', 'run-1', 'merged', 'Genus')
  const bare = JSON.parse(String(lastRequest?.init.body)) as Record<string, unknown>
  expect(bare).toEqual({})
  expect('colFilters' in bare).toBe(false)
  expect('filter' in bare).toBe(false)
  await api.results.distinctValues('study-a', 'run-1', 'merged', 'Genus', { Genus: { text: 'mal' } }, null, 'mal')
  const full = JSON.parse(String(lastRequest?.init.body)) as Record<string, unknown>
  expect(full).toEqual({ colFilters: { Genus: { text: 'mal' } }, filter: 'mal' })
  // And the column segment lands in the URL path.
  expect(lastRequest?.url).toBe('/api/v1/studies/study-a/runs/run-1/results/tables/merged/distinct/Genus')
})

test('jobs.list builds the query string only from supplied options', async () => {
  await api.jobs.list()
  expect(lastRequest?.url).toBe('/api/v1/jobs')
  // Parameterised over the two supported filters.
  for (const [opts, expected] of [
    [{ study: 'study-a' }, '/api/v1/jobs?study=study-a'],
    [{ status: 'running' as const }, '/api/v1/jobs?status=running'],
    [{ study: 'study-a', status: 'failed' as const }, '/api/v1/jobs?study=study-a&status=failed'],
  ] as const) {
    await api.jobs.list(opts)
    expect(lastRequest?.url).toBe(expected)
  }
})

test('successful table responses parse into the TablePage shape with rows intact', async () => {
  // The declared rows contract (TableRow[]: Record<string, TableCell>) must
  // survive the wire: no coercion, no key rewriting.
  const page = await api.results.runTable('study-a', 'run-1', 'merged', { page: 1, perPage: 25 })
  expect(page.rows).toEqual([{ OTU: 'OTU_1', S1_r1: 42 }])
  expect(page.sample_count_columns).toEqual(['S1_r1'])
})
