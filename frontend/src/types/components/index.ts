// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/components/index.ts — cross-component contracts only.
//
// Framework convention is React-style co-located props (component files own
// their local prop types). This directory hosts only types shared across two
// or more components so the dependency direction stays types ← components.
import type { PlotTrace, PlotLayout } from '../plotly'

/**
 * Minimal labelled option contract shared by selector components.
 * `AnalysisOption` (src/components/annotationShared.ts) extends this shape.
 */
export interface SelectionOption {
  key: string
  label: string
}

/**
 * Seed/persistent state of the react-chart-editor wrapper: a figure split
 * into its three mutable parts.
 *
 * SOURCE: src/components/ChartCustomiser.tsx (seed construction) +
 * src/components/ChartEditorInner.tsx (props).
 */
export interface ChartEditorState {
  data: PlotTrace[]
  layout: Partial<PlotLayout>
  frames: unknown[]
}

/** Editor mutation callback, matching PlotlyEditor's onUpdate arity. */
export type ChartEditorUpdateHandler = (
  data: PlotTrace[],
  layout: Partial<PlotLayout>,
  frames: unknown[],
) => void
