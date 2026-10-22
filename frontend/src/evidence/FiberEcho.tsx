// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// The fibre visualiser, "Echo".
//
// A fibre is the preimage of a projection's value: the rows whose label at a
// rank (or whose category in a set) is one of the chosen values. The chart shows
// the fibre's share of every sample, because that is the quantity a claim about
// enrichment is actually about. The echoes show the same fibre seen through
// another projection - the other classifier, the rank above - so the reader can
// see how far the claim's scope survives a change of method or a coarser view.
// Disagreement is reported, never averaged away.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { PlotlyChart } from '../components/PlotlyChart'
import { Skeleton } from '../components/Skeleton'
import { fibreFigure, formatCount, formatPercent } from './figures'
import { defaultRequest } from './claims'
import { ProjectionControls, rankColumnFor, suggestionsFor } from './ProjectionControls'
import { Badge, Notice, Stat, sectionTitleStyle, tableStyle, tdStyle, thStyle } from './ui'
import type {
  ClaimScope, EvidenceContext, FibreEcho, FibreRequest, FibreResult,
} from './types'

const VERDICT_TONE: Record<string, 'good' | 'warn' | 'bad' | 'neutral'> = {
  concordant: 'good',
  contained: 'good',
  'minor divergence': 'warn',
  'partial agreement': 'warn',
  'inconsistent': 'bad',
  discordant: 'bad',
  disjoint: 'bad',
  empty: 'neutral',
}

const VERDICT_TEXT: Record<string, string> = {
  concordant: 'the echo reproduces the fibre almost exactly',
  'minor divergence': 'the echo mostly agrees, with a small disagreeing part',
  'partial agreement': 'the echo agrees for only part of the fibre; state the claim as method-specific',
  discordant: 'the two projections disagree about most of the fibre; the claim is not safe across methods',
  contained: 'the parent-rank fibre contains the whole fibre, as a taxonomy must',
  inconsistent: 'the parent-rank fibre does not contain the whole fibre',
  disjoint: 'no row of the fibre sits inside the parent-rank fibre',
  empty: 'the fibre has no rows',
}

export function EchoCard({ echo }: { echo: FibreEcho }) {
  const tone = VERDICT_TONE[echo.verdict] ?? 'neutral'
  const title = echo.kind === 'source'
    ? `${echo.label} at ${echo.projection.value}`
    : `Parent rank ${echo.projection.value}`

  return (
    <div style={{ border: '1px solid var(--color-border)', borderRadius: 4, padding: '10px 12px',
                  marginBottom: 8 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
        <strong style={{ fontSize: '.88rem' }}>{title}</strong>
        <Badge tone={tone}>{echo.verdict}</Badge>
      </div>
      <div style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)', margin: '4px 0 8px' }}>
        {VERDICT_TEXT[echo.verdict] ?? echo.verdict}
      </div>

      <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', fontSize: '.8rem' }}>
        <span>{formatPercent(echo.agree_fraction)} of the fibre agrees</span>
        <span>fibre: {formatCount(echo.fibre_rows)} rows · {formatCount(echo.fibre_reads)} reads</span>
        {echo.kind === 'source' ? (
          <>
            <span>conflicting: {formatCount(echo.conflict_rows ?? 0)} rows</span>
            <span>unclassified by the echo: {formatCount(echo.missing_rows ?? 0)} rows</span>
          </>
        ) : (
          <>
            <span>inside the parent fibre: {formatCount(echo.inside_rows ?? 0)} rows</span>
            <span>parent fibre: {formatCount(echo.echo_rows ?? 0)} rows</span>
          </>
        )}
      </div>

      {echo.note && (
        <div style={{ marginTop: 8 }}>
          <Notice tone={tone === 'bad' ? 'bad' : 'warn'}>{echo.note}</Notice>
        </div>
      )}
    </div>
  )
}

interface Props {
  study: string
  run: string
  group?: string | null
  context: EvidenceContext
  /** A scope handed over from the claim editor, which pre-fills the picker. */
  draftScope?: ClaimScope | null
  onUseAsClaim?: (scope: ClaimScope) => void
  /** Called once a handed-over scope has been applied, so it is not reapplied. */
  onDraftConsumed?: () => void
}

export function FiberEcho({ study, run, group, context, draftScope, onUseAsClaim, onDraftConsumed }: Props) {
  const [request, setRequest] = useState<FibreRequest>(() => defaultRequest(context))
  const [result, setResult] = useState<FibreResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [suggestions, setSuggestions] = useState<string[]>([])

  const runKey = `${study}/${group ?? ''}/${run}`
  useEffect(() => {
    setRequest(defaultRequest(context))
    setResult(null)
    setError(null)
    // A refetch of the context must not reset a picker the user is using.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runKey])

  // A scope arriving from the claim editor becomes the picker's state; it is
  // applied only when its identity changes, so typing in the picker is not
  // undone on every render of the parent.
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

  const column = rankColumnFor(context, request)
  useEffect(() => {
    if (!column) { setSuggestions(suggestionsFor(context, request)); return }
    let cancelled = false
    api.results.distinctValues(study, run, request.table, column, undefined, group)
      .then(info => {
        if (cancelled) return
        setSuggestions(info.type === 'text' ? info.values : [])
      })
      .catch(() => { if (!cancelled) setSuggestions([]) })
    return () => { cancelled = true }
  }, [study, run, group, request.table, request.tag, request.value, request.source, column, context])

  const compute = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setResult(await api.evidence.fiber(study, run, request, group))
    } catch (err) {
      setError(errorMessage(err, 'Could not compute the fibre'))
      setResult(null)
    } finally {
      setLoading(false)
    }
  }, [study, run, group, request])

  const figure = useMemo(() => (result ? fibreFigure(result) : null), [result])
  const canCompute = request.values.length > 0 && !!request.value && !loading

  return (
    <div>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>Fibre</div>
        <p style={{ fontSize: '.82rem', color: 'var(--color-muted-fg)', marginBottom: 12 }}>
          The rows whose {request.tag === 'rank' ? 'rank label' : 'category'} is one of the values,
          and the share of each sample they hold. Values are required: a fibre is never everything.
        </p>

        <ProjectionControls context={context} request={request} onChange={setRequest}
          suggestions={suggestions} disabled={loading} idPrefix="fibre" />

        <div style={{ display: 'flex', gap: 8, marginTop: 12, alignItems: 'center' }}>
          <button className="btn btn-primary" onClick={compute} disabled={!canCompute}>
            {loading ? 'Computing…' : 'Compute fibre'}
          </button>
          {onUseAsClaim && result && (
            <button className="btn" onClick={() => onUseAsClaim({
              table: request.table, tag: request.tag, value: request.value,
              source: request.source ?? null, values: [...request.values],
            })}>
              Use this scope in a claim
            </button>
          )}
          {!request.values.length && (
            <span style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)' }}>
              Add at least one value to compute.
            </span>
          )}
        </div>

        {error && <p className="error-msg" style={{ marginTop: 10 }}>{error}</p>}
      </div>

      {loading && !result && <Skeleton lines={4} />}

      {result && (
        <>
          <div className="card">
            <div style={sectionTitleStyle}>Fibre of {result.label} ⊇ {result.values.join(', ')}</div>
            <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', marginBottom: 12 }}>
              <Stat label="Fibre rows" value={formatCount(result.fibre.rows)}
                hint={`${formatPercent(result.fibre.row_share, 2)} of ${formatCount(result.totals.rows)} rows`} />
              <Stat label="Fibre reads" value={formatCount(result.fibre.reads)}
                hint={`${formatPercent(result.fibre.read_share, 2)} of ${formatCount(result.totals.reads)} reads`} />
              <Stat label="Members" value={formatCount(result.member_count)}
                hint={result.members_truncated ? `listing the top ${result.members.length}` : 'all listed'} />
              <Stat label="Classifier" value={result.source ?? 'run default'}
                hint={`column “${result.column}”`} />
            </div>

            {result.fibre.samples.length > 0 && figure && (
              <PlotlyChart figure={figure} heightRatio={0.42} />
            )}

            <table style={tableStyle}>
              <thead>
                <tr>
                  <th style={thStyle}>Sample</th>
                  <th style={thStyle}>Fibre reads</th>
                  <th style={thStyle}>Sample reads</th>
                  <th style={thStyle}>Share</th>
                </tr>
              </thead>
              <tbody>
                {result.fibre.samples.map(s => (
                  <tr key={s.sample}>
                    <td style={tdStyle}>{s.sample}</td>
                    <td style={tdStyle}>{formatCount(s.observed)}</td>
                    <td style={tdStyle}>{formatCount(s.total)}</td>
                    <td style={tdStyle}>{s.percent.toFixed(2)} %</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="card">
            <div style={sectionTitleStyle}>Echo — the fibre seen from elsewhere</div>
            {result.echoes.length === 0 ? (
              <Notice tone="neutral">
                No echo could be computed for this projection. That is not a clean bill of
                health: it means the claim’s scope cannot be checked against a second view.
              </Notice>
            ) : result.echoes.map((echo, i) => (
              <EchoCard key={`${echo.kind}-${echo.label}-${i}`} echo={echo} />
            ))}
            {result.notes.length > 0 && (
              <ul style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)', marginTop: 8, paddingLeft: 18 }}>
                {result.notes.map((n, i) => <li key={i}>{n}</li>)}
              </ul>
            )}
          </div>

          <div className="card">
            <div style={sectionTitleStyle}>
              Members {result.member_count > result.members.length
                ? `(top ${result.members.length} of ${formatCount(result.member_count)} by reads)`
                : `(${formatCount(result.member_count)})`}
            </div>
            {result.members.length === 0 ? (
              <p className="empty-state">This table carries no identity column, so the fibre’s members cannot be listed.</p>
            ) : (
              <table style={tableStyle}>
                <thead>
                  <tr>
                    <th style={thStyle}>Member</th>
                    <th style={thStyle}>Reads</th>
                    <th style={thStyle}>Share of fibre</th>
                  </tr>
                </thead>
                <tbody>
                  {result.members.map(m => (
                    <tr key={m.member}>
                      <td style={tdStyle}>{m.member}</td>
                      <td style={tdStyle}>{formatCount(m.reads)}</td>
                      <td style={tdStyle}>
                        {formatPercent(result.fibre.reads > 0 ? m.reads / result.fibre.reads : 0, 2)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            {result.members_truncated && (
              <p style={{ fontSize: '.76rem', color: 'var(--color-muted-fg)', marginTop: 6 }}>
                The list is capped at {result.members.length} members. The count above is exact;
                open the Tables tab to page through the rest.
              </p>
            )}
          </div>
        </>
      )}
    </div>
  )
}
