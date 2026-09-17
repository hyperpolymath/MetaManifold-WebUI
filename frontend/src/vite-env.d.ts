/// <reference types="vite/client" />

// vite/client already declares '*.module.css' (const classes); a local
// re-declaration here collided with it (TS2300 duplicate identifier) once
// lib checking was examined under the strict foundation and has been removed.

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
  export type Data   = Record<string, unknown>
  export type Layout = Record<string, unknown>
}
