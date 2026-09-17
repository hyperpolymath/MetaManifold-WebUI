// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Type-boundary tests — DOM-free component contracts.
//
// Boundary under test: the three components callable without a DOM (no hooks
// in their bodies), exercised through their *observable* props→element
// contract. React element descriptors are plain data: calling a hook-free
// function component returns the descriptor tree without rendering, and a
// class component's statics/state are callable directly. This tests render
// OUTPUT, not React internals; hooks-bearing components stay in the e2e lane
// (see tests/unit/plotly-chain.todo.test.ts and docs/testing/coverage.md).
import { describe, test, expect } from 'bun:test'
import type { ReactElement, ReactNode } from 'react'
import { Skeleton } from '../../src/components/Skeleton'
import { ErrorBoundary } from '../../src/components/ErrorBoundary'
import { NotFoundView } from '../../src/views/NotFoundView'

// Descriptor-tree helpers: dig into props.children without rendering.
const children = (el: ReactElement | ReactNode): unknown =>
  (el as ReactElement | null)?.props?.children

describe('Skeleton — lines contract', () => {
  test('renders exactly `lines` skeleton lines, defaulting to 3', () => {
    // Arrange/Act: descriptors only — observable contract is the child count.
    const explicit = Skeleton({ lines: 5 })
    expect(Array.isArray(children(explicit))).toBe(true)
    expect((children(explicit) as unknown[]).length).toBe(5)
    const def = Skeleton({})
    expect((children(def) as unknown[]).length).toBe(3)
  })

  test('line widths cycle through the fixed pattern (wraps past the pattern)', () => {
    const el = Skeleton({ lines: 6 })
    const widths = (children(el) as ReactElement[]).map(
      (c) => (c.props as { style?: { width?: string } }).style?.width,
    )
    expect(widths).toEqual(['60%', '80%', '45%', '70%', '55%', '60%'])
  })

  test('extra lines produce a stable class per line', () => {
    const el = Skeleton({ lines: 2 })
    for (const c of children(el) as ReactElement[]) {
      expect((c.props as { className?: string }).className).toBe('skeleton-line')
    }
  })
})

describe('ErrorBoundary — error-state contract', () => {
  test('fresh instance starts error-free and renders children straight through', () => {
    // Arrange
    const boundary = new ErrorBoundary({ children: 'payload' })
    // Assert: no error → observable output is exactly the props children
    // (getDerivedStateFromError has not run).
    expect(boundary.state.error).toBeNull()
    expect(boundary.render()).toBe('payload')
  })

  test('getDerivedStateFromError stores the Error object, not a string copy', () => {
    const error = new Error('kaboom')
    const next = ErrorBoundary.getDerivedStateFromError(error)
    expect(next.error).toBe(error)
  })

  test('in the error state, render surfaces the message inside a recovery box', () => {
    // Arrange: reach the error state through the public static, as React does.
    const boundary = new ErrorBoundary({ children: 'payload' })
    const next = ErrorBoundary.getDerivedStateFromError(new Error('kaboom'))
    boundary.state = next
    // Act
    const el = boundary.render() as ReactElement
    // Assert: the fallback replaces children and exposes a retry control —
    // asserted by walking the descriptor, not by rendering.
    const parts = children(el) as ReactElement[]
    const headings = parts.map((p) => p?.type)
    expect(headings).toEqual(['h2', 'pre', 'button'])
    expect(children(parts[0] as ReactElement)).toBe('Something went wrong')
    expect(children(parts[1] as ReactElement)).toBe('kaboom')
    expect(children(parts[2] as ReactElement)).toBe('Try again')
  })
})

describe('NotFoundView — static 404 contract', () => {
  test('renders the 404 copy and a link back to /studies', () => {
    const el = NotFoundView()
    const parts = children(el) as ReactElement[]
    const texts = parts.map((p) => children(p))
    expect(texts[0]).toBe('404')
    expect(texts[1]).toBe("This page doesn't exist.")
    // The recovery affordance is a Link descriptor to the studies home —
    // the element factory never mounts the router, so the descriptor holds
    // the `to` prop we assert on.
    const link = parts[2] as ReactElement
    expect((link.props as { to?: string }).to).toBe('/studies')
    expect(children(link)).toBe('Back to Studies')
  })
})
