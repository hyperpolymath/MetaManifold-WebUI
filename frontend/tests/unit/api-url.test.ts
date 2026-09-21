// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Scaffold smoke test — api/client.ts URL building (unit battery).
// One known property per the infrastructure prompt: proves the module loads
// and its pure helper behaves. NOT domain coverage (Prompt 5+).
import { test, expect } from 'bun:test'
import { apiUrl, sanitiseApiBase } from '../../src/api/client'

test('apiUrl: same-origin paths pass through unchanged by default', () => {
  // With no loadConfig() call, _apiBase defaults to '' (same-origin), so the
  // helper is the identity on API paths.
  expect(apiUrl('/api/v1/studies')).toBe('/api/v1/studies')
})

// sanitiseApiBase is the single cleansing point for config.json's apiBase: it
// feeds _apiBase, which prefixes every fetch() in client.ts and the EventSource
// in events.ts. These cases pin the three things it must do -- reject non-HTTP
// schemes, strip credentials/query/fragment, and leave a legitimate
// cross-origin base usable.
test('sanitiseApiBase: absent or empty config yields same-origin', () => {
  expect(sanitiseApiBase(undefined)).toBe('')
  expect(sanitiseApiBase(null)).toBe('')
  expect(sanitiseApiBase('')).toBe('')
  expect(sanitiseApiBase('   ')).toBe('')
  expect(sanitiseApiBase(42)).toBe('')
})

test('sanitiseApiBase: a legitimate split-deployment base survives intact', () => {
  expect(sanitiseApiBase('https://bioserver:8080')).toBe('https://bioserver:8080')
  expect(sanitiseApiBase('http://bioserver')).toBe('http://bioserver')
})

test('sanitiseApiBase: trailing slashes are stripped so apiUrl never doubles them', () => {
  expect(sanitiseApiBase('https://bioserver:8080/')).toBe('https://bioserver:8080')
  expect(sanitiseApiBase('https://bioserver:8080///')).toBe('https://bioserver:8080')
  expect(sanitiseApiBase('https://bioserver:8080/backend/')).toBe('https://bioserver:8080/backend')
})

test('sanitiseApiBase: non-HTTP schemes are refused', () => {
  expect(sanitiseApiBase('javascript:alert(1)')).toBe('')
  expect(sanitiseApiBase('data:text/html,<script>alert(1)</script>')).toBe('')
  expect(sanitiseApiBase('blob:https://bioserver/abc')).toBe('')
  expect(sanitiseApiBase('file:///etc/passwd')).toBe('')
})

test('sanitiseApiBase: credentials, query and fragment are dropped, traversal normalised', () => {
  expect(sanitiseApiBase('https://user:pass@bioserver:8080/api')).toBe('https://bioserver:8080/api')
  expect(sanitiseApiBase('https://bioserver:8080/api?token=secret#frag')).toBe('https://bioserver:8080/api')
  expect(sanitiseApiBase('https://bioserver:8080/api/../../etc')).toBe('https://bioserver:8080/etc')
})
