// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import { expect, test } from 'bun:test'
import { checkApiPath, joinApiUrl, normaliseApiBase } from './apiBase'

test('an absent or empty apiBase means same-origin', () => {
  expect(normaliseApiBase(undefined)).toBe('')
  expect(normaliseApiBase(null)).toBe('')
  expect(normaliseApiBase('')).toBe('')
  expect(normaliseApiBase('   ')).toBe('')
})

test('an http(s) apiBase is kept, with trailing slashes removed', () => {
  expect(normaliseApiBase('https://bioserver:8080')).toBe('https://bioserver:8080')
  expect(normaliseApiBase('https://bioserver:8080///')).toBe('https://bioserver:8080')
  expect(normaliseApiBase('http://127.0.0.1:8080/')).toBe('http://127.0.0.1:8080')
  expect(normaliseApiBase('https://example.org/metamanifold/')).toBe('https://example.org/metamanifold')
  // Dot segments are resolved by URL parsing, not passed on.
  expect(normaliseApiBase('https://example.org/a/../b/')).toBe('https://example.org/b')
  expect(normaliseApiBase('https://example.org/%2e%2e/b')).toBe('https://example.org/b')
  // Default ports are dropped by URL parsing, which is the same origin.
  expect(normaliseApiBase('https://example.org:443')).toBe('https://example.org')
})

test('an apiBase that is not a plain http(s) location is refused', () => {
  for (const bad of [
    'javascript:alert(1)',
    'data:text/plain,x',
    'file:///etc/passwd',
    'ftp://example.org',
    '//example.org',
    '/relative',
    'example.org',
    'https://user:pass@example.org',
    'https://user@example.org',
    'https://example.org/?x=1',
    'https://example.org/#frag',
  ]) {
    expect(() => normaliseApiBase(bad)).toThrow(TypeError)
  }
  expect(() => normaliseApiBase(42)).toThrow(TypeError)
  expect(() => normaliseApiBase({ href: 'https://example.org' })).toThrow(TypeError)
})

test('root-relative API paths pass through unchanged', () => {
  for (const ok of [
    '/api/v1/events',
    '/api/v1/studies/my-study/runs/run.1/qc/report.html',
    '/api/v1/studies/a..b',
    '/api/v1/tables?group=a/../b',
    '/api/v1/x#..',
  ]) {
    expect(checkApiPath(ok)).toBe(ok)
  }
})

test('API paths that would leave the API path space are refused', () => {
  for (const bad of [
    'api/v1/events',
    'https://evil.example/api',
    '//evil.example/api',
    '/api/v1/studies/../../admin',
    '/api/v1/studies/%2E%2E/admin',
    '/api/v1/studies/%2e./admin',
    '/api/v1/./events',
    '/api\\v1',
    '/api/v1/\nevents',
    '',
  ]) {
    expect(() => checkApiPath(bad)).toThrow(TypeError)
  }
})

test('joinApiUrl prefixes the base only when there is one', () => {
  expect(joinApiUrl('', '/api/v1/events')).toBe('/api/v1/events')
  expect(joinApiUrl('https://bioserver:8080', '/api/v1/events')).toBe('https://bioserver:8080/api/v1/events')
  expect(() => joinApiUrl('https://bioserver:8080', '//evil.example')).toThrow(TypeError)
})
