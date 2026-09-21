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
//
// Written as one table rather than five test bodies. The bodies were all
// `expect(sanitiseApiBase(x)).toBe(y)` repeated, which is duplicated code by
// token count as well as by eye -- SonarCloud measured 6.7% duplication on new
// code against a 3% limit, and it was right. A row still becomes its own named
// test below, so a failure names the exact case rather than a block of five.
const cases: ReadonlyArray<readonly [label: string, raw: unknown, expected: string]> = [
  // Absent, blank or non-string config: same outcome as a missing config.json.
  ['undefined yields same-origin', undefined, ''],
  ['null yields same-origin', null, ''],
  ['empty string yields same-origin', '', ''],
  ['whitespace-only yields same-origin', '   ', ''],
  ['a non-string yields same-origin', 42, ''],

  // A split deployment genuinely needs a cross-origin base; it must survive.
  ['a host:port base survives intact', 'https://bioserver:8080', 'https://bioserver:8080'],
  ['a bare http host survives intact', 'http://bioserver', 'http://bioserver'],

  // apiUrl concatenates, so a trailing slash here would double up in every URL.
  ['one trailing slash is stripped', 'https://bioserver:8080/', 'https://bioserver:8080'],
  ['repeated trailing slashes are stripped', 'https://bioserver:8080///', 'https://bioserver:8080'],
  ['a path prefix keeps its slash stripped', 'https://bioserver:8080/backend/', 'https://bioserver:8080/backend'],
  // 5000 trailing slashes: the case /\/+$/ backtracked on. A correctness
  // check of the replacement loop on long input, not a timing assertion.
  ['a long run of trailing slashes is stripped', 'https://bioserver:8080' + '/'.repeat(5000), 'https://bioserver:8080'],

  // The dangerous schemes: config.json is fetched at runtime, so these would
  // otherwise reach fetch() and EventSource verbatim.
  ['javascript: is refused', 'javascript:alert(1)', ''],
  ['data: is refused', 'data:text/html,<script>alert(1)</script>', ''],
  ['blob: is refused', 'blob:https://bioserver/abc', ''],
  ['file: is refused', 'file:///etc/passwd', ''],

  // Rebuilding from parsed components is what drops these, not a regex.
  ['embedded credentials are dropped', 'https://user:pass@bioserver:8080/api', 'https://bioserver:8080/api'],
  ['query and fragment are dropped', 'https://bioserver:8080/api?token=secret#frag', 'https://bioserver:8080/api'],
  ['path traversal is normalised', 'https://bioserver:8080/api/../../etc', 'https://bioserver:8080/etc'],
]

for (const [label, raw, expected] of cases) {
  test(`sanitiseApiBase: ${label}`, () => {
    expect(sanitiseApiBase(raw)).toBe(expected)
  })
}
