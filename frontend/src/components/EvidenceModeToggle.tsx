// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

export interface EvidenceModeToggleProps {
  enabled: boolean
  onChange: (next: boolean) => void
}

/**
 * Progressive-disclosure gate for CladeCumulus cladistic and epistemic
 * explorer surfaces. Defaults to `false` so standard reference/placement tree
 * management is never replaced silently.
 */
export function EvidenceModeToggle({ enabled, onChange }: EvidenceModeToggleProps) {
  return (
    <div
      style={{
        display: 'flex',
        flexWrap: 'wrap',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 12,
        padding: '10px 14px',
        marginBottom: 16,
        borderRadius: 8,
        border: enabled ? '1px solid #2e7d32' : '1px solid var(--color-border, #d0d7de)',
        background: enabled ? 'rgba(46, 125, 50, 0.06)' : 'var(--color-surface, #f8f9fa)',
      }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <strong style={{ fontSize: '.92rem' }}>CladeCumulus Evidence Mode</strong>
          <span
            style={{
              fontSize: '.74rem',
              padding: '1px 8px',
              borderRadius: 999,
              fontWeight: 600,
              background: enabled ? '#2e7d32' : '#6e7781',
              color: '#ffffff',
            }}
          >
            {enabled ? 'Active' : 'Standard view'}
          </span>
        </div>
        <span style={{ fontSize: '.82rem', color: 'var(--color-muted-fg, #57606a)' }}>
          {enabled
            ? 'Showing cumulative cladistic abundances, epistemic warrant colours, Faith’s PD, UniFrac, and non-destructive move validation.'
            : 'Enable to inspect phylogenetic + taxonomic clade clouds, Faith’s PD, UniFrac distances, and epistemic warrant.'}
        </span>
      </div>

      <button
        type="button"
        role="switch"
        aria-checked={enabled}
        className={enabled ? 'btn btn-primary btn-sm' : 'btn btn-sm'}
        onClick={() => onChange(!enabled)}
      >
        {enabled ? 'Exit Evidence Mode' : 'Enable Evidence Mode'}
      </button>
    </div>
  )
}
