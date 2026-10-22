// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// Small presentation pieces shared by the Evidence Mode panels. Kept here so
// the same number never gets two different treatments in two views.

import type { ReactNode } from 'react'

export interface Tone {
  fg: string
  bg: string
  border: string
}

export const TONES: Record<string, Tone> = {
  neutral: { fg: '#495057', bg: '#f1f3f5', border: '#dee2e6' },
  good:    { fg: '#2b8a3e', bg: '#ebfbee', border: '#b2f2bb' },
  warn:    { fg: '#b7791f', bg: '#fff8e1', border: '#ffe8a3' },
  bad:     { fg: '#c92a2a', bg: '#fff5f5', border: '#ffc9c9' },
  info:    { fg: '#1864ab', bg: '#e7f5ff', border: '#a5d8ff' },
}

export function Badge({ tone = 'neutral', children, title }: {
  tone?: keyof typeof TONES
  children: ReactNode
  title?: string
}) {
  const t = TONES[tone] ?? TONES.neutral
  return (
    <span title={title} style={{
      display: 'inline-block', padding: '1px 8px', borderRadius: 10, fontSize: '.74rem',
      color: t.fg, background: t.bg, border: `1px solid ${t.border}`, whiteSpace: 'nowrap',
    }}>{children}</span>
  )
}

/** A headline number with its label and an optional explanation. */
export function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div style={{ minWidth: 120 }}>
      <div style={{ fontSize: '.74rem', textTransform: 'uppercase', letterSpacing: '.03em',
                    color: 'var(--color-muted-fg)' }}>{label}</div>
      <div style={{ fontSize: '1.05rem', fontWeight: 600 }}>{value}</div>
      {hint && <div style={{ fontSize: '.74rem', color: 'var(--color-muted-fg)' }}>{hint}</div>}
    </div>
  )
}

/** A bordered remark that is about honesty rather than decoration. */
export function Notice({ tone = 'info', children }: { tone?: keyof typeof TONES; children: ReactNode }) {
  const t = TONES[tone] ?? TONES.info
  return (
    <div style={{
      padding: '8px 10px', borderRadius: 4, fontSize: '.82rem', lineHeight: 1.45,
      color: t.fg, background: t.bg, border: `1px solid ${t.border}`,
    }}>{children}</div>
  )
}

export const sectionTitleStyle: React.CSSProperties = {
  fontSize: '.78rem', textTransform: 'uppercase', letterSpacing: '.04em',
  color: 'var(--color-muted-fg)', marginBottom: 8,
}

export const tableStyle: React.CSSProperties = { width: '100%', borderCollapse: 'collapse', fontSize: '.82rem' }
export const thStyle: React.CSSProperties = {
  textAlign: 'left', padding: '4px 8px', borderBottom: '1px solid var(--color-border)',
  fontWeight: 600, color: 'var(--color-muted-fg)',
}
export const tdStyle: React.CSSProperties = {
  padding: '4px 8px', borderBottom: '1px solid var(--color-border)',
}
