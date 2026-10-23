import { expect, test } from 'bun:test'
import { ijsonJcsStringify as jcs } from './ijsonJcs'

test('JCS sorts by UTF-16 code units recursively and preserves array order', () => {
  expect(jcs({ b: 1, a: { z: 1, x: [3, 2] }, 'Ａ': 4, '😀': 5 }))
    .toBe('{"a":{"x":[3,2],"z":1},"b":1,"😀":5,"Ａ":4}')
  // Numeric-like keys are sorted too, unlike JSON.stringify's object enumeration.
  expect(jcs({ '10': 1, '2': 2 })).toBe('{"10":1,"2":2}')
  expect(jcs({ optional: undefined, exact: '9007199254740992' })).toBe('{"exact":"9007199254740992"}')
})

test('ECMAScript number formatting and escaped controls match JCS', () => {
  expect(jcs({ a: -0, b: 1e-7, c: 1e-6, d: '\n' }))
    .toBe('{"a":0,"b":1e-7,"c":0.000001,"d":"\\n"}')
})

test('I-JSON rejects unsafe and non-finite numbers, noncharacters and lone surrogates', () => {
  for (const value of [Number.MAX_SAFE_INTEGER + 1, NaN, Infinity, -Infinity]) {
    expect(() => jcs({ count: value })).toThrow()
  }
  for (const text of ['\ud800', '\udc00', '\ufdd0', '\uffff', '\u{1ffff}']) {
    expect(() => jcs({ text })).toThrow()
    expect(() => jcs({ [text]: 1 })).toThrow()
  }
  expect(() => jcs({ a: [undefined] })).toThrow()
  expect(() => jcs(new Array(1))).toThrow()
  const cycle: { self?: unknown } = {}
  cycle.self = cycle
  expect(() => jcs(cycle)).toThrow()
})
