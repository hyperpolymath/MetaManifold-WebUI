// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// The residual explorer.
//
// A residual is only meaningful next to the null it is measured against, so the
// null is a first-class control here and its statement travels with the figure.
// Two nulls are offered:
//
//   proportional  the fibre holds the same share of every sample that it holds
//                 of the library as a whole. A large residual then means the
//                 fibre is concentrated in particular samples.
//   claim share   the fibre holds a stated share of every sample. A large
//                 residual then means the claim's stated share does not hold.
//
// The chi-square statistic is descriptive: it is reported with its degrees of
// freedom and no p-value, because this view is a reading aid for a stated claim,
// not a test chosen after looking at the data.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { PlotlyChart } from '../components/PlotlyChart'
import { Skeleton } from '../components/Skeleton'
import { formatCount, formatPercent, formatSigned, residualFigure } from './figures'
import { ProjectionControls, suggestionsFor } from './ProjectionControls'
import { Notice, Stat, sectionTitleStyle, tableStyle, tdStyle, thStyle } from './ui'
import { defaultRequest } from './claims'
import type {
  ClaimScope, EvidenceContext, FibreRequest, ResidualNull, ResidualResult,
} from './types'

interface Props {
  study: string
  run: string
  group?: string | null
  context: EvidenceContext
  draftScope?: ClaimScope | null
  onDraftConsumed?: () => void
}

export function ResidualExplorer({ study, run, group, context, draftScope, onDraftConsumed }: Props) {
  const [request, setRequest] = useState<FibreRequest>(() => defaultRequest(context))
  const [nullKind, setNullKind] = useState<ResidualNull>('proportional')
  const [shareInput, setShareInput] = useState('20')
  const [result, setResult] = useState<ResidualResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const runKey = `${study}/${group ?? ''}/${run}`
  useEffect(() => {
    setRequest(defaultRequest(context))
    setResult(null)
    setError(null)
    // A refetch of the context must not reset a picker the user is using.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runKey])

  const draftKey = draftScope
    ? JSON.stringify([draftScope.table, draftScope.tag, draftScope.value, draftScope.source, draftScope.values])
    : null
  useEffect(() => {
    if (!draftScope) return
    setRequest({
      table: draftScope.table, tag: draftScope.tag, value: draftScope.value,
      source: draftScope.source, values: [...draftScope.values],
    })
    setResult(null)
    onDraftConsumed?.()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draftKey])

  const share = Number(shareInput) / 100
  const shareValid = nullKind === 'proportional' || (Number.isFinite(share) && share > 0 && share <= 1)

  const compute = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setResult(await api.evidence.residuals(study, run, {
        ...request,
        null: nullKind,
        share: nullKind === 'claim_share' ? share : null,
      }, group))
    } catch (err) {
      setError(errorMessage(err, 'Could not compute the residuals'))
      setResult(null)
    } finally {
      setLoading(false)
    }
  }, [study, run, group, request, nullKind, share])

  const figure = useMemo(() => (result ? residualFigure(result) : null), [result])
  const canCompute = request.values.length > 0 && !!request.value && shareValid && !loading

  const field: React.CSSProperties = { display: 'flex', flexDirection: 'column', minWidth: 140 }
  const select: React.CSSProperties = {
    padding: '4px 6px', borderRadius: 4, border: '1px solid var(--color-border)',
    background: 'var(--color-bg)', color: 'var(--color-fg)', fontSize: '.85rem',
  }
  const labelStyle: React.CSSProperties = {
    fontSize: '.8rem', color: 'var(--color-muted-fg)', display: 'block', marginBottom: 2,
  }

  return (
    <div>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>Residuals</div>
        <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)', marginBottom: 12 }}>
          Where the fibre departs from a declared null, sample by sample. A residual is
          (observed − expected) / √expected, so a value beyond ±2 is worth reading and is not by
          itself evidence of anything.
        </p>

        <ProjectionControls context={context} request={request} onChange={setRequest}
          suggestions={suggestionsFor(context, request)} disabled={loading} idPrefix="residual" />

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'flex-end', marginTop: 12 }}>
          <div style={field}>
            <label style={labelStyle} htmlFor="residual-null">Null</label>
            <select id="residual-null" value={nullKind} style={select} disabled={loading}
              onChange={e => setNullKind(e.target.value as ResidualNull)}>
              <option value="proportional">proportional (library distribution)</option>
              <option value="claim_share">claim share (stated % of each sample)</option>
            </select>
          </div>
          {nullKind === 'claim_share' && (
            <div style={field}>
              <label style={labelStyle} htmlFor="residual-share">Stated share (%)</label>
              <input id="residual-share" type="number" min={0.01} max={100} step={0.1}
                value={shareInput} disabled={loading}
                onChange={e => setShareInput(e.target.value)}
                style={select} />
            </div>
          )}
          <button className="btn btn-primary" onClick={compute} disabled={!canCompute}>
            {loading ? 'Computing…' : 'Compute residuals'}
          </button>
          {!shareValid && (
            <span style={{ fontSize: '.78rem', color: 'var(--color-accent-danger, #c92a2a)' }}>
              The stated share must be between 0 and 100 %.
            </span>
          )}
        </div>

        {error && <p className="error-msg" style={{ marginTop: 10 }}>{error}</p>}
      </div>

      {loading && !result && <Skeleton lines={4} />}

      {result && (
        <>
          <div className="card">
            <div style={sectionTitleStyle}>Summary</div>
            <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', marginBottom: 12 }}>
              <Stat label="χ² (Pearson)" value={result.summary.chi2.toFixed(2)}
                hint={`${result.summary.df} degrees of freedom`} />
              <Stat label="Samples ±2" value={`${result.summary.n_excess} high · ${result.summary.n_deficit} low`}
                hint={`of ${result.summary.n_usable} with a positive expectation`} />
              <Stat label="Largest |residual|" value={result.summary.max_abs_residual.toFixed(2)}
                hint="the worst case below" />
              <Stat label="Fibre share" value={formatPercent(result.fibre.read_share, 2)}
                hint={`${formatCount(result.fibre.reads)} of ${formatCount(result.grand.reads)} reads`} />
            </div>
            <Notice tone="neutral">{result.null.note}</Notice>
            {figure && <PlotlyChart figure={figure} heightRatio={0.42} />}
          </div>

          <div className="card">
            <div style={sectionTitleStyle}>Samples, worst departure first</div>
            <table style={tableStyle}>
              <thead>
                <tr>
                  <th style={thStyle}>Sample</th>
                  <th style={thStyle}>Observed</th>
                  <th style={thStyle}>Expected</th>
                  <th style={thStyle}>Residual</th>
                  <th style={thStyle}>log2 ratio</th>
                  <th style={thStyle}>Sample reads</th>
                </tr>
              </thead>
              <tbody>
                {result.samples.map(s => (
                  <tr key={s.sample}>
                    <td style={tdStyle}>{s.sample}</td>
                    <td style={tdStyle}>{formatCount(s.observed)}</td>
                    <td style={tdStyle}>{s.expected.toFixed(1)}</td>
                    <td style={tdStyle}>{formatSigned(s.residual)}</td>
                    <td style={tdStyle}>{formatSigned(s.log2_ratio)}</td>
                    <td style={tdStyle}>{formatCount(s.total)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p style={{ fontSize: '.76rem', color: 'var(--color-muted-fg)', marginTop: 8 }}>
              log2 ratio uses a half-read pseudocount, so a sample with no fibre reads stays finite
              and is not reported as negative infinity.
            </p>
          </div>
        </>
      )}
    </div>
  )
}
