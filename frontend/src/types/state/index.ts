// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/state/index.ts — store/context, hook-result, and navigation
// state contracts.

/**
 * Async fetch lifecycle as produced by useApi.
 * SOURCE: src/hooks/useApi.ts (canonical implementation).
 */
export interface FetchState<T> {
  data: T | null
  loading: boolean
  error: string | null
}

/** useApi's return contract: lifecycle plus manual refetch. */
export type FetchResult<T> = FetchState<T> & { refetch: () => void }

/**
 * Navigation/routing state the whole app resolves through: the
 * study/run/group scope encoded in the URL and echoed as the (study, run,
 * group) triple accepted by every scoped API call.
 *
 * SOURCE: react-router useParams shapes in src/views/GroupView.tsx,
 * src/views/RunView.tsx, src/views/SlugResolver.tsx.
 */
export interface RouteScope {
  study: string
  run?: string | undefined
  group?: string | undefined
}
