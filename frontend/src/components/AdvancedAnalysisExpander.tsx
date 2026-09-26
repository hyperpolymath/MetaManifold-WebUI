// SPDX-License-Identifier: AGPL-3.0-only
import { useState } from 'react'
import type { AdvancedOverrides } from '../types/analysis_config'
import { contextHelp } from '../types/analysis_config'

// The replacement preview. The point of it is that delta's effect is visible *before* a run
// rather than after one: on a [10, 20, 0] sample with per-part detection limits [10, 20, 20],
// delta = 0.65 places delta x sum(DL of the zero parts) = 13 counts into the replaced entry
// and scales the observed parts by 1 - 13/30. This mirrors src/analysis/zero_replacement.jl
// for one sample and one zero, which is exactly what the expander has in hand without the
// data. It computes nothing about the data — the note says so, because a preview that looked
// like a result would be worse than no preview.
const PREVIEW_SAMPLE = [10, 20, 0]
const PREVIEW_LIMITS = [10, 20, 20]

function replacementPreview(delta: number) {
  const total = PREVIEW_SAMPLE.reduce((a, b) => a + b, 0)
  const zeroRows = PREVIEW_SAMPLE.map((v, i) => (v === 0 ? i : -1)).filter(i => i >= 0)
  const limitSum = zeroRows.reduce((a, i) => a + PREVIEW_LIMITS[i], 0)
  const imputedMass = (delta * limitSum) / total
  const scale = 1 - imputedMass
  const refused = imputedMass >= 1
  const replaced = PREVIEW_SAMPLE.map((v, i) => {
    if (v === 0) return delta * PREVIEW_LIMITS[i]
    return scale * v
  })
  return { total, zeroRows, limitSum, imputedMass, scale, replaced, refused }
}

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

          {/* Zero replacement parameters — delta with a preview, alpha, trend */}
          {(advanced.zero_handling === 'multiplicative_replacement' ||
            advanced.zero_policy === 'multiplicative_replacement' ||
            advanced.zero_handling === 'bayesian_multiplicative' ||
            advanced.zero_policy === 'bayesian_multiplicative') && (() => {
            const delta = advanced.multiplicative_delta ?? 0.65
            const preview = replacementPreview(delta)
            return (
              <div style={{ marginBottom: 16 }}>
                <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span>{'Multiplicative delta (0,1) — 0.65 is the reference default'}</span>
                  <button onClick={() => setHelpField(helpField === 'zr' ? null : 'zr')} style={{ fontSize: 10 }}>?</button>
                </label>
                <input
                  type="range"
                  min={0.01}
                  max={0.99}
                  step={0.01}
                  value={delta}
                  onChange={e => {
                    const v = parseFloat(e.target.value)
                    if (isNaN(v) || v <= 0 || v >= 1) {
                      alert(`delta must be in (0,1), got ${e.target.value}. Refusing as meaningless.`)
                      return
                    }
                    onChange({ ...advanced, multiplicative_delta: v })
                  }}
                  style={{ width: '100%', marginTop: 4 }}
                />
                <div style={{ fontSize: 12, display: 'flex', gap: 16 }}>
                  <span>delta = <strong>{delta.toFixed(2)}</strong></span>
                  <span>admissible 0 to {(preview.total / preview.limitSum).toFixed(3)}</span>
                </div>
                {delta < 0.01 && <div style={{ color: '#e65100', fontSize: 12 }}>delta below 0.01: replaced values are far below every detection limit; the run will warn.</div>}
                {delta >= 0.9 && <div style={{ color: '#e65100', fontSize: 12 }}>delta at or above 0.9: replaced values approach the observed parts; the run will warn.</div>}
                <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 4, borderRadius: 4 }}>
                  <div style={{ fontWeight: 600, marginBottom: 4 }}>Preview on a fixed example, not on your data: [10, 20, 0] with per-part detection limits [10, 20, 20]</div>
                  {preview.refused ? (
                    <div style={{ color: '#c62828' }}>delta ≥ {preview.total > 0 ? (preview.total / preview.limitSum).toFixed(3) : '—'} would place the whole sample in replaced values. Refused.</div>
                  ) : (
                    <div>
                      <div>replaced table: [{preview.replaced.map(v => v.toFixed(2)).join(', ')}]</div>
                      <div>imputed mass {preview.imputedMass.toFixed(4)} of {preview.total} counts; observed parts scaled by {preview.scale.toFixed(4)}</div>
                      <div>sample total preserved exactly; ratios among observed parts unchanged.</div>
                    </div>
                  )}
                </div>
                {(advanced.zero_handling === 'bayesian_multiplicative' ||
                  advanced.zero_policy === 'bayesian_multiplicative') && (
                  <div style={{ marginTop: 8 }}>
                    <label style={{ fontWeight: 600 }}>Bayesian prior concentration alpha ({'>'}0, blank = estimate from the data)</label>
                    <input
                      type="number"
                      min={0.000001}
                      step={0.1}
                      value={advanced.bayesian_alpha ?? ''}
                      placeholder="1/gmean(t) — the reference GBM estimate"
                      onChange={e => {
                        if (e.target.value === '') {
                          onChange({ ...advanced, bayesian_alpha: null })
                          return
                        }
                        const v = parseFloat(e.target.value)
                        if (isNaN(v) || v <= 0) {
                          alert(`alpha must be > 0, got ${e.target.value}. Refusing: a non-positive Dirichlet concentration is an improper prior.`)
                          return
                        }
                        onChange({ ...advanced, bayesian_alpha: v })
                      }}
                      style={{ width: '100%', padding: 8, marginTop: 4 }}
                    />
                    {advanced.bayesian_alpha != null && (
                      <div style={{ color: '#e65100', fontSize: 12, marginTop: 4 }}>
                        A hand-set alpha is recorded in the DEED as a deviation from the reference estimate.
                      </div>
                    )}
                  </div>
                )}
                {helpField === 'zr' && (
                  <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 4, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
                    {contextHelp('advanced.zero_replacement_parameters')}
                  </div>
                )}
                {validationErrors?.['advanced.multiplicative_delta'] && (
                  <div style={{ color: '#c62828', fontSize: 12 }}>{validationErrors['advanced.multiplicative_delta']}</div>
                )}
              </div>
            )
          })()}

          {advanced.dispersion_method === 'glmGamPoi' && (
            <div style={{ marginBottom: 16 }}>
              <label style={{ fontWeight: 600 }}>glmGamPoi abundance trend (variance prior)</label>
              <select
                value={advanced.glmgampoi_abundance_trend === true ? 'true' : advanced.glmgampoi_abundance_trend === false ? 'false' : 'null'}
                onChange={e => {
                  const v = e.target.value
                  onChange({ ...advanced, glmgampoi_abundance_trend: v === 'null' ? null : v === 'true' })
                }}
                style={{ width: '100%', padding: 8, marginTop: 4 }}
              >
                <option value="null">not set — refused at or above 100 features</option>
                <option value="false">false — the reference's non-trended prior (recorded)</option>
                <option value="true">true — NOT PORTED, will be refused</option>
              </select>
              <div style={{ fontSize: 12, color: '#666', marginTop: 4 }}>
                The reference switches to a natural-spline trend at 100 features. That spline is not ported, so
                asking for it is refused by name; `false` runs the reference's own non-trended prior and records the
                deviation. See docs/statistics/method-conditions/dispersion-glmGamPoi.md.
              </div>
            </div>
          )}

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
