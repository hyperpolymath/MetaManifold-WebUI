// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { describe, expect, test } from 'bun:test'
import { byCodeUnit, splitLines, stripHtmlTags } from './text'

describe('byCodeUnit', () => {
  test('orders exactly as a comparison-less sort() does', () => {
    // The point of the helper: it is sort()'s default ordering, made explicit.
    // If it ever drifts from that default, every caller migrated off a bare
    // sort() has silently changed behaviour -- so the expected order is written
    // out in full rather than recomputed with another sort implementation.
    const values = ['b', 'A', 'a', 'B', 'Z', 'z', 'é', 'ä', '0', '_']
    expect([...values].sort(byCodeUnit))
      .toEqual(['0', 'A', 'B', 'Z', '_', 'a', 'b', 'z', 'ä', 'é'])
  })

  test('is not locale-collated, which is why localeCompare is not a substitute', () => {
    // Code units put z (U+007A) before ä (U+00E4); a locale collator does not.
    // The locale is pinned so the assertion does not depend on the runner's LANG.
    expect(['ä', 'z'].sort(byCodeUnit)).toEqual(['z', 'ä'])
    expect(['ä', 'z'].sort((a, b) => a.localeCompare(b, 'en'))).toEqual(['ä', 'z'])
  })

  test('is case-sensitive and total, so equal strings compare equal', () => {
    expect(byCodeUnit('A', 'a')).toBeLessThan(0)
    expect(byCodeUnit('a', 'A')).toBeGreaterThan(0)
    expect(byCodeUnit('same', 'same')).toBe(0)
  })
})

describe('stripHtmlTags', () => {
  test('removes the markup Plotly allows in a title', () => {
    expect(stripHtmlTags('CO<sub>2</sub> by <b>run</b>')).toBe('CO2 by run')
  })

  test('a tag hiding inside another does not survive', () => {
    expect(stripHtmlTags('<scr<script>ipt>alert(1)</script>')).not.toMatch(/<[^>]+>/)
  })

  test('text without markup, including a bare >, is unchanged', () => {
    expect(stripHtmlTags('p > 0.05 for all')).toBe('p > 0.05 for all')
  })
})

describe('splitLines', () => {
  test('one trimmed value per line, blanks dropped', () => {
    expect(splitLines(' a\n\n b \nc')).toEqual(['a', 'b', 'c'])
  })
})
