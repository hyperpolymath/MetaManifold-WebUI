// src/types/__tests__/api-boundary.type-test.ts
//
// TYPE-LEVEL tests: this file is validated by `bun run typecheck` (tsc),
// NOT executed by `bun test` (the `.type-test.ts` suffix keeps it out of
// runner discovery). A failing assertion is a compile error.
//
// Deviation note: the prompt suggested the `expect-type` package; we use 12
// lines of structural helpers instead — no new runtime/tooling dependency,
// same failing-the-gate semantics. Documented in docs/types/architecture.md.

/** `Equal<A, B>` is `true` iff A and B are mutually assignable. */
type Equal<A, B> =
  (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2)
    ? (<T>() => T extends B ? 1 : 2) extends (<T>() => T extends A ? 1 : 2)
      ? true
      : false
    : false

/** Asserts a compile-time condition; an error on the expression = test fail. */
type Expect<T extends true> = T

/** Asserts `A` is assignable to `B` (covariant direction only). */
type Assignable<A, B> = A extends B ? true : false

import type { TableCell, TableRow } from '../api/tables'
import type { LayoutOverrides, TraceOverrides } from '../api/cosmetics'
import type { TablePage, ChartCosmetics } from '../../api/types'
import type { PlotTrace, PlotLayout, PlotFigure } from '../plotly'
import type { Data, Layout } from 'plotly.js-dist-min'

// --- TableCell is exactly the DuckDB scalar surface -------------------------

export type _t1 = Expect<Equal<TableCell, string | number | boolean | null>>

// --- TableRow tightness -----------------------------------------------------

export type _t2 = Expect<Assignable<TableRow, Record<string, unknown>>>
export type _t3 = Expect<Equal<Assignable<Record<string, unknown>, TableRow>, false>>

// --- TablePage.rows resolves to the canonical row type ----------------------

export type _t5 = Expect<Equal<TablePage['rows'], TableRow[]>>

// --- Chart cosmetics narrow (never widen) the plotly vocabulary -------------

export type _t6 = Expect<Assignable<LayoutOverrides, Record<string, unknown>>>
export type _t7 = Expect<Assignable<ChartCosmetics['traces'], Record<string, Record<string, unknown>> | undefined>>
export type _t8 = Expect<Assignable<TraceOverrides, Record<string, unknown>>>

// --- The plotly.js-dist-min facade re-exports the canonical vocabulary ------

export type _t9 = Expect<Equal<Data, PlotTrace>>
export type _t10 = Expect<Equal<Layout, PlotLayout>>

// --- `unknown`, never `any`: unknown accepts everything, forces narrowing ---

declare const anyCell: TableCell
declare const trace: PlotTrace

// (wrapped in a tuple so `extends` does not distribute over the union)
export type _t11 = Expect<Equal<[typeof anyCell] extends [{ toUpperCase: () => string }] ? true : false, false>>
export type _t12 = Expect<Assignable<PlotFigure['layout'], Partial<PlotLayout> | undefined>>

// A trace is an open record, but requires no property:
export const _t13: PlotTrace = { type: 'bar', marker: { color: '#aabbcc' } }
export const _t14: PlotTrace = {}
export const _t15 = trace['confidence'] // unknown — open attributes are verifiable only after narrowing
export type _t15_is_unknown = typeof _t15
