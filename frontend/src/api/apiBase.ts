// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Validation for the two halves of every API URL the frontend builds: the
// deployment base read from config.json at startup, and the root-relative path
// a caller asks for. Both end up in fetch() and EventSource(), so neither is
// used until it has been checked here.

/**
 * Normalise the `apiBase` value from config.json.
 *
 * Returns `''` (same-origin) for an absent or empty value. Otherwise the value
 * must be an absolute `http:` or `https:` URL with no credentials, query or
 * fragment; an optional path prefix is kept, with dot segments resolved and
 * trailing slashes removed. Anything else is refused with a `TypeError`, so a
 * malformed or hostile config.json cannot point requests at another scheme or
 * smuggle userinfo into the URL.
 */
export function normaliseApiBase(raw: unknown): string {
  if (raw === undefined || raw === null) return ''
  if (typeof raw !== 'string') throw new TypeError('apiBase must be a string')
  const text = raw.trim()
  if (text === '') return ''
  let url: URL
  try {
    url = new URL(text)
  } catch {
    throw new TypeError(`apiBase is not an absolute URL: ${text}`)
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new TypeError(`apiBase must use http or https, not ${url.protocol}`)
  }
  if (url.username !== '' || url.password !== '') throw new TypeError('apiBase must not carry credentials')
  if (url.search !== '' || url.hash !== '') throw new TypeError('apiBase must not carry a query or fragment')
  return `${url.protocol}//${url.host}${url.pathname.replace(/\/+$/, '')}`
}

/**
 * Check a root-relative API path before it is joined to the base.
 *
 * The path must start with exactly one `/` and contain no backslash, control
 * character, or `.`/`..` segment (plain or percent-encoded) before its query
 * string. This keeps a caller-supplied value, such as a study name from the
 * address bar or a report URL returned by the server, from leaving the API's
 * own path space.
 */
export function checkApiPath(path: string): string {
  if (!path.startsWith('/') || path.startsWith('//')) {
    throw new TypeError(`API path must be root-relative: ${path}`)
  }
  if (/[\\\p{Cc}]/u.test(path)) throw new TypeError(`API path contains a forbidden character: ${path}`)
  const end = path.search(/[?#]/)
  const pathname = end === -1 ? path : path.slice(0, end)
  if (hasDotSegment(pathname)) throw new TypeError(`API path must not contain . or .. segments: ${path}`)
  return path
}

/** Join a validated base (from normaliseApiBase) and a path (checked here). */
export function joinApiUrl(base: string, path: string): string {
  const checked = checkApiPath(path)
  return base ? `${base}${checked}` : checked
}

function hasDotSegment(pathname: string): boolean {
  return pathname.split('/').some(segment => {
    const s = segment.toLowerCase().replace(/%2e/g, '.')
    return s === '.' || s === '..'
  })
}
