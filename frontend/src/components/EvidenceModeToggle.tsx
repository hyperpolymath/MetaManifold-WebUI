// SPDX-License-Identifier: AGPL-3.0-only
import { useState } from 'react'

interface EvidenceModeToggleProps {
  enabled: boolean
  onToggle: (enabled: boolean) => void
}

export function EvidenceModeToggle({ enabled, onToggle }: EvidenceModeToggleProps) {
  const [showInfo, setShowInfo] = useState(false)

  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      gap: 12,
      padding: '8px 12px',
      background: enabled ? '#e8f5e9' : '#fafafa',
      border: `1px solid ${enabled ? '#4caf50' : '#e0e0e0'}`,
      borderRadius: 8,
      marginBottom: 16,
    }}>
      <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', fontWeight: 600 }}>
        <input
          type="checkbox"
          checked={enabled}
          onChange={e => onToggle(e.target.checked)}
          style={{ width: 18, height: 18 }}
        />
        Evidence Mode {enabled ? '✓' : ''}
      </label>

      <button
        className="btn btn-sm"
        onClick={() => setShowInfo(!showInfo)}
        style={{ marginLeft: 8 }}
      >
        {showInfo ? 'Hide' : 'What is this?'}
      </button>

      {enabled && (
        <span style={{ fontSize: 12, color: '#2e7d32', marginLeft: 8 }}>
          Advanced analysis & cladistic visuals enabled
        </span>
      )}

      {showInfo && (
        <div style={{
          position: 'absolute',
          zIndex: 100,
          marginTop: 100,
          background: 'white',
          border: '1px solid #ccc',
          borderRadius: 8,
          padding: 16,
          maxWidth: 500,
          boxShadow: '0 4px 12px rgba(0,0,0,0.15)',
          fontSize: 13,
          lineHeight: 1.5,
        }}>
          <h4 style={{ margin: '0 0 8px 0' }}>Evidence Mode</h4>
          <p>
            Evidence Mode enables advanced, epistemic-aware features that require understanding of
            <strong> Echo Types</strong> (fibers as structured loss witnesses), <strong>Epistemic Types</strong> (warrant without assumed soundness),
            and <strong>Residual Evidence</strong> (presence in every admissible world).
          </p>
          <ul style={{ margin: '8px 0', paddingLeft: 20 }}>
            <li><strong>AnalysisConfig layer</strong>: explicit, versioned, BH mandatory, DANGER banner on overrides, DOI-ready bundles</li>
            <li><strong>CladeCumulus</strong>: cumulative cladistic tree with epistemic colour coding, cloud sizing by residual count, drag-and-drop with live <code>present_in_every_admissible_world</code> validation</li>
            <li><strong>Advanced Analysis expander</strong>: dispersion methods, zero handling, prevalence filters — all with heavy validation and context-sensitive help</li>
          </ul>
          <p style={{ fontSize: 12, color: '#666' }}>
            Based on hyperpolymath/echo-types, epistemic-types, residual-evidence-types.
            Every analysis is an explicit, immutable, provenance-rich derived object. No silent switching.
          </p>
          <button className="btn btn-sm" onClick={() => setShowInfo(false)} style={{ marginTop: 8 }}>Close</button>
        </div>
      )}
    </div>
  )
}
