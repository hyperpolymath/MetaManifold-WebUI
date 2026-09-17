// SPDX-License-Identifier: AGPL-3.0-only
/** Extract a human-readable message from an unknown caught value. */
export function errorMessage(err: unknown, fallback = 'Unknown error'): string {
  if (err instanceof Error) return err.message
  if (typeof err === 'string') return err
  return fallback
}
