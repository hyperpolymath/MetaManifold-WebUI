// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import { useEffect, useRef, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from './Toast'
import type { ComparisonRunSpec, DifferentialResult } from '../api/types'
import { sharedRanks } from './sharedRanks'
import type { AnalysisOption } from './annotationShared'
import { AnalysisChart } from './AnalysisChart'
import { AddToReport } from './AddToReport'
import { saveBlob } from '../utils/download'
import { differentialCsv, effectValue, formatStat } from './differentialTable'

const cell = { padding: '3px 10px', textAlign: 'right' } as const
const head = { padding: '4px 10px', textAlign: 'right' } as const

/** The CSV as a blob, ready to download or file in the report. */
function csvBlob(result: DifferentialResult): Blob {
  return new Blob([differentialCsv(result)], { type: 'text/csv;charset=utf-8' })
}

/**
 * Differential abundance between exactly two runs or sub-groups: a model per
 * taxon at the chosen rank (negative-binomial GLM, CLR Welch test after zero
 * replacement, or one multinomial / Dirichlet-multinomial model over the whole
 * composition, as configured), with BH-adjusted p-values, shown as a volcano
 * plot and a table
 * that can be downloaded or added to the report. The first selected condition
 * is the reference. The Advanced expander reports the settings the last fit
 * used, lets the reference taxon of the multinomial models be changed (only
 * taxa seen in at least half the samples are offered), and states what a fit
 * costs.
 */
export function DifferentialPanel({ study, runs, option, aggregate }: {
  study: string
  runs: ComparisonRunSpec[]
  option: AnalysisOption | null
  aggregate: boolean
}) {
  const toast = useToast()
  const [ranks, setRanks] = useState<string[]>([])
  const [rank, setRank] = useState<string>('')
  const [ranksReady, setRanksReady] = useState(false)
  const [ranksError, setRanksError] = useState<string | null>(null)
  const [result, setResult] = useState<DifferentialResult | null>(null)
  const [loading, setLoading] = useState(false)
  // The reference taxon chosen in the Advanced expander; '' means automatic.
  const [referenceChoice, setReferenceChoice] = useState('')
  const [savingReference, setSavingReference] = useState(false)
  // Only the response to the latest request, for the current inputs, is shown.
  const request = useRef(0)

  // The ranks shared by every selected run.
  useEffect(() => {
    setRanksError(null)
    if (!option || runs.length === 0) { setRanks([]); setRank(''); setRanksReady(false); return }
    let cancelled = false
    setRanksReady(false)
    sharedRanks(runs, r => api.analysis.ranks(study, r.run, {
      table: option.table,
      group: r.group,
      ...(r.source ? { source: r.source } : {}),
    })).then(shared => {
      if (cancelled) return
      setRanks(shared)
      setRanksReady(true)
      setRank(current => shared.includes(current) ? current : (shared[shared.length - 1] ?? ''))
    }).catch(err => {
      if (cancelled) return
      setRanks([])
      setRank('')
      setRanksError(errorMessage(err))
    })
    return () => { cancelled = true }
  }, [study, runs, option])

  // A result answers the inputs it was computed from; new inputs discard it,
  // along with any request still in flight for the old ones.
  useEffect(() => {
    request.current++
    setResult(null)
    setLoading(false)
  }, [study, runs, option?.table, rank, aggregate])

  /** Fit the model for the current inputs and show it, unless the inputs changed meanwhile. */
  const run = async () => {
    if (!option || !rank) return
    const req = ++request.current
    setLoading(true)
    try {
      const res = await api.analysis.differential(study, { runs, table: option.table, rank, aggregate })
      if (req === request.current) setResult(res)
    } catch (err) {
      if (req !== request.current) return
      setResult(null)
      toast.error(`Differential abundance failed: ${errorMessage(err)}`)
    } finally {
      if (req === request.current) setLoading(false)
    }
  }

  // A new result names its own reference; the selector follows it.
  useEffect(() => {
    setReferenceChoice(result?.config.mn_reference_taxon ?? '')
  }, [result])

  /**
   * Save the chosen reference taxon to the study configuration and refit. The
   * route has no per-request overrides: settings belong to the study, as they
   * do for every other analysis here, so the selection is persisted and the
   * table is rebuilt from it.
   */
  const applyReference = async (taxon: string | null) => {
    setSavingReference(true)
    try {
      await api.config.patchStudy(study, { 'analysis.differential.mn_reference_taxon': taxon })
      await run()
      toast.success(taxon ? `Reference taxon set to ${taxon}` : 'Reference taxon set to automatic')
    } catch (err) {
      toast.error(`Could not set the reference taxon: ${errorMessage(err)}`)
    } finally {
      setSavingReference(false)
    }
  }

  const title = result
    ? `Differential abundance: ${result.groups.contrast} vs ${result.groups.reference} (${result.rank})`
    : ''

  const multinomialResult = result?.config.method === 'multinomial' ||
    result?.config.method === 'dirichlet_multinomial'
  // Only taxa that took part in the composition can anchor a log ratio; the
  // rest carry their reason in `note` and would leave every ratio undefined.
  const referenceCandidates = (result?.rows ?? []).filter(
    r => r.status === 'reference' || r.status === 'ok' || r.status === 'boundary')

  return (
    <div style={{ marginTop: 16 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
        <button className="btn" onClick={run} disabled={loading || !option || !rank || runs.length !== 2}>
          {loading ? 'Fitting…' : 'Differential Abundance'}
        </button>
        {ranks.length > 0 && (
          <select aria-label="Rank" value={rank} onChange={e => setRank(e.target.value)}
            style={{ font: 'inherit', padding: '1px 4px', verticalAlign: 'baseline' }}>
            {ranks.map(r => <option key={r} value={r}>{r}</option>)}
          </select>
        )}
        {ranksReady && ranks.length === 0 && (
          <span style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>No taxonomy rank shared by the selected runs.</span>
        )}
        {ranksError && (
          <span className="error-msg" style={{ margin: 0 }}>Could not read the taxonomy ranks: {ranksError}</span>
        )}
        {runs.length === 2 && (
          <span style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>
            Reference: {runs[0].prefix ?? runs[0].run}; a positive effect means more abundant in {runs[1].prefix ?? runs[1].run}.
          </span>
        )}
      </div>

      <details style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)', margin: '0 0 12px' }}>
        <summary style={{ cursor: 'pointer' }}>Which model is this?</summary>
        <ul style={{ margin: '6px 0 0 18px', lineHeight: 1.5 }}>
          <li>
            <strong>nb_glm</strong>: one negative-binomial GLM per taxon on the read counts,
            with a library-size offset. Tolerates overdispersion through its own dispersion
            parameter and suits few samples per group, but each taxon is fitted on its own.
          </li>
          <li>
            <strong>multinomial</strong>: one multinomial logistic model over the whole
            composition, so each coefficient is a log ratio against a reference taxon and no
            size factor or pseudocount is needed (Songbird; Morton et al. 2019). Conditioning
            on each sample's total is what makes the comparison robust to sequencing depth
            (Gloor et al. 2017).
          </li>
          <li>
            <strong>dirichlet_multinomial</strong>: the multinomial with a Dirichlet prior
            whose concentration absorbs variation between samples rather than within them
            (La Rosa et al. 2012); its standard errors widen when the data are overdispersed,
            and it collapses to the multinomial when they are not.
          </li>
          <li>
            <strong>clr_welch</strong>: Welch's t-test on centred log-ratios after zero
            replacement. A quick, robust check whose effect is a CLR difference, not a fold
            change.
          </li>
        </ul>
      </details>

      {result && (
        <>
          <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)', margin: '0 0 8px' }}>
            {result.method}. {result.diagnostics.n_tested} of {result.diagnostics.n_taxa} taxa tested
            {result.diagnostics.n_failed > 0 && `, ${result.diagnostics.n_failed} could not be fitted`}
            {result.diagnostics.n_boundary > 0 && `, ${result.diagnostics.n_boundary} at a dispersion boundary`}
            {result.diagnostics.n_filtered > 0 && `, ${result.diagnostics.n_filtered} below the prevalence threshold`}
            . Samples: {Object.entries(result.n_samples).map(([g, n]) => `${g} ${n}`).join(', ')}.
            {result.diagnostics.zero_replacement && (() => {
              const z = result.diagnostics.zero_replacement
              return ` ${z.zeros_replaced} zeros replaced by ${z.method} over ${z.n_taxa_in_composition} taxa; ` +
                `replaced values hold ${(100 * z.median_imputed_fraction).toPrecision(2)}% of the median sample ` +
                `and at most ${(100 * z.max_imputed_fraction).toPrecision(2)}% of any, and are not measurements.`
            })()}
            {result.diagnostics.ancom_bc && (() => {
              const b = result.diagnostics.ancom_bc
              const warn = b.warnings.length > 0 ? ` Warning: ${b.warnings.join('; ')}.` : ''
              return ` Estimated sampling-fraction shift δ = ${formatStat(b.delta)} (SE ${formatStat(b.delta_se)}, ` +
                `${b.em_iterations} E-M steps over ${b.n_taxa_in_composition} taxa).${warn}`
            })()}
            {result.diagnostics.aldex2 && (() => {
              const a = result.diagnostics.aldex2
              return ` ${a.mc_samples} Dirichlet(count + ${a.dirichlet_prior}) instances over ` +
                `${a.n_taxa_in_composition} taxa (seed ${a.seed}); ALDEx2 integrates over posterior draws rather than reporting a single SE.`
            })()}
            {result.diagnostics.songbird && (() => {
              const s = result.diagnostics.songbird
              const sep = s.n_separated_taxa > 0 ? ` (${s.n_separated_taxa} separated single-group taxa excluded)` : ''
              return ` Reference frame taxon: ${s.reference_taxon ?? 'none'} over ${s.n_identifiable_taxa} identifiable taxa${sep}.`
            })()}
          </p>

          {result.diagnostics.zero_replacement && result.diagnostics.zero_replacement.zeros_replaced > 0 && (() => {
            const z = result.diagnostics.zero_replacement!
            return (
              <div role="note" style={{ border: '1px solid var(--color-danger-border)', borderRadius: 4,
                padding: '8px 10px', margin: '8px 0', color: 'var(--color-danger)', fontSize: '.8rem' }}>
                <strong>DANGER — zero replacement is biased.</strong> Replaced zeros are model-based imputations,
                not measurements. Do not try multiple delta or alpha values and report only the most significant result;
                the selected values are recorded in this result and its CSV provenance.
                {z.posterior && ' Dirichlet posterior parameters are recorded; the replacements are adjusted posterior estimates, not posterior draws.'}
                {z.warnings.length > 0 && <ul style={{ margin: '5px 0 0', paddingLeft: 20 }}>
                  {z.warnings.map(w => <li key={w}>{w}</li>)}
                </ul>}
              </div>
            )
          })()}
          <details style={{ margin: '0 0 12px', fontSize: '.82rem' }}>
            <summary style={{ cursor: 'pointer', color: 'var(--color-muted-fg)' }}>
              Advanced
            </summary>
            <div style={{ display: 'grid', gap: 6, margin: '8px 0 0', padding: '8px 0 0 12px',
                          borderLeft: '2px solid var(--color-border)' }}>
              <div>
                Settings the last fit used: <code>{result.config.method}</code>
                {result.config.mn_reference_taxon && `, log ratios against ${result.config.mn_reference_taxon}`}
                {result.config.mn_penalty !== undefined && `, L2 penalty ${result.config.mn_penalty}`}
                {result.config.dm_overdispersion_method && `, overdispersion ${result.config.dm_overdispersion_method}`}
                {result.config.tolerance !== undefined &&
                  `, tolerance ${result.config.tolerance}, at most ${result.config.max_iter} Newton steps and ${result.config.max_seconds} s`}
                . These are study settings; change them in the configuration editor.
              </div>
              {result.diagnostics.model && (
                <div>
                  Cost: {result.diagnostics.model.n_taxa_fitted} taxa fitted in{' '}
                  {result.diagnostics.model.runtime_seconds.toPrecision(2)} s. The observed
                  information is a dense matrix, so the cost grows with the square of the number
                  of taxa; at most 1000 taxa are fitted, and a fit that exceeds{' '}
                  {result.config.max_seconds} s fails instead of holding the request open.
                </div>
              )}
              {multinomialResult && (
                <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
                  <label htmlFor="differential-reference">Reference taxon</label>
                  <select id="differential-reference" value={referenceChoice}
                    disabled={savingReference}
                    onChange={e => setReferenceChoice(e.target.value)}
                    style={{ font: 'inherit', padding: '1px 4px' }}>
                    <option value="">automatic (most abundant fitted taxon)</option>
                    {referenceCandidates.map(r => (
                      <option key={r.taxon} value={r.taxon}
                        disabled={r.prevalence < 0.5}>
                        {r.taxon} — in {Math.round(100 * r.prevalence)}% of samples
                        {r.prevalence < 0.5 ? ' (needs at least half)' : ''}
                      </option>
                    ))}
                  </select>
                  <button className="btn" disabled={savingReference}
                    onClick={() => applyReference(referenceChoice === '' ? null : referenceChoice)}>
                    {savingReference ? 'Saving…' : 'Apply and refit'}
                  </button>
                  <span style={{ color: 'var(--color-muted-fg)' }}>
                    Every reported effect is a log ratio against this taxon, so it must be
                    present in at least half the samples; taxa below the prevalence threshold
                    are not offered.
                  </span>
                </div>
              )}
            </div>
          </details>

          <AnalysisChart study={study} figure={result.figure} />

          {result.diagnostics.model_warning && (
            <div role="note" style={{ border: '1px solid var(--color-danger)', borderLeftWidth: 4,
              borderRadius: 4, color: 'var(--color-danger)', padding: '8px 12px', margin: '10px 0' }}>
              <strong>Model caution:</strong> {result.diagnostics.model_warning}
            </div>
          )}

          <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end', margin: '8px 0' }}>
            <button className="btn" onClick={() => saveBlob(csvBlob(result), 'differential_abundance.csv')}>
              Download CSV
            </button>
            <AddToReport study={study} kind="table" className="btn" defaultTitle={title}
              make={async () => ({ blob: csvBlob(result), ext: '.csv' })} />
          </div>

          <div style={{ overflowX: 'auto' }}>
            <table style={{ borderCollapse: 'collapse', fontSize: '.82rem', width: '100%' }}>
              <thead>
                <tr style={{ borderBottom: '2px solid var(--color-border)' }}>
                  <th style={{ ...head, textAlign: 'left' }}>{result.rank}</th>
                  <th style={head}>{result.effect.label}</th>
                  {['nb_glm', 'zinb', 'hurdle_nb'].includes(result.config.method) && <th style={head}>Estimate (ln)</th>}
                  {['zinb', 'hurdle_nb'].includes(result.config.method) && <th style={head}>Zero-process log-odds</th>}
                  <th style={head}>SE</th>
                  <th style={head}>p</th>
                  <th style={head}>padj (BH)</th>
                  <th style={{ ...head, textAlign: 'left' }}>Status</th>
                </tr>
              </thead>
              <tbody>
                {result.rows.map(r => (
                  <tr key={r.taxon} style={{ borderBottom: '1px solid var(--color-border)' }}>
                    <td style={{ ...cell, textAlign: 'left' }}>{r.taxon}</td>
                    <td style={cell}>{formatStat(effectValue(result, r))}</td>
                    {['nb_glm', 'zinb', 'hurdle_nb'].includes(result.config.method) && <td style={cell}>{formatStat(r.estimate)}</td>}
                    {['zinb', 'hurdle_nb'].includes(result.config.method) && <td style={cell}>{formatStat(r.zero_process_log_odds ?? null)}</td>}
                    <td style={cell}>{formatStat(r.standard_error)}</td>
                    <td style={cell}>{formatStat(r.pvalue)}</td>
                    <td style={cell}>{formatStat(r.padj)}</td>
                    <td style={{ ...cell, textAlign: 'left' }} title={r.note || undefined}>
                      {r.status}{r.note && <span style={{ color: 'var(--color-muted-fg)' }}> – {r.note}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  )
}
