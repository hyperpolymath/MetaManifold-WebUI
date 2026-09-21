// SPDX-License-Identifier: AGPL-3.0-only
// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import type { CSSProperties } from 'react'

/**
 * Strips a <button> back to the appearance of the <div> or <span> it replaced.
 *
 * Several controls here were plain elements carrying an onClick, which made them
 * unreachable by keyboard: no focus stop, no Enter, no Space. A real <button>
 * brings that behaviour with it for free -- and also brings the user agent's
 * button chrome, which would change how the page looks. Spreading this first
 * keeps the rendering identical to what it replaced while the semantics become
 * correct; anything after it in the same object still wins.
 */
export const BUTTON_RESET: CSSProperties = {
  appearance: 'none',
  background: 'none',
  border: 'none',
  margin: 0,
  padding: 0,
  font: 'inherit',
  color: 'inherit',
  textAlign: 'inherit',
}
