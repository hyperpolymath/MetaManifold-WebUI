// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/__tests__/domain-state.type-test.ts
// Type-level tests for the domain and state layers (see api-boundary
// .type-test.ts for the Equal/Expect harness rationale).

type Equal<A, B> =
  (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2)
    ? (<T>() => T extends B ? 1 : 2) extends (<T>() => T extends A ? 1 : 2)
      ? true
      : false
    : false
type Expect<T extends true> = T
type Assignable<A, B> = A extends B ? true : false

import type { TaxonomyRank, OtuTableRow } from '../domain'
import type { TableRow } from '../api/tables'
import type { SelectionOption, ChartEditorState, ChartEditorUpdateHandler } from '../components'
import type { FetchState, FetchResult, RouteScope } from '../state'
import type { AnalysisOption } from '../../components/annotationShared'

// --- Domain: ranks derive from the canonical RANK_ORDER value ---------------

export type _d1 = Expect<Equal<TaxonomyRank,
  'species' | 'genus' | 'family' | 'order' | 'class' | 'division' | 'supergroup'>>
export type _d2 = Expect<Equal<Assignable<'domain', TaxonomyRank>, false>>

// --- Domain: OTU display rows stay API-compatible ---------------------------

export type _d3 = Expect<Assignable<OtuTableRow, TableRow>>
export type _d4 = Expect<Assignable<OtuTableRow, { OTU: string }>>
export type _d5 = Expect<Equal<[TableRow] extends [OtuTableRow] ? true : false, false>>

// --- Components: shared contracts --------------------------------------------

export type _c1 = Expect<Assignable<AnalysisOption, SelectionOption>>
export type _c2 = Expect<Equal<ChartEditorState['frames'], unknown[]>>
export type _c3 = Expect<Equal<Parameters<ChartEditorUpdateHandler>[1], Partial<import('../plotly').PlotLayout>>>

// --- State: useApi lifecycle --------------------------------------------------

export type _s1 = Expect<Equal<FetchState<number>['data'], number | null>>
export type _s2 = Expect<Equal<FetchState<string>['error'], string | null>>
export type _s3 = Expect<Equal<FetchState<boolean>['loading'], boolean>>
export type _s4 = Expect<Assignable<FetchResult<Date>, FetchState<Date> & { refetch: () => void }>>

// --- State: routing scope ------------------------------------------------------

export type _r1 = Expect<Assignable<RouteScope, { study: string }>>
export const _r2: RouteScope = { study: 'acc_schwartz_2021', run: '16S', group: 'soil' }
export const _r3: RouteScope = { study: 'acc_schwartz_2021' }
export type _r4 = Expect<Equal<{ name: string } extends { study: string } ? true : false, false>>
