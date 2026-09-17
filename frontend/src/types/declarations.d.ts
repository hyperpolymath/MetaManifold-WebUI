// Ambient declarations for dependencies that publish no types.
// Pattern per estate type policy: a FIXME(types) header + tracking pointer +
// unknown-safe declarations (never `any`).

// FIXME(types): plotly.js-dist-min has no published types.
// Tracked in: docs/type-system/category-d-e-closure.md
// (The minified dist bundle intentionally has no declaration surface; if the
// frontend ever moves to the full plotly.js package, @types/plotly.js could
// replace this hand-written subset.)
declare module 'plotly.js-dist-min' {
  const Plotly: {
    react(
      root: HTMLElement,
      data: Record<string, unknown>[],
      layout?: Record<string, unknown>,
      config?: Record<string, unknown>,
    ): Promise<void>
    relayout(root: HTMLElement, update: Record<string, unknown>): Promise<void>
    purge(root: HTMLElement): void
    newPlot(
      root: HTMLElement,
      data: Record<string, unknown>[],
      layout?: Record<string, unknown>,
      config?: Record<string, unknown>,
    ): Promise<void>
  }
  export default Plotly
  // Data/Layout are aliases of the manual plotly vocabulary; the bundle
  // itself remains untyped (see src/types/plotly.ts).
  export type Data = import('./plotly').PlotTrace
  export type Layout = import('./plotly').PlotLayout
}

// FIXME(types): react-chart-editor has no published types.
// Tracked in: docs/type-system/category-d-e-closure.md
// (upstream https://github.com/plotly/react-chart-editor is archived and will
// never ship type declarations; this ambient declaration is the permanent
// boundary until the component is replaced or vendored.)
declare module 'react-chart-editor' {
  import type { ComponentType, ReactNode } from 'react'
  import type { PlotTrace, PlotLayout } from './plotly'

  interface PlotlyEditorProps {
    data?: PlotTrace[] | undefined
    layout?: Partial<PlotLayout> | undefined
    frames?: unknown[] | undefined
    config?: Record<string, unknown> | undefined
    plotly?: unknown
    onUpdate?:
      | ((data: PlotTrace[], layout: Partial<PlotLayout>, frames: unknown[]) => void)
      | undefined
    useResizeHandler?: boolean | undefined
    children?: ReactNode
  }

  const PlotlyEditor: ComponentType<PlotlyEditorProps>
  export default PlotlyEditor

  interface PanelMenuWrapperProps {
    children?: ReactNode
  }
  interface StylePanelProps {
    group?: string | undefined
    name?: string | undefined
  }

  export const PanelMenuWrapper: ComponentType<PanelMenuWrapperProps>
  export const StyleLayoutPanel: ComponentType<StylePanelProps>
  export const StyleTracesPanel: ComponentType<StylePanelProps>
  export const StyleAxesPanel: ComponentType<StylePanelProps>
  export const StyleLegendPanel: ComponentType<StylePanelProps>
}

declare module 'react-chart-editor/lib/react-chart-editor.css'
