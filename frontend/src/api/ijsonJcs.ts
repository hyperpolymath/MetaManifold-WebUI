// SPDX-License-Identifier: AGPL-3.0-only
// First-party API JSON: I-JSON values in RFC 8785 canonical form. JS string
// ordering is UTF-16 code-unit ordering, as required by JCS (unlike UTF-8).
// This deliberately doesn't canonicalise external jplace/Plotly documents.

function validString(value: string): void {
  for (let i = 0; i < value.length; i++) {
    const code = value.codePointAt(i)!
    if (code > 0xffff) i++ // a valid UTF-16 surrogate pair
    else if (code >= 0xd800 && code <= 0xdfff) throw new TypeError('I-JSON refuses unpaired surrogates')
    if ((code >= 0xfdd0 && code <= 0xfdef) || (code & 0xfffe) === 0xfffe) {
      throw new TypeError('I-JSON refuses Unicode noncharacters')
    }
  }
}

// JCS sorts UTF-16 code units, NOT human-language collation (localeCompare).
const compareUtf16 = (a: string, b: string): number => a < b ? -1 : a > b ? 1 : 0

/** Canonicalise a JSON-shaped API payload; reject values that cannot round-trip. */
export function ijsonJcsStringify(value: unknown): string {
  const active = new Set<object>()
  function encode(input: unknown): string {
    if (input === null) return 'null'
    if (typeof input === 'string') { validString(input); return JSON.stringify(input) }
    if (typeof input === 'boolean') return String(input)
    if (typeof input === 'number') {
      if (!Number.isFinite(input) || (Number.isInteger(input) && !Number.isSafeInteger(input))) {
        throw new TypeError('I-JSON refuses non-finite or unsafe numbers; use a decimal string for exact counts')
      }
      return JSON.stringify(input)
    }
    if (typeof input !== 'object') throw new TypeError(`Not an I-JSON value: ${typeof input}`)
    if (active.has(input)) throw new TypeError('Cyclic JSON value')
    if (!Array.isArray(input) && Object.getPrototypeOf(input) !== Object.prototype && Object.getPrototypeOf(input) !== null) {
      throw new TypeError('I-JSON objects must be plain objects')
    }
    active.add(input)
    try {
      if (Array.isArray(input)) {
        return `[${Array.from({ length: input.length }, (_, i) => {
          if (!(i in input)) throw new TypeError('I-JSON refuses sparse arrays')
          return encode(input[i])
        }).join(',')}]`
      }
      const object = input as Record<string, unknown>
      // Omit undefined optional properties just as JSON.stringify does, but
      // never convert an undefined array element into null silently.
      return `{${Object.keys(object).sort(compareUtf16).filter(key => object[key] !== undefined).map(key => {
        validString(key)
        return `${JSON.stringify(key)}:${encode(object[key])}`
      }).join(',')}}`
    } finally {
      active.delete(input)
    }
  }
  return encode(value)
}
