// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/plotly.ts — manual vocabulary for the plotly.js subset the WebUI uses.
//
// SOURCE: https://plotly.com/javascript/reference/ (trace + layout attributes)
// Defined manually per prompt-4 (no codegen available for the
// plotly.js-dist-min bundle). Unverifiable attributes stay `unknown` via the
// index signatures — never `any`.
export interface TraceMarker {
  color?: string | number | undefined
  size?: number | number[] | undefined
  opacity?: number | undefined
  [key: string]: unknown
}

export interface TraceLine {
  color?: string | undefined
  width?: number | undefined
  dash?: string | undefined
  [key: string]: unknown
}

export interface PlotTrace {
  name?: string | undefined
  type?: string | undefined
  x?: unknown[] | undefined
  y?: unknown[] | undefined
  width?: number | number[] | undefined
  marker?: TraceMarker | undefined
  line?: TraceLine | undefined
  [key: string]: unknown
}

export interface PlotAxis {
  title?: string | { text?: string | undefined } | undefined
  type?: string | undefined
  range?: unknown[] | undefined
  [key: string]: unknown
}

export interface PlotFont {
  size?: number | undefined
  family?: string | undefined
  color?: string | undefined
  [key: string]: unknown
}

export interface PlotMargin {
  l?: number | undefined
  r?: number | undefined
  t?: number | undefined
  b?: number | undefined
  [key: string]: unknown
}

export interface PlotLegend {
  font?: PlotFont | undefined
  orientation?: string | undefined
  [key: string]: unknown
}

export interface PlotLayout {
  title?: string | { text?: string | undefined; font?: PlotFont | undefined } | undefined
  font?: PlotFont | undefined
  legend?: PlotLegend | undefined
  margin?: PlotMargin | undefined
  autosize?: boolean | undefined
  height?: number | undefined
  width?: number | undefined
  xaxis?: PlotAxis | undefined
  yaxis?: PlotAxis | undefined
  [key: string]: unknown
}

/** A complete plotly figure document as returned by the backend chart APIs. */
export interface PlotFigure {
  data: PlotTrace[]
  layout?: Partial<PlotLayout> | undefined
  frames?: unknown[] | undefined
}
