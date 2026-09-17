// Scaffold smoke test — api/client.ts URL building (unit battery).
// One known property per the infrastructure prompt: proves the module loads
// and its pure helper behaves. NOT domain coverage (Prompt 5+).
import { test, expect } from 'bun:test'
import { apiUrl } from '../../src/api/client'

test('apiUrl: same-origin paths pass through unchanged by default', () => {
  // With no loadConfig() call, _apiBase defaults to '' (same-origin), so the
  // helper is the identity on API paths.
  expect(apiUrl('/api/v1/studies')).toBe('/api/v1/studies')
})
