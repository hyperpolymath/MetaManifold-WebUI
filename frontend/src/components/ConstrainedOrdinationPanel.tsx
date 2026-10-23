// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

import { useEffect, useMemo, useRef, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { saveBlob } from '../utils/download'
import { AnalysisChart } from './AnalysisChart'
import { useToast } from './Toast'
import type {
  ActiveOrdinationMethod,
  CladisticsSummary,
  ColFilter,
  ComparisonRunSpec,
  OrdinationDistance,
  OrdinationResult,
  OrdinationScaling,
  OrdinationTermTest,
} from '../api/types'
import {
  ORDINATION_CITATIONS,
  ORDINATION_DISTANCE_LABELS,
  ORDINATION_METHODS_INFO,
  estimateOrdinationRuntime,
  formatOrdinationCsv,
  getMethodInfo,
  isDistanceCompatible,
  resolveCompatibleDistance,
  scalingDescription,
  validateOrdinationFormulaSyntax,
} from './ordinationModel'

const ALL_DISTANCES: readonly OrdinationDistance[] = [
  'bray',
  'jaccard',
  'aitchison',
  'euclidean',
  'chisq',
  'weighted_unifrac',
  'unweighted_unifrac',
]

function fmtNum(v: number | null | undefined, digits = 4): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—'
  return v.toFixed(digits)
}

function fmtPct(v: number | null | undefined): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—'
  return `${(100 * v).toFixed(1)}%`
}

function TermAnovaTable({ title, subtitle, rows }: {
  title: string
  subtitle: string
  rows: OrdinationTermTest[]
}) {
  if (rows.length === 0) return null
  return (
    <div style={{ marginTop: 14 }}>
      <div style={{ fontWeight: 600, fontSize: '.84rem' }}>{title}</div>
      <div style={{ fontSize: '.76rem', color: 'var(--color-muted-fg)', marginBottom: 6 }}>{subtitle}</div>
      <div style={{ overflowX: 'auto' }}>
        <table className="data-table" style={{ width: '100%', fontSize: '.8rem' }}>
          <thead>
            <tr>
              <th style={{ textAlign: 'left' }}>Term</th>
              <th style={{ textAlign: 'right' }}>df</th>
              <th style={{ textAlign: 'right' }}>Variance / Inertia</th>
              <th style={{ textAlign: 'right' }}>Pseudo-F</th>
              <th style={{ textAlign: 'right' }}>Permutation p</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(r => (
              <tr key={r.term}>
                <td style={{ fontFamily: 'monospace' }}>{r.term}</td>
                <td style={{ textAlign: 'right' }}>{r.df}</td>
                <td style={{ textAlign: 'right' }}>{fmtNum(r.variance, 4)}</td>
                <td style={{ textAlign: 'right' }}>{fmtNum(r.f_statistic, 3)}</td>
                <td style={{ textAlign: 'right' }}>
                  {r.untestable_reason
                    ? <span title={r.untestable_reason} style={{ color: 'var(--color-warn)' }}>withheld (blocked)</span>
                    : fmtNum(r.p_value, 4)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function OrdinationHelpDetails() {
  return (
    <details style={{ marginTop: 14, fontSize: '.8rem', lineHeight: 1.5 }}>
      <summary style={{ cursor: 'pointer', fontWeight: 600, color: 'var(--color-muted-fg)' }}>
        Method selection, interpretation guide &amp; primary literature
      </summary>
      <div style={{ marginTop: 8, paddingLeft: 10, borderLeft: '2px solid var(--color-border)' }}>
        <p style={{ margin: '0 0 8px' }}>
          <strong>Constrained vs. unconstrained ordination:</strong> Unconstrained ordination (NMDS, PCoA, PCA)
          finds axes of largest total community variation first and overlays groups afterwards. Constrained
          ordination (<strong>dbRDA, CAP, RDA, CCA</strong>) projects community variation directly onto the
          subspace spanned by explicit study covariates, separating explained inertia from residual unconstrained
          variation. Always inspect adjusted R&sup2;, residual unconstrained inertia, and permutation p-values:
          visual separation on constrained axes alone is not confirmatory proof when R&sup2; is small.
        </p>
        <p style={{ margin: '0 0 8px' }}>
          <strong>Compositional compatibility:</strong> Linear <code>rda</code> operates in Euclidean space and
          therefore accepts zero-replaced CLR (<code>aitchison</code>; Gloor et al. 2017) or Euclidean/Hellinger
          coordinates, refusing raw non-Euclidean dissimilarities such as Bray-Curtis. Use <code>dbrda</code> or{' '}
          <code>cap</code> for Bray-Curtis, Jaccard, and UniFrac dissimilarities, and <code>cca</code> for
          unimodal chi-square niche gradients.
        </p>
        <p style={{ margin: '0 0 8px' }}>
          <strong>Multiple-testing discipline:</strong> Overall model and term tests use seeded{' '}
          <code>vegan::anova.cca</code> permutation inference (not Benjamini-Hochberg FDR). Per-taxon differential
          abundance tests in the Differential tab continue to enforce Benjamini-Hochberg adjustment.
        </p>
        <div style={{ fontWeight: 600, marginBottom: 4 }}>References</div>
        <ul style={{ margin: 0, paddingLeft: 18 }}>
          {ORDINATION_CITATIONS.map(c => (
            <li key={c.doi} style={{ marginBottom: 3 }}>
              {c.authors}. {c.title}{' '}
              <a href={`https://doi.org/${encodeURI(c.doi)}`} target="_blank" rel="noreferrer">
                doi:{c.doi}
              </a>
            </li>
          ))}
        </ul>
      </div>
    </details>
  )
}

function OrdinationResultsView({ study, result }: { study: string; result: OrdinationResult }) {
  const downloadCsv = () => {
    const csv = formatOrdinationCsv(result)
    saveBlob(
      new Blob([csv], { type: 'text/csv;charset=utf-8' }),
      `${study}_${result.method}_${result.distance}_ordination.csv`,
    )
  }

  const vp = result.variance_partitioning
  const om = result.omnibus_test

  return (
    <div style={{ marginTop: 14 }}>
      <AnalysisChart study={study} figure={result.biplot} heightRatio={0.54} />

      <div className="card" style={{ marginTop: 12, fontSize: '.82rem' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title" style={{ margin: 0 }}>
            Constrained Ordination Summary ({result.method.toUpperCase()} · {result.distance} · scaling {result.scaling})
          </div>
          <button className="btn btn-sm" onClick={downloadCsv}>Download CSV + Provenance</button>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10, marginTop: 12 }}>
          <div style={{ padding: '8px 10px', border: '1px solid var(--color-border)', borderRadius: 6 }}>
            <div style={{ fontSize: '.72rem', color: 'var(--color-muted-fg)' }}>Constrained R&sup2; / Adj. R&sup2;</div>
            <div style={{ fontWeight: 600, fontSize: '.95rem' }}>
              {fmtNum(result.r2, 3)} / {fmtNum(result.adj_r2, 3)}
            </div>
          </div>
          <div style={{ padding: '8px 10px', border: '1px solid var(--color-border)', borderRadius: 6 }}>
            <div style={{ fontSize: '.72rem', color: 'var(--color-muted-fg)' }}>Omnibus Permutation Test</div>
            <div style={{ fontWeight: 600, fontSize: '.95rem' }}>
              F({om.df_model}, {om.df_residual}) = {fmtNum(om.f_statistic, 2)}, p = {om.untestable_reason ? 'withheld' : fmtNum(om.p_value, 4)}
            </div>
          </div>
          <div style={{ padding: '8px 10px', border: '1px solid var(--color-border)', borderRadius: 6 }}>
            <div style={{ fontSize: '.72rem', color: 'var(--color-muted-fg)' }}>Inertia Partition</div>
            <div style={{ fontWeight: 600, fontSize: '.86rem' }}>
              Constrained {fmtPct(result.constrained_proportion)}
              {result.conditioned_proportion > 0 ? ` · Conditioned ${fmtPct(result.conditioned_proportion)}` : ''}
              {' · '}Residual {fmtPct(result.unconstrained_proportion)}
            </div>
          </div>
          <div style={{ padding: '8px 10px', border: '1px solid var(--color-border)', borderRadius: 6 }}>
            <div style={{ fontSize: '.72rem', color: 'var(--color-muted-fg)' }}>Provenance</div>
            <div style={{ fontFamily: 'monospace', fontSize: '.75rem' }}>
              vegan {result.provenance.software.vegan_version} · {om.permutations} perms · seed {result.provenance.seed}
            </div>
          </div>
        </div>

        {result.cautions.length > 0 && (
          <div style={{ marginTop: 12, padding: '8px 10px', borderRadius: 6, background: 'rgba(217, 119, 6, 0.08)', border: '1px solid rgba(217, 119, 6, 0.3)', fontSize: '.78rem' }}>
            {result.cautions.map((c, idx) => (
              <div key={idx} style={{ marginTop: idx > 0 ? 4 : 0 }}>{c}</div>
            ))}
          </div>
        )}

        <TermAnovaTable
          title="Sequential Term Tests (by = 'terms')"
          subtitle={`Tested sequentially in formula order (${result.formula}); smallest attainable p = ${om.min_p_value.toFixed(4)}.`}
          rows={result.term_tests}
        />
        <TermAnovaTable
          title="Marginal Term Tests (by = 'margin', Type III)"
          subtitle="Order-independent unique variance test of each constraining term given all other terms."
          rows={result.marginal_tests}
        />
        <TermAnovaTable
          title="Constrained Axis Tests (by = 'axis')"
          subtitle="Sequential permutation test of individual canonical axes."
          rows={result.axis_tests}
        />

        {vp && (
          <div style={{ marginTop: 14 }}>
            <div style={{ fontWeight: 600, fontSize: '.84rem' }}>Variance Partitioning (vegan::varpart)</div>
            {vp.status === 'skipped' ? (
              <p style={{ margin: '4px 0 0', fontSize: '.78rem', color: 'var(--color-muted-fg)' }}>{vp.reason}</p>
            ) : (
              <>
                {vp.note && (
                  <div style={{ fontSize: '.76rem', color: 'var(--color-muted-fg)', marginBottom: 6 }}>{vp.note}</div>
                )}
                <div style={{ overflowX: 'auto' }}>
                  <table className="data-table" style={{ width: '100%', fontSize: '.8rem' }}>
                    <thead>
                      <tr>
                        <th style={{ textAlign: 'left' }}>Fraction</th>
                        <th style={{ textAlign: 'right' }}>df</th>
                        <th style={{ textAlign: 'right' }}>Unadjusted R&sup2;</th>
                        <th style={{ textAlign: 'right' }}>Adjusted R&sup2;</th>
                        <th style={{ textAlign: 'left' }}>Testability</th>
                      </tr>
                    </thead>
                    <tbody>
                      {vp.individual_fractions.map(f => (
                        <tr key={f.label}>
                          <td style={{ fontFamily: 'monospace' }}>{f.label}</td>
                          <td style={{ textAlign: 'right' }}>{f.df}</td>
                          <td style={{ textAlign: 'right' }}>{fmtNum(f.r2, 4)}</td>
                          <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmtNum(f.adj_r2, 4)}</td>
                          <td>{f.testable ? 'Testable (partial ordination)' : 'Shared / residual (not permutation-testable)'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export function ConstrainedOrdinationPanel({
  study,
  runs,
  table,
  aggregate,
  rAvailable,
}: {
  study: string
  runs: ComparisonRunSpec[]
  table: string
  aggregate: boolean
  rAvailable: boolean | null
}) {
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [method, setMethod] = useState<ActiveOrdinationMethod>('dbrda')
  const [distance, setDistance] = useState<OrdinationDistance>('bray')
  const [scaling, setScaling] = useState<OrdinationScaling>(2)
  const [permutations, setPermutations] = useState<number>(999)
  const [formula, setFormula] = useState<string>('~ group')
  const [variancePartitioning, setVariancePartitioning] = useState<boolean>(false)
  const [testAxes, setTestAxes] = useState<boolean>(false)
  const [showFeatures, setShowFeatures] = useState<boolean>(false)
  const [cladisticsId, setCladisticsId] = useState<string>('')
  const [cladisticsTrees, setCladisticsTrees] = useState<CladisticsSummary[]>([])
  const [savingDefaults, setSavingDefaults] = useState<boolean>(false)
  const [computing, setComputing] = useState<boolean>(false)
  const [result, setResult] = useState<OrdinationResult | null>(null)
  const reqCounter = useRef(0)
  const loadedStudyCfg = useRef<string | null>(null)

  useEffect(() => {
    reqCounter.current++
    setResult(null)
    setComputing(false)
  }, [study, runs, table, aggregate])

  useEffect(() => {
    if (!open || loadedStudyCfg.current === study) return
    loadedStudyCfg.current = study
    api.config.getStudy(study).then(cfg => {
      const mRaw = String(cfg['analysis.ordination.method']?.value ?? 'none')
      const activeM: ActiveOrdinationMethod =
        (mRaw === 'rda' || mRaw === 'cca' || mRaw === 'cap' || mRaw === 'dbrda') ? mRaw : 'dbrda'
      const dRaw = String(cfg['analysis.ordination.distance']?.value ?? 'bray') as OrdinationDistance
      const compatD = resolveCompatibleDistance(activeM, ALL_DISTANCES.includes(dRaw) ? dRaw : 'bray')
      setMethod(activeM)
      setDistance(compatD)
      const scRaw = Number(cfg['analysis.ordination.scaling']?.value ?? 2)
      setScaling(scRaw === 1 ? 1 : 2)
      const permRaw = Number(cfg['analysis.ordination.permutations']?.value ?? 999)
      if (Number.isInteger(permRaw) && permRaw >= 99 && permRaw <= 9999) setPermutations(permRaw)
      const vpRaw = Boolean(cfg['analysis.ordination.variance_partitioning']?.value ?? false)
      setVariancePartitioning(vpRaw)
      const fRaw = cfg['analysis.ordination.formula']?.value
      if (typeof fRaw === 'string' && fRaw.trim() !== '') setFormula(fRaw)
    }).catch(() => {
      if (loadedStudyCfg.current === study) loadedStudyCfg.current = null
    })
  }, [open, study])

  const needsPhylo = distance === 'weighted_unifrac' || distance === 'unweighted_unifrac'
  useEffect(() => {
    if (!open || !needsPhylo) return
    api.cladistics.list(study)
      .then(items => setCladisticsTrees(items.filter(t => t.built)))
      .catch(() => setCladisticsTrees([]))
  }, [open, needsPhylo, study])

  const handleMethodChange = (next: ActiveOrdinationMethod) => {
    setMethod(next)
    setDistance(prev => resolveCompatibleDistance(next, prev))
  }

  const formulaCheck = useMemo(() => validateOrdinationFormulaSyntax(formula), [formula])
  const permValid = Number.isInteger(permutations) && permutations >= 99 && permutations <= 9999

  const runtimeEst = useMemo(() => estimateOrdinationRuntime({
    method,
    distance,
    nSamples: Math.max(6, runs.length * 6),
    nFeatures: 300,
    permutations: permValid ? permutations : 999,
    nTerms: Math.max(1, formulaCheck.constrainedCount),
    variancePartitioning,
  }), [method, distance, runs.length, permValid, permutations, formulaCheck.constrainedCount, variancePartitioning])

  const availableCovariateChips = result?.available_covariates ?? ['group', 'run', 'log_library_size']

  const appendFormulaToken = (token: string) => {
    setFormula(prev => {
      const trimmed = prev.trim()
      if (!trimmed || trimmed === '~') return `~ ${token}`
      return `${trimmed} + ${token}`
    })
  }

  const saveStudyDefaults = async () => {
    if (!formulaCheck.valid || !permValid) return
    setSavingDefaults(true)
    try {
      await api.config.patchStudy(study, {
        'analysis.ordination.method': method,
        'analysis.ordination.distance': distance,
        'analysis.ordination.scaling': scaling,
        'analysis.ordination.permutations': permutations,
        'analysis.ordination.variance_partitioning': variancePartitioning,
        'analysis.ordination.formula': formula.trim() || null,
      })
      toast.success('Saved constrained ordination defaults to study config')
    } catch (err) {
      toast.error(`Could not save ordination defaults: ${errorMessage(err)}`)
    } finally {
      setSavingDefaults(false)
    }
  }

  const runOrdination = async () => {
    if (!formulaCheck.valid || !permValid) return
    const reqId = ++reqCounter.current
    setComputing(true)
    try {
      const res = await api.analysis.ordination(study, {
        table,
        runs,
        colFilters: {} as Record<string, ColFilter>,
        aggregate,
        method,
        distance,
        scaling,
        permutations,
        formula: formula.trim() || null,
        variance_partitioning: variancePartitioning,
        test_axes: testAxes,
        show_features: showFeatures,
        cladistics_id: needsPhylo && cladisticsId ? cladisticsId : null,
      })
      if (reqId === reqCounter.current) setResult(res)
    } catch (err) {
      if (reqId !== reqCounter.current) return
      setResult(null)
      toast.error(`Constrained ordination failed: ${errorMessage(err)}`)
    } finally {
      if (reqId === reqCounter.current) setComputing(false)
    }
  }

  const methodInfo = getMethodInfo(method)

  return (
    <details
      className="card"
      style={{ marginTop: 14 }}
      open={open}
      onToggle={e => setOpen((e.currentTarget as HTMLDetailsElement).open)}
    >
      <summary style={{ cursor: 'pointer', fontWeight: 600, fontSize: '.9rem', userSelect: 'none' }}>
        Advanced Analysis: Constrained Ordinations (RDA, CCA, CAP, dbRDA)
      </summary>

      <div style={{ marginTop: 12 }}>
        <p style={{ margin: '0 0 12px', fontSize: '.82rem', color: 'var(--color-muted-fg)' }}>
          {methodInfo.summary} <em>{methodInfo.whenToUse}</em>
        </p>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(210px, 1fr))', gap: 10 }}>
          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.8rem' }}>
            <span>Method</span>
            <select
              value={method}
              onChange={e => handleMethodChange(e.target.value as ActiveOrdinationMethod)}
              disabled={computing}
              style={{ padding: '5px 8px', borderRadius: 4, border: '1px solid var(--color-border)', background: 'var(--color-bg)' }}
            >
              {ORDINATION_METHODS_INFO.map(m => (
                <option key={m.id} value={m.id}>{m.label}</option>
              ))}
            </select>
          </label>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.8rem' }}>
            <span>Dissimilarity / Geometry</span>
            <select
              value={distance}
              onChange={e => setDistance(e.target.value as OrdinationDistance)}
              disabled={computing}
              style={{ padding: '5px 8px', borderRadius: 4, border: '1px solid var(--color-border)', background: 'var(--color-bg)' }}
            >
              {ALL_DISTANCES.map(d => {
                const ok = isDistanceCompatible(method, d)
                return (
                  <option key={d} value={d} disabled={!ok}>
                    {ORDINATION_DISTANCE_LABELS[d]}{ok ? '' : ` (incompatible with ${method.toUpperCase()})`}
                  </option>
                )
              })}
            </select>
          </label>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.8rem' }}>
            <span>Biplot Scaling</span>
            <select
              value={scaling}
              onChange={e => setScaling(Number(e.target.value) === 1 ? 1 : 2)}
              disabled={computing}
              style={{ padding: '5px 8px', borderRadius: 4, border: '1px solid var(--color-border)', background: 'var(--color-bg)' }}
            >
              <option value={2}>Scaling 2 — Feature &amp; covariate correlations</option>
              <option value={1}>Scaling 1 — Inter-sample distances</option>
            </select>
          </label>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.8rem' }}>
            <span>Permutations (99–9999)</span>
            <input
              type="number"
              min={99}
              max={9999}
              step={100}
              value={permutations}
              onChange={e => setPermutations(Number(e.target.value))}
              disabled={computing}
              style={{ padding: '5px 8px', borderRadius: 4, border: '1px solid var(--color-border)', background: 'var(--color-bg)' }}
            />
          </label>
        </div>

        <div style={{ marginTop: 10 }}>
          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.8rem' }}>
            <span>Covariate Formula (supports <code>Condition(...)</code> partial ordination)</span>
            <input
              type="text"
              value={formula}
              onChange={e => setFormula(e.target.value)}
              placeholder="~ group + Condition(run)"
              disabled={computing}
              style={{ fontFamily: 'monospace', padding: '6px 8px', borderRadius: 4, border: '1px solid var(--color-border)', background: 'var(--color-bg)' }}
            />
          </label>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center', marginTop: 6, fontSize: '.75rem' }}>
            <span style={{ color: 'var(--color-muted-fg)' }}>Insert term:</span>
            {availableCovariateChips.map(cov => (
              <button
                key={cov}
                type="button"
                className="btn btn-sm"
                style={{ padding: '1px 6px', fontSize: '.73rem', fontFamily: 'monospace' }}
                onClick={() => appendFormulaToken(cov)}
                disabled={computing}
              >
                + {cov}
              </button>
            ))}
            <button
              type="button"
              className="btn btn-sm"
              style={{ padding: '1px 6px', fontSize: '.73rem', fontFamily: 'monospace' }}
              onClick={() => appendFormulaToken('Condition(run)')}
              disabled={computing}
              title="Partial out run/batch differences before constrained ordination"
            >
              + Condition(run)
            </button>
            <button
              type="button"
              className="btn btn-sm"
              style={{ padding: '1px 6px', fontSize: '.73rem', fontFamily: 'monospace' }}
              onClick={() => appendFormulaToken('Condition(log_library_size)')}
              disabled={computing}
              title="Partial out sequencing depth variation before constrained ordination"
            >
              + Condition(log_library_size)
            </button>
          </div>
          {!formulaCheck.valid && (
            <div className="error-msg" style={{ marginTop: 6, fontSize: '.78rem' }}>{formulaCheck.error}</div>
          )}
          {!permValid && (
            <div className="error-msg" style={{ marginTop: 6, fontSize: '.78rem' }}>
              Permutations must be a whole number between 99 and 9999.
            </div>
          )}
        </div>

        {needsPhylo && (
          <div style={{ marginTop: 10, fontSize: '.8rem' }}>
            <label style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <span>ASV Phylogeny (Cladistics build)</span>
              <select
                value={cladisticsId}
                onChange={e => setCladisticsId(e.target.value)}
                disabled={computing}
                style={{ padding: '5px 8px', borderRadius: 4, border: '1px solid var(--color-border)', background: 'var(--color-bg)', maxWidth: 420 }}
              >
                <option value="">Latest completed Cladistics phylogeny (auto)</option>
                {cladisticsTrees.map(t => (
                  <option key={t.id} value={t.id}>
                    {t.name} ({t.id} · {t.asv_count} ASVs)
                  </option>
                ))}
              </select>
            </label>
            {cladisticsTrees.length === 0 && (
              <div style={{ fontSize: '.75rem', color: 'var(--color-warn)', marginTop: 4 }}>
                No completed study Cladistics tree found yet; build an ASV phylogeny in the study Cladistics tab before running UniFrac ordination.
              </div>
            )}
          </div>
        )}

        <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginTop: 10, fontSize: '.8rem' }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <input
              type="checkbox"
              checked={variancePartitioning}
              onChange={e => setVariancePartitioning(e.target.checked)}
              disabled={computing}
            />
            <span>Variance partitioning (<code>vegan::varpart</code>, needs 2–4 covariates)</span>
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <input
              type="checkbox"
              checked={testAxes}
              onChange={e => setTestAxes(e.target.checked)}
              disabled={computing}
            />
            <span>Test individual canonical axes (<code>by = &apos;axis&apos;</code>)</span>
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <input
              type="checkbox"
              checked={showFeatures}
              onChange={e => setShowFeatures(e.target.checked)}
              disabled={computing}
            />
            <span>Overlay top taxon loadings on biplot</span>
          </label>
        </div>

        <div style={{ fontSize: '.76rem', color: 'var(--color-muted-fg)', marginTop: 8 }}>
          {scalingDescription(scaling)}
        </div>

        <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', marginTop: 12 }}>
          <button
            className="btn btn-primary"
            onClick={runOrdination}
            disabled={computing || rAvailable === false || !formulaCheck.valid || !permValid}
          >
            {computing ? 'Running ordination…' : `Run ${method === 'dbrda' ? 'dbRDA' : method.toUpperCase()}`}
          </button>
          <button
            className="btn"
            onClick={saveStudyDefaults}
            disabled={savingDefaults || computing || !formulaCheck.valid || !permValid}
          >
            {savingDefaults ? 'Saving…' : 'Save as study defaults'}
          </button>
          <span
            style={{
              fontSize: '.76rem',
              padding: '2px 8px',
              borderRadius: 12,
              border: '1px solid var(--color-border)',
              color: runtimeEst.warnFiveMinutes ? 'var(--color-warn)' : 'var(--color-muted-fg)',
            }}
          >
            Estimated runtime: {runtimeEst.label}
            {runtimeEst.warnFiveMinutes ? ' (> 5 min warning: consider fewer permutations for exploration)' : ''}
          </span>
        </div>

        {result && <OrdinationResultsView study={study} result={result} />}
        <OrdinationHelpDetails />
      </div>
    </details>
  )
}
