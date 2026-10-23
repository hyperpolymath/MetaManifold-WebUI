// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

/**
 * Compare two strings by UTF-16 code unit: the ordering `Array.prototype.sort`
 * applies when it is handed no comparator, written out so the intent is
 * visible at the call site.
 *
 * It exists because a comparison-less `sort()` is reported as a BUG by
 * SonarCloud's `typescript:S2871`, and the repository's required "SonarCloud
 * Code Analysis" check rates reliability on the worst bug in the changed lines:
 * one `CRITICAL` bug is rating D, and anything above A fails the gate. That is
 * a classification Sonar makes, not a severity a reviewer would recognise — the
 * compiler is perfectly happy with the bare call.
 *
 * The rule's own suggestion, `(a, b) => a.localeCompare(b)`, is NOT equivalent:
 * it applies locale collation, so `['z', 'ä'].sort(byCodeUnit)` keeps `z` first
 * while `localeCompare` moves `ä` in front of it. For a list of identifiers
 * that is a silent behaviour change, and for RFC 8785 canonicalisation it is a
 * correctness bug, so the code-unit comparison is spelled out instead.
 */
export function byCodeUnit(a: string, b: string): number {
  if (a < b) return -1
  if (a > b) return 1
  return 0
}

/**
 * Turn the contents of a multi-line textarea into a list of values: one per
 * line, trimmed, with blank lines dropped. The shape every "paste a list
 * freely" field in the app expects.
 */
export function splitLines(text: string): string[] {
  return text.split('\n').map(v => v.trim()).filter(v => v.length > 0)
}

/**
 * Strip the pseudo-HTML markup Plotly accepts in titles and axis labels (<b>,
 * <br>, <sub> and friends), leaving the bare text for measuring or for a
 * filename. A single pass is not enough: replacing "<scr<script>ipt>" once
 * removes the inner tag and leaves the halves joined into another, so the
 * strip repeats until the text stops changing.
 * Entities are not decoded and removed tags add no spacing or line breaks.
 * This is a text helper, not an HTML sanitiser.
 */
export function stripHtmlTags(text: string): string {
  let stripped = text
  let previous = ''
  do {
    previous = stripped
    stripped = stripped.replace(/<[^>]+>/g, '')
  } while (stripped !== previous)
  return stripped
}
