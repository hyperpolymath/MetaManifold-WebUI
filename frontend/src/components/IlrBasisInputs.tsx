// SPDX-License-Identifier: AGPL-3.0-only
// ILR basis selection and its inputs (issue #20). The basis's REQUIRED input (tree,
// SBP file or clustering method) sits next to the basis choice, because the basis is
// unusable without it; the optional philr weights and the SBP history are Advanced
// Analysis options and appear only in Evidence Mode. Conditions and refusals:
// docs/statistics/method-conditions/ilr-bases.md.
import { useState } from 'react'
import type { AnalysisConfig, IlrBasis, IlrBalanceWeights, IlrDendrogramMethod, IlrPartWeights } from '../types/analysis_config'
import {
  ILR_BALANCE_WEIGHTS,
  ILR_BASES,
  ILR_DENDROGRAM_METHODS,
  ILR_PART_WEIGHTS,
  ILR_SBP_ATTEMPT_DANGER_THRESHOLD,
  contextHelp,
  ilrBasisOf,
  ilrInputProblems,
  ilrSbpAttempts,
  withIlrBasis,
} from '../types/analysis_config'

interface IlrBasisInputsProps {
  evidenceMode: boolean
  config: AnalysisConfig
  onChange: (config: AnalysisConfig) => void
  validationErrors?: Record<string, string>
}

const BASIS_LABELS: Record<IlrBasis, string> = {
  default: 'default — Helmert (unchanged)',
  phylogenetic: 'phylogenetic — PhILR (needs a rooted, bifurcating tree)',
  sequential_binary_partition: 'sequential_binary_partition — your SBP matrix (CSV)',
  balance_dendrogram: 'balance_dendrogram — clustered from the data (variation matrix)',
}

const helpBox = { fontSize: 12, background: '#fff', padding: 8, marginTop: 4, borderRadius: 4, whiteSpace: 'pre-wrap' as const }
const errorText = { color: '#c62828', fontSize: 12 }

export function IlrBasisInputs({ evidenceMode, config, onChange, validationErrors }: IlrBasisInputsProps) {
  const [helpField, setHelpField] = useState<string | null>(null)
  const basis = ilrBasisOf(config)
  const a = config.advanced
  const problems = ilrInputProblems(config)
  const setAdvanced = (patch: Partial<AnalysisConfig['advanced']>) => onChange({ ...config, advanced: { ...a, ...patch } })

  const help = (field: string) => (
    <button
      type="button"
      aria-label={`Help for ${field}`}
      onClick={() => setHelpField(helpField === field ? null : field)}
      style={{ fontSize: 10 }}
    >?</button>
  )
  const helpText = (field: string) => helpField === field ? <div style={helpBox}>{contextHelp(field)}</div> : null
  const fieldErrors = (field: string) => {
    const messages = problems.filter(p => p.field === field).map(p => p.message)
    const server = validationErrors?.[field]
    if (server && !messages.includes(server)) messages.push(server)
    return messages.map(m => <div key={m} role="alert" style={errorText}>{m}</div>)
  }
  const pathInput = (field: 'ilr_phylo_tree_path' | 'ilr_sbp_matrix_path', label: string, placeholder: string) => (
    <div style={{ marginTop: 8 }}>
      <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
        {label} (required)
        {help(`advanced.${field}`)}
      </label>
      <input
        type="text"
        value={a[field] ?? ''}
        onChange={e => setAdvanced({ [field]: e.target.value === '' ? null : e.target.value })}
        placeholder={placeholder}
        style={{ width: '100%', padding: 8, marginTop: 4, fontFamily: 'monospace' }}
      />
      {helpText(`advanced.${field}`)}
      {fieldErrors(`advanced.${field}`)}
    </div>
  )

  const partWeights = a.ilr_part_weights ?? 'uniform'
  const balanceWeights = a.ilr_balance_weights ?? 'uniform'
  const history = a.ilr_sbp_history ?? []
  const attempts = ilrSbpAttempts(a)
  const shownFields = new Set<string>([
    ...(basis === 'phylogenetic' ? ['advanced.ilr_phylo_tree_path'] : []),
    ...(basis === 'sequential_binary_partition' ? ['advanced.ilr_sbp_matrix_path'] : []),
    ...(basis === 'balance_dendrogram' ? ['advanced.ilr_balance_dendrogram_method'] : []),
    ...(evidenceMode && basis !== 'default' ? ['advanced.ilr_part_weights'] : []),
    ...(evidenceMode && basis === 'phylogenetic' ? ['advanced.ilr_balance_weights'] : []),
    ...(evidenceMode && basis === 'sequential_binary_partition' ? ['advanced.ilr_sbp_history'] : []),
  ])

  return (
    <div style={{ marginTop: 8 }}>
      <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
        ILR Basis
        {help('normalization.ilr_basis')}
      </label>
      <select
        value={basis}
        onChange={e => onChange(withIlrBasis(config, e.target.value as IlrBasis))}
        style={{ width: '100%', padding: 8, marginTop: 4 }}
      >
        {ILR_BASES.map(b => <option key={b} value={b}>{BASIS_LABELS[b]}</option>)}
      </select>
      {helpText('normalization.ilr_basis')}
      {basis !== 'default' && (
        <div style={{ fontSize: 11, color: '#666', marginTop: 4 }}>
          Switching basis clears the inputs of the other bases; nothing is chosen for you. Benjamini-Hochberg across balances stays mandatory.
        </div>
      )}

      {basis === 'phylogenetic' && pathInput('ilr_phylo_tree_path', 'Newick tree', 'data/tree.nwk')}
      {basis === 'sequential_binary_partition' && pathInput('ilr_sbp_matrix_path', 'SBP matrix CSV', 'data/sbp.csv')}
      {basis === 'balance_dendrogram' && (
        <div style={{ marginTop: 8 }}>
          <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
            Dendrogram clustering method (required)
            {help('advanced.ilr_balance_dendrogram_method')}
          </label>
          <select
            value={a.ilr_balance_dendrogram_method ?? ''}
            onChange={e => setAdvanced({ ilr_balance_dendrogram_method: e.target.value === '' ? null : e.target.value as IlrDendrogramMethod })}
            style={{ width: '100%', padding: 8, marginTop: 4 }}
          >
            <option value="">— choose explicitly —</option>
            {ILR_DENDROGRAM_METHODS.map(m => <option key={m} value={m}>{m === 'ward' ? "ward (R's ward.D2)" : m}</option>)}
          </select>
          {helpText('advanced.ilr_balance_dendrogram_method')}
          {fieldErrors('advanced.ilr_balance_dendrogram_method')}
        </div>
      )}

      {basis !== 'default' && evidenceMode && (
        <div style={{ marginTop: 8, padding: 8, border: '1px dashed #ff9800', borderRadius: 4, background: '#fff8e1' }}>
          <div style={{ fontSize: 11, color: '#e65100', marginBottom: 4 }}>🔬 Advanced Analysis — ILR basis options</div>
          <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
            Part weights (philr part.weights)
            {help('advanced.ilr_part_weights')}
          </label>
          <select
            value={partWeights}
            onChange={e => setAdvanced({ ilr_part_weights: e.target.value as IlrPartWeights })}
            style={{ width: '100%', padding: 8, marginTop: 4 }}
          >
            {ILR_PART_WEIGHTS.map(w => <option key={w} value={w}>{w}</option>)}
          </select>
          {helpText('advanced.ilr_part_weights')}
          {fieldErrors('advanced.ilr_part_weights')}

          {basis === 'phylogenetic' && (
            <div style={{ marginTop: 8 }}>
              <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
                Balance weights (philr ilr.weights; need branch lengths)
                {help('advanced.ilr_balance_weights')}
              </label>
              <select
                value={balanceWeights}
                onChange={e => setAdvanced({ ilr_balance_weights: e.target.value as IlrBalanceWeights })}
                style={{ width: '100%', padding: 8, marginTop: 4 }}
              >
                {ILR_BALANCE_WEIGHTS.map(w => <option key={w} value={w}>{w}</option>)}
              </select>
              {balanceWeights !== 'uniform' && (
                <div style={{ fontSize: 11, color: '#e65100', marginTop: 4 }}>
                  Weighted balances are not isometric: effect sizes change, per-balance test statistics do not. Recorded in provenance.
                </div>
              )}
              {helpText('advanced.ilr_balance_weights')}
              {fieldErrors('advanced.ilr_balance_weights')}
            </div>
          )}

          {basis === 'sequential_binary_partition' && (
            <div style={{ marginTop: 8 }}>
              <label style={{ fontWeight: 600, display: 'flex', alignItems: 'center', gap: 8 }}>
                SBP matrices tried earlier (SHA-256, one per line)
                {help('advanced.ilr_sbp_history')}
              </label>
              <textarea
                value={history.join('\n')}
                onChange={e => setAdvanced({ ilr_sbp_history: e.target.value.split('\n').map(h => h.trim()).filter(h => h.length > 0) })}
                rows={3}
                style={{ width: '100%', padding: 8, marginTop: 4, fontFamily: 'monospace', fontSize: 11 }}
              />
              <div style={{ fontSize: 11, color: attempts > ILR_SBP_ATTEMPT_DANGER_THRESHOLD ? '#c62828' : '#666', marginTop: 4, fontWeight: attempts > ILR_SBP_ATTEMPT_DANGER_THRESHOLD ? 600 : 400 }}>
                {attempts} distinct SBP{attempts === 1 ? '' : 's'} recorded; the run adds the current file's digest.
                {attempts > ILR_SBP_ATTEMPT_DANGER_THRESHOLD
                  ? ' DANGER: more than 3 SBPs tried — the p-hacking guard banner will be raised and must be disclosed.'
                  : ` More than ${ILR_SBP_ATTEMPT_DANGER_THRESHOLD} distinct SBPs raises the DANGER banner.`}
              </div>
              {helpText('advanced.ilr_sbp_history')}
              {fieldErrors('advanced.ilr_sbp_history')}
            </div>
          )}
        </div>
      )}

      {basis !== 'default' && !evidenceMode && (partWeights !== 'uniform' || balanceWeights !== 'uniform' || history.length > 0) && (
        <div style={{ fontSize: 11, color: '#e65100', marginTop: 4 }}>
          Advanced ILR options are set (part weights {partWeights}, balance weights {balanceWeights}, {history.length} earlier SBPs). Enable Evidence Mode to review them.
        </div>
      )}

      {/* Problems on fields not rendered above (e.g. an input left over for another basis). */}
      {problems
        .filter(p => !shownFields.has(p.field))
        .map(p => <div key={`${p.field}:${p.message}`} role="alert" style={errorText}>{p.message}</div>)}
    </div>
  )
}
