// SPDX-License-Identifier: AGPL-3.0-only
import { useState } from 'react'
import type { AdvancedOverrides } from '../types/analysis_config'
import { contextHelp } from '../types/analysis_config'

interface AdvancedAnalysisExpanderProps {
  evidenceMode: boolean
  advanced: AdvancedOverrides
  onChange: (advanced: AdvancedOverrides) => void
  validationErrors?: Record<string, string>
}

export function AdvancedAnalysisExpander({ evidenceMode, advanced, onChange, validationErrors }: AdvancedAnalysisExpanderProps) {
  const [expanded, setExpanded] = useState(false)
  const [helpField, setHelpField] = useState<string | null>(null)

  if (!evidenceMode) return null // Keep UI clean — only appears when Evidence Mode enabled

  return (
    <div style={{
      border: '1px solid #ff9800',
      borderRadius: 8,
      marginTop: 16,
      background: '#fff8e1',
    }}>
      <button
        onClick={() => setExpanded(!expanded)}
        style={{
          width: '100%',
          padding: '12px 16px',
          background: expanded ? '#ffe0b2' : '#fff3e0',
          border: 'none',
          borderRadius: expanded ? '8px 8px 0 0' : '8px',
          cursor: 'pointer',
          fontWeight: 600,
          textAlign: 'left',
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
        }}
      >
        <span>🔬 Advanced Analysis (Evidence Mode only)</span>
        <span>{expanded ? '▼ Collapse' : '▶ Expand'}</span>
      </button>

      {expanded && (
        <div style={{ padding: 16 }}>
          <p style={{ fontSize: 12, color: '#e65100', marginBottom: 12 }}>
            All advanced options are behind this expander with heavy validation, context-sensitive help, and refusal of meaningless inputs.
            See hyperpolymath/standards for JSON + Nickel + DEED schemes.
          </p>

          {/* Dispersion method */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
              Dispersion Method
              <button onClick={() => setHelpField(helpField === 'dispersion' ? null : 'dispersion')} style={{ fontSize: 10 }}>?</button>
            </label>
            <select
              value={advanced.dispersion_method}
              onChange={e => onChange({ ...advanced, dispersion_method: e.target.value as any })}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            >
              <option value="parametric">parametric (DESeq2 default)</option>
              <option value="local">local</option>
              <option value="mean">mean</option>
              <option value="pooled">pooled</option>
              <option value="glmGamPoi">glmGamPoi (fast)</option>
            </select>
            {helpField === 'dispersion' && (
              <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 4, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
                {contextHelp('advanced.dispersion_method')}
              </div>
            )}
            {validationErrors?.['advanced.dispersion_method'] && (
              <div style={{ color: '#c62828', fontSize: 12 }}>{validationErrors['advanced.dispersion_method']}</div>
            )}
          </div>

          {/* Zero handling */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
              Zero Handling
              <button onClick={() => setHelpField(helpField === 'zero' ? null : 'zero')} style={{ fontSize: 10 }}>?</button>
            </label>
            <select
              value={advanced.zero_handling}
              onChange={e => onChange({ ...advanced, zero_handling: e.target.value as any })}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            >
              <option value="pseudocount">pseudocount (recommended for CLR/ILR)</option>
              <option value="multiplicative_replacement">multiplicative_replacement</option>
              <option value="bayesian_multiplicative">bayesian_multiplicative</option>
              <option value="refuse">refuse (DANGEROUS — triggers DANGER banner)</option>
            </select>
            {advanced.zero_handling === 'refuse' && (
              <div style={{ color: '#c62828', fontSize: 12, fontWeight: 600, marginTop: 4 }}>
                DANGER: refuse will cause log(0) failures for compositional methods. Requires acknowledgment token.
              </div>
            )}
            {helpField === 'zero' && (
              <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 4, borderRadius: 4 }}>
                Zero handling determines how zeros are treated. For CLR/ILR, zeros must be replaced because log(0) is undefined.
                'refuse' is mathematically invalid for CLR/ILR and will be refused at runtime even with acknowledgment.
              </div>
            )}
          </div>

          {/* Min prevalence */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
              Min Prevalence [0,1]
              <button onClick={() => setHelpField(helpField === 'prevalence' ? null : 'prevalence')} style={{ fontSize: 10 }}>?</button>
            </label>
            <input
              type="number"
              min={0}
              max={1}
              step={0.01}
              value={advanced.min_prevalence}
              onChange={e => {
                const v = parseFloat(e.target.value)
                if (isNaN(v) || v < 0 || v > 1) {
                  // Refuse meaningless
                  alert(`min_prevalence must be in [0,1], got ${e.target.value}. Refusing as meaningless.`)
                  return
                }
                onChange({ ...advanced, min_prevalence: v })
              }}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            />
            {helpField === 'prevalence' && (
              <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 4, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
                {contextHelp('advanced.min_prevalence')}
              </div>
            )}
            {validationErrors?.['advanced.min_prevalence'] && (
              <div style={{ color: '#c62828', fontSize: 12 }}>{validationErrors['advanced.min_prevalence']}</div>
            )}
          </div>

          {/* Min abundance */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ fontWeight: 600 }}>{'Min Abundance ≥0'}</label>
            <input
              type="number"
              min={0}
              step={0.01}
              value={advanced.min_abundance}
              onChange={e => {
                const v = parseFloat(e.target.value)
                if (isNaN(v) || v < 0) {
                  alert(`min_abundance must be >=0, got ${e.target.value}. Refusing as meaningless.`)
                  return
                }
                onChange({ ...advanced, min_abundance: v })
              }}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            />
          </div>

          {/* Max features */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ fontWeight: 600 }}>{'Max Features (optional, >0, ≤100k)'}</label>
            <input
              type="number"
              min={1}
              max={100000}
              value={advanced.max_features ?? ''}
              placeholder="No limit"
              onChange={e => {
                if (e.target.value === '') {
                  onChange({ ...advanced, max_features: null })
                  return
                }
                const v = parseInt(e.target.value, 10)
                if (isNaN(v) || v <= 0) {
                  alert(`max_features must be >0 if set, got ${e.target.value}. Refusing.`)
                  return
                }
                if (v > 100000) {
                  alert(`max_features=${v} is absurdly large (>100k). Refusing as meaningless.`)
                  return
                }
                onChange({ ...advanced, max_features: v })
              }}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            />
          </div>

          {/* Min samples per group */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
              {'Min Samples Per Group ≥2'}
              <span style={{ fontSize: 10, color: '#666' }}>{'(≥3 recommended, <3 triggers DANGER)'}</span>
            </label>
            <input
              type="number"
              min={2}
              value={advanced.min_samples_per_group}
              onChange={e => {
                const v = parseInt(e.target.value, 10)
                if (isNaN(v) || v < 2) {
                  alert(`min_samples_per_group must be >=2, got ${e.target.value}. Refusing. Need at least 2 for variance estimation.`)
                  return
                }
                onChange({ ...advanced, min_samples_per_group: v })
              }}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            />
            {advanced.min_samples_per_group < 3 && (
              <div style={{ color: '#c62828', fontSize: 12, marginTop: 4 }}>
                {'DANGER: <3 samples per group — variance estimation will be unstable.'}
              </div>
            )}
          </div>

          {/* Robust */}
          <div style={{ marginBottom: 16 }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <input
                type="checkbox"
                checked={advanced.robust}
                onChange={e => onChange({ ...advanced, robust: e.target.checked })}
              />
              Robust estimation
            </label>
          </div>

          {advanced.zero_handling === 'refuse' && (
            <div style={{ marginTop: 16 }}>
              <label style={{ fontWeight: 600, color: '#c62828' }}>Acknowledgment Token for dangerous zero_handling='refuse'</label>
              <input
                type="text"
                value={advanced.acknowledgment_token ?? ''}
                onChange={e => onChange({ ...advanced, acknowledgment_token: e.target.value })}
                placeholder="I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH"
                style={{ width: '100%', padding: 8, marginTop: 4, border: '1px solid #c62828', fontFamily: 'monospace' }}
              />
            </div>
          )}

          <div style={{ marginTop: 16, fontSize: 11, color: '#666', background: '#fff', padding: 8, borderRadius: 4 }}>
            <strong>Heavy validation active:</strong> meaningless inputs are refused immediately (empty formula, prevalence outside [0,1], etc.).
            All advanced options are logged in provenance and DOI bundle. No silent switching.
          </div>
        </div>
      )}
    </div>
  )
}
