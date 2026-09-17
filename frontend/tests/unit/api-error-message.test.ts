// Type-boundary tests — api/errorMessage.ts.
//
// Boundary under test: `errorMessage(err: unknown, fallback?)` is the single
// narrowing point for caught values across the UI. Because the catch-path is
// `unknown` (never `any`), every consumer depends on this parser honouring
// the declared contract: Error → its message, string → itself, anything else
// → the fallback. Losing this contract means raw objects render as
// "[object Object]" in user-visible banners.
import { describe, test, expect } from 'bun:test'
import { errorMessage } from '../../src/api/errorMessage'

describe('errorMessage — unknown catch-value narrowing', () => {
  test('Error instances yield their message, including subclass messages', () => {
    // Arrange/Act/Assert grouped by one concept: the Error branch.
    expect(errorMessage(new Error('boom'))).toBe('boom')
    expect(errorMessage(new TypeError('type boom'))).toBe('type boom')
    // An error carrying the api-client payload still surfaces its message.
    const apiThrown = Object.assign(new Error('run not found'), { status: 404 })
    expect(errorMessage(apiThrown)).toBe('run not found')
  })

  test('raw strings pass through (fetch wrappers throw strings upstream)', () => {
    expect(errorMessage('plain failure')).toBe('plain failure')
    expect(errorMessage('')).toBe('')
  })

  test('parameterised non-Error values all collapse to the fallback', () => {
    const malformed = [null, undefined, 42, { message: 'object, not Error' }, ['boom'], Symbol('x')]
    for (const value of malformed) {
      expect(errorMessage(value, 'fallback-x')).toBe('fallback-x')
    }
  })

  test('the default fallback applies when none is given', () => {
    expect(errorMessage(null)).toBe('Unknown error')
    expect(errorMessage({})).toBe('Unknown error')
  })
})
