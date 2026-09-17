// src/types/api/cosmetics.ts — boundary types for chart cosmetics.
//
// SOURCE: src/server/routes/analysis.jl
// Chart cosmetics are free-form plotly attribute overrides persisted by the
// backend and deep-merged client-side (src/api/figureColours.ts). They are
// narrows of the manual plotly vocabulary, not new shapes.
import type { PlotLayout, PlotTrace } from '../plotly'

/** Partial plotly layout document stored as a cosmetic override. */
export type LayoutOverrides = Partial<PlotLayout>

/** Partial per-trace attribute override, keyed by trace name at the call site. */
export type TraceOverrides = Partial<PlotTrace>
