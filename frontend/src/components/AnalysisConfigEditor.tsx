// SPDX-License-Identifier: AGPL-3.0-only
import { useState } from 'react'
import type { AnalysisConfig, ValidationError } from '../types/analysis_config'
import { contextHelp, isDangerous, DANGER_ACK_TOKEN, withoutIlrInputs } from '../types/analysis_config'
import { DangerBanner } from './DangerBanner'
import { AdvancedAnalysisExpander } from './AdvancedAnalysisExpander'
import { IlrBasisInputs } from './IlrBasisInputs'

interface AnalysisConfigEditorProps {
  evidenceMode: boolean
  config: AnalysisConfig
  onChange: (config: AnalysisConfig) => void
  onSave: () => void
  availableMetadataColumns?: string[]
  validationErrors?: ValidationError[]
}

export function AnalysisConfigEditor({ evidenceMode, config, onChange, onSave, availableMetadataColumns, validationErrors }: AnalysisConfigEditorProps) {
  const [helpField, setHelpField] = useState<string | null>(null)
  const [showJson, setShowJson] = useState(false)

  const errorsByField: Record<string, string> = {}
  validationErrors?.forEach(e => { errorsByField[e.field] = e.message })

  const handleFormulaChange = (value: string) => {
    // Heavy validation, refusal of meaningless inputs
    if (value.includes(';') || value.includes('`') || value.includes('$')) {
      alert(`Formula contains forbidden characters (; \` $) that could be injection. Refusing.`)
      return
    }
    if (value.trim().length > 0 && !value.includes('~')) {
      alert(`Formula must contain '~' (R-style), e.g. '~ group'. Got '${value}'. Refusing ambiguous formula.`)
      // Still allow typing, but show error
    }
    onChange({ ...config, formula: value })
  }

  return (
    <div style={{ border: '1px solid #e0e0e0', borderRadius: 8, padding: 16, background: 'white' }}>
      <h3 style={{ margin: '0 0 16px 0', display: 'flex', alignItems: 'center', gap: 8 }}>
        AnalysisConfig — explicit, versioned, immutable
        <span style={{ fontSize: 10, background: '#e3f2fd', padding: '2px 6px', borderRadius: 4 }}>
          v{config.schema_version}
        </span>
        <span style={{ fontSize: 10, background: '#f3e5f5', padding: '2px 6px', borderRadius: 4, fontFamily: 'monospace' }}>
          {config.hash.slice(0, 12)}...
        </span>
      </h3>

      <DangerBanner config={config} onAcknowledge={token => {
        onChange({
          ...config,
          correction: { ...config.correction, acknowledgment_token: token, allow_no_correction: true },
          advanced: { ...config.advanced, acknowledgment_token: token }
        })
      }} />

      {/* Method — explicit, no auto-selection */}
      <div style={{ marginBottom: 16 }}>
        <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
          Method (required, no silent switching)
          <button onClick={() => setHelpField(helpField === 'method' ? null : 'method')} style={{ fontSize: 10 }}>?</button>
        </label>
        <select
          value={config.method}
          onChange={e => {
            const newMethod = e.target.value as any
            // When method changes, adjust normalization to compatible default — but explicitly, no silent auto
            let newNorm = config.normalization
            if (newMethod === 'clr_lm' && newNorm.method !== 'clr') {
              newNorm = { ...newNorm, method: 'clr', pseudocount: 0.5 }
            } else if (newMethod === 'ilr_lm' && newNorm.method !== 'ilr') {
              newNorm = { ...newNorm, method: 'ilr', pseudocount: 0.5, ilr_basis: 'default' }
            } else if (newMethod === 'nb_glm' && (newNorm.method === 'clr' || newNorm.method === 'ilr')) {
              newNorm = { ...newNorm, method: 'size_factors' }
            } else if (newMethod === 'logistic' && (newNorm.method === 'clr' || newNorm.method === 'ilr')) {
              newNorm = { ...newNorm, method: 'presence_absence' }
            }
            // ILR basis inputs are refused outside ILR, so leaving ILR clears them (visibly: the controls disappear with it)
            const newAdvanced = newNorm.method === 'ilr' ? config.advanced : withoutIlrInputs(config.advanced)
            onChange({ ...config, method: newMethod, normalization: newNorm, advanced: newAdvanced })
          }}
          style={{ width: '100%', padding: 8, marginTop: 4 }}
        >
          <option value="nb_glm">nb_glm — Negative Binomial GLM (counts, overdispersion)</option>
          <option value="clr_lm">clr_lm — CLR + Gaussian LM (compositional)</option>
          <option value="ilr_lm">ilr_lm — ILR + Gaussian LM (balances)</option>
          <option value="logistic">logistic — Logistic regression (presence/absence)</option>
        </select>
        {helpField === 'method' && (
          <div style={{ fontSize: 12, background: '#f5f5f5', padding: 8, marginTop: 4, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
            {contextHelp('method')}
          </div>
        )}
        {errorsByField['method'] && <div style={{ color: '#c62828', fontSize: 12 }}>{errorsByField['method']}</div>}
      </div>

      {/* Formula */}
      <div style={{ marginBottom: 16 }}>
        <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
          Formula (R-style, e.g. '~ group' or 'disease ~ group + batch')
          <button onClick={() => setHelpField(helpField === 'formula' ? null : 'formula')} style={{ fontSize: 10 }}>?</button>
        </label>
        <input
          type="text"
          value={config.formula}
          onChange={e => handleFormulaChange(e.target.value)}
          placeholder="~ group"
          style={{ width: '100%', padding: 8, marginTop: 4, fontFamily: 'monospace' }}
        />
        {helpField === 'formula' && (
          <div style={{ fontSize: 12, background: '#f5f5f5', padding: 8, marginTop: 4, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
            {contextHelp('formula')}
          </div>
        )}
        {errorsByField['formula'] && <div style={{ color: '#c62828', fontSize: 12 }}>{errorsByField['formula']}</div>}
        {availableMetadataColumns && (
          <div style={{ fontSize: 11, color: '#666', marginTop: 4 }}>
            Available columns: {availableMetadataColumns.join(', ')}
          </div>
        )}
      </div>

      {/* Metadata columns */}
      <div style={{ marginBottom: 16 }}>
        <label style={{ fontWeight: 600 }}>Metadata Columns (explicit, no auto-selection)</label>
        <input
          type="text"
          value={config.metadata_columns.join(', ')}
          onChange={e => {
            const cols = e.target.value.split(',').map(s => s.trim()).filter(s => s.length > 0)
            if (cols.length === 0) {
              alert('metadata_columns must be non-empty. Refusing empty as meaningless.')
              return
            }
            onChange({ ...config, metadata_columns: cols })
          }}
          placeholder="group, batch"
          style={{ width: '100%', padding: 8, marginTop: 4, fontFamily: 'monospace' }}
        />
        {errorsByField['metadata_columns'] && <div style={{ color: '#c62828', fontSize: 12 }}>{errorsByField['metadata_columns']}</div>}
      </div>

      {/* Outcome column for logistic */}
      {config.method === 'logistic' && (
        <div style={{ marginBottom: 16 }}>
          <label style={{ fontWeight: 600 }}>Outcome Column (required for logistic, binary)</label>
          <input
            type="text"
            value={config.outcome_column ?? ''}
            onChange={e => onChange({ ...config, outcome_column: e.target.value || null })}
            placeholder="disease"
            style={{ width: '100%', padding: 8, marginTop: 4 }}
          />
          {errorsByField['outcome_column'] && <div style={{ color: '#c62828', fontSize: 12 }}>{errorsByField['outcome_column']}</div>}
        </div>
      )}

      {/* Normalization */}
      <div style={{ marginBottom: 16, padding: 12, background: '#f9f9f9', borderRadius: 4 }}>
        <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
          Normalization / Transform (method-dependent)
          <button onClick={() => setHelpField(helpField === 'norm' ? null : 'norm')} style={{ fontSize: 10 }}>?</button>
        </label>
        <select
          value={config.normalization.method}
          onChange={e => {
            const method = e.target.value as any
            onChange({
              ...config,
              normalization: { ...config.normalization, method },
              advanced: method === 'ilr' ? config.advanced : withoutIlrInputs(config.advanced),
            })
          }}
          style={{ width: '100%', padding: 8, marginTop: 4 }}
        >
          <option value="none">none</option>
          <option value="size_factors">size_factors (DESeq2, for nb_glm)</option>
          <option value="relative">relative</option>
          <option value="rarefy">rarefy (discouraged for nb_glm — triggers DANGER)</option>
          <option value="clr">clr (for clr_lm, requires pseudocount)</option>
          <option value="ilr">ilr (for ilr_lm, requires pseudocount + basis)</option>
          <option value="presence_absence">presence_absence (for logistic)</option>
        </select>

        {(config.normalization.method === 'clr' || config.normalization.method === 'ilr') && (
          <div style={{ marginTop: 8 }}>
            <label>{'Pseudocount (must be >0, typical 0.5)'}</label>
            <input
              type="number"
              min={0.000001}
              step={0.01}
              value={config.normalization.pseudocount}
              onChange={e => {
                const v = parseFloat(e.target.value)
                if (isNaN(v) || v <= 0) {
                  alert(`pseudocount must be >0 for CLR/ILR (log(0) undefined). Got ${e.target.value}. Refusing.`)
                  return
                }
                onChange({ ...config, normalization: { ...config.normalization, pseudocount: v } })
              }}
              style={{ width: '100%', padding: 8, marginTop: 4 }}
            />
          </div>
        )}

        {config.normalization.method === 'ilr' && (
          <IlrBasisInputs evidenceMode={evidenceMode} config={config} onChange={onChange} validationErrors={errorsByField} />
        )}

        {helpField === 'norm' && (
          <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 8, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
            {contextHelp('normalization.method')}
          </div>
        )}
        {errorsByField['normalization.method'] && <div style={{ color: '#c62828', fontSize: 12 }}>{errorsByField['normalization.method']}</div>}
      </div>

      {/* Correction — BH mandatory */}
      <div style={{ marginBottom: 16, padding: 12, background: '#e8f5e9', borderRadius: 4, border: '1px solid #4caf50' }}>
        <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
          Correction (BH mandatory in v1)
          <button onClick={() => setHelpField(helpField === 'correction' ? null : 'correction')} style={{ fontSize: 10 }}>?</button>
        </label>
        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
          <input
            type="text"
            value={config.correction.method}
            onChange={e => onChange({ ...config, correction: { ...config.correction, method: e.target.value } })}
            style={{ flex: 1, padding: 8, fontFamily: 'monospace' }}
            placeholder="BH"
          />
          <input
            type="number"
            min={0.0001}
            max={0.9999}
            step={0.01}
            value={config.correction.alpha}
            onChange={e => {
              const v = parseFloat(e.target.value)
              if (isNaN(v) || v <= 0 || v >= 1) {
                alert(`alpha must be in (0,1), got ${e.target.value}. Typical 0.05. Refusing.`)
                return
              }
              onChange({ ...config, correction: { ...config.correction, alpha: v } })
            }}
            style={{ width: 100, padding: 8 }}
          />
        </div>

        <label style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8, color: '#c62828', fontWeight: 600 }}>
          <input
            type="checkbox"
            checked={config.correction.allow_no_correction}
            onChange={e => {
              if (e.target.checked) {
                const token = prompt(`DANGER: You are about to disable BH correction. This is scientifically dangerous and will inflate false discoveries. To proceed, paste exactly: ${DANGER_ACK_TOKEN}`)
                if (token !== DANGER_ACK_TOKEN) {
                  alert('Wrong token or cancelled. BH remains enforced.')
                  return
                }
                onChange({
                  ...config,
                  correction: { ...config.correction, allow_no_correction: true, acknowledgment_token: token }
                })
              } else {
                onChange({
                  ...config,
                  correction: { ...config.correction, allow_no_correction: false, method: 'BH', acknowledgment_token: null }
                })
              }
            }}
          />
          Allow non-BH correction (triggers DANGER banner, requires acknowledgment)
        </label>

        {config.correction.allow_no_correction && (
          <input
            type="text"
            value={config.correction.acknowledgment_token ?? ''}
            onChange={e => onChange({ ...config, correction: { ...config.correction, acknowledgment_token: e.target.value } })}
            placeholder={DANGER_ACK_TOKEN}
            style={{ width: '100%', padding: 8, marginTop: 8, border: '2px solid #c62828', fontFamily: 'monospace' }}
          />
        )}

        {helpField === 'correction' && (
          <div style={{ fontSize: 12, background: '#fff', padding: 8, marginTop: 8, borderRadius: 4, whiteSpace: 'pre-wrap' }}>
            {contextHelp('correction.method')}
          </div>
        )}
      </div>

      {/* Advanced — behind Evidence Mode */}
      <AdvancedAnalysisExpander
        evidenceMode={evidenceMode}
        advanced={config.advanced}
        onChange={adv => onChange({ ...config, advanced: adv })}
        validationErrors={errorsByField}
      />

      {/* Provenance preview */}
      <div style={{ marginTop: 16, fontSize: 11, color: '#666', background: '#fafafa', padding: 8, borderRadius: 4 }}>
        <strong>Provenance:</strong> ID {config.id.slice(0, 8)}... | Hash {config.hash.slice(0, 12)}... | Created {config.created_at} by {config.created_by}
        <br />
        <strong>Immutable:</strong> Every analysis is an explicit, immutable, provenance-rich derived object. No silent switching.
        <br />
        <strong>DOI-ready:</strong> Bundle includes JSON + Nickel + DEED + DataCite + provenance.
      </div>

      {/* Actions */}
      <div style={{ marginTop: 16, display: 'flex', gap: 8 }}>
        <button
          className="btn btn-primary"
          onClick={onSave}
          disabled={isDangerous(config) && config.correction.acknowledgment_token !== DANGER_ACK_TOKEN && config.advanced.acknowledgment_token !== DANGER_ACK_TOKEN}
          style={{ padding: '8px 16px' }}
        >
          Save AnalysisConfig (immutable)
        </button>
        <button className="btn" onClick={() => setShowJson(!showJson)} style={{ padding: '8px 16px' }}>
          {showJson ? 'Hide JSON' : 'Show JSON/Nickel/DEED'}
        </button>
      </div>

      {showJson && (
        <div style={{ marginTop: 16 }}>
          <h4>JSON (canonical, hash: {config.hash.slice(0, 16)}...)</h4>
          <pre style={{ background: '#f5f5f5', padding: 12, borderRadius: 4, overflow: 'auto', fontSize: 11, maxHeight: 300 }}>
            {JSON.stringify(config, null, 2)}
          </pre>
          <p style={{ fontSize: 11, color: '#666' }}>
            Nickel and DEED representations are available in DOI bundle and via API.
            See config/schemas/analysis_config.schema.json, .ncl, and _chora.deed template (hyperpolymath/standards).
          </p>
        </div>
      )}
    </div>
  )
}
