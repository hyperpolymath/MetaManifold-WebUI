// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// Evidence Mode for one run: the full surface, not a gated preview.
//
// Three views over one record:
//   Claims      the epistemic editor - what is asserted, about which fibre, and
//               on what warrant.
//   Fibre/Echo  the sub-population a claim is about, and the same fibre seen
//               through another projection.
//   Residuals   where the fibre departs from a declared null.
//
// The provenance card is not decoration. A claim about a run whose attestation
// is absent, degraded, or internally inconsistent is a claim of unknown
// software lineage, and the record says so at the top rather than in a footnote.

import { useCallback, useMemo, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import { Skeleton } from '../components/Skeleton'
import { ClaimEditor } from './ClaimEditor'
import { FiberEcho } from './FiberEcho'
import { ResidualExplorer } from './ResidualExplorer'
import { Badge, Notice, Stat, sectionTitleStyle, tableStyle, tdStyle, thStyle } from './ui'
import { claimCountByStatus } from './claims'
import type { ClaimScope, EvidenceContext } from './types'

type View = 'claims' | 'fibre' | 'residuals'

const VIEWS: { id: View; label: string }[] = [
  { id: 'claims', label: 'Claims' },
  { id: 'fibre', label: 'Fibre & echo' },
  { id: 'residuals', label: 'Residuals' },
]

function ProvenanceCard({ context }: { context: EvidenceContext }) {
  const p = context.provenance
  return (
    <div className="card">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, marginBottom: 8 }}>
        <div className="card-title" style={{ margin: 0 }}>Provenance</div>
        {!p.present ? <Badge tone="bad">not recorded</Badge>
          : p.readable === false ? <Badge tone="bad">unreadable</Badge>
          : p.degraded ? <Badge tone="warn">degraded</Badge>
          : p.uniform === false ? <Badge tone="warn">stages disagree</Badge>
          : <Badge tone="good">recorded</Badge>}
      </div>

      {!p.present && (
        <Notice tone="bad">
          This run has no <code>{p.file}</code>. There is no record of which software produced
          its outputs, so a claim about them cannot name its instrument. Re-run a stage to
          record one before treating these results as evidence.
        </Notice>
      )}

      {p.present && p.readable === false && (
        <Notice tone="bad">
          <code>{p.file}</code> exists but could not be read. Treat the run's outputs as
          unattributed until it parses.
        </Notice>
      )}

      {p.present && p.readable !== false && (
        <>
          {p.degraded && (
            <div style={{ marginBottom: 8 }}>
              <Notice tone="warn">
                The run is <strong>degraded</strong>: {(p.degraded_components ?? []).join(', ') || 'one or more components'}
                {' '}could not be proved. Outputs are not fully attributable.
              </Notice>
            </div>
          )}
          {p.uniform === false && (
            <div style={{ marginBottom: 8 }}>
              <Notice tone="warn">
                Stages of this run disagree about {(p.divergent ?? []).join(', ') || 'their environment'}.
                The per-stage records are authoritative; one environment does not describe the run.
              </Notice>
            </div>
          )}

          <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', marginBottom: 10 }}>
            <Stat label="Generated" value={p.generated || '—'} />
            <Stat label="MetaManifold"
              value={(p.metamanifold?.git_sha || '—').slice(0, 12)}
              hint={p.metamanifold?.git_dirty ? 'dirty tree' : undefined} />
            <Stat label="Tools recorded" value={p.tools?.length ?? 0} />
            <Stat label="Stages recorded" value={p.stages?.length ?? 0} />
          </div>

          {(p.tools?.length ?? 0) > 0 && (
            <>
              <div style={sectionTitleStyle}>Tools</div>
              <table style={tableStyle}>
                <thead>
                  <tr>
                    <th style={thStyle}>Tool</th>
                    <th style={thStyle}>Version</th>
                    <th style={thStyle}>SHA-256</th>
                  </tr>
                </thead>
                <tbody>
                  {(p.tools ?? []).map(t => (
                    <tr key={t.name}>
                      <td style={tdStyle}>{t.name}</td>
                      <td style={tdStyle}>{t.version}</td>
                      <td style={tdStyle}><code>{t.sha256}</code></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}

          {(p.databases?.length ?? 0) > 0 && (
            <div style={{ marginTop: 10, fontSize: '.8rem' }}>
              <span style={{ color: 'var(--color-muted-fg)' }}>Databases: </span>
              {(p.databases ?? []).map(d => `${d.name} ${d.release}`).join(' · ')}
            </div>
          )}

          {(p.stages?.length ?? 0) > 0 && (
            <div style={{ marginTop: 6, fontSize: '.8rem' }}>
              <span style={{ color: 'var(--color-muted-fg)' }}>Latest stages: </span>
              {(p.stages ?? []).slice(-4).map(s => `${s.name} (${s.status})`).join(' · ')}
            </div>
          )}
        </>
      )}
    </div>
  )
}

export function EvidencePanel({ study, run, group }: {
  study: string
  run: string
  group?: string | null
}) {
  const [view, setView] = useState<View>('claims')
  const [claimScope, setClaimScope] = useState<ClaimScope | null>(null)
  const [fibreScope, setFibreScope] = useState<ClaimScope | null>(null)

  const runKey = `${study}/${group ?? ''}/${run}`
  const fetcher = useCallback(
    () => api.evidence.context(study, run, group),
    [study, run, group],
  )
  const { data: context, loading, error, refetch } = useApi(fetcher, runKey)

  const counts = useMemo(
    () => claimCountByStatus(context?.claims ?? []),
    [context?.claims],
  )

  const handleUseInFibre = useCallback((scope: ClaimScope) => {
    setFibreScope(scope)
    setView('fibre')
  }, [])

  const handleUseAsClaim = useCallback((scope: ClaimScope) => {
    setClaimScope(scope)
    setView('claims')
  }, [])

  if (loading && !context) return <Skeleton lines={5} />
  if (error) return <p className="error-msg">{error}</p>
  if (!context) return null

  return (
    <div>
      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12, flexWrap: 'wrap' }}>
          <div>
            <div className="card-title" style={{ marginBottom: 2 }}>Evidence record</div>
            <div style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)' }}>
              <code>{context.file}</code>
              {context.updated ? ` · updated ${context.updated}` : ' · not written yet'}
            </div>
          </div>
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            <Stat label="Claims" value={context.claims.length} />
            <Stat label="Supported" value={counts.supported} />
            <Stat label="Contested" value={counts.contested} />
            <Stat label="Draft" value={counts.draft} />
          </div>
        </div>

        {context.no_results && (
          <div style={{ marginTop: 10 }}>
            <Notice tone="warn">
              This run has no results database yet. Claims can be drafted, but no fibre or
              residual can be computed until the pipeline has produced a merged table.
            </Notice>
          </div>
        )}
      </div>

      <ProvenanceCard context={context} />

      <div className="tabs">
        {VIEWS.map(v => (
          <button key={v.id} className={`tab ${view === v.id ? 'active' : ''}`}
            onClick={() => setView(v.id)}>
            {v.label}
          </button>
        ))}
      </div>

      {view === 'claims' && (
        <ClaimEditor
          study={study} run={run} group={group}
          context={context}
          draftScope={claimScope}
          onSaved={refetch}
          onUseInFibre={handleUseInFibre}
          onDraftConsumed={() => setClaimScope(null)}
        />
      )}

      {view === 'fibre' && (
        <FiberEcho
          study={study} run={run} group={group}
          context={context}
          draftScope={fibreScope}
          onUseAsClaim={handleUseAsClaim}
          onDraftConsumed={() => setFibreScope(null)}
        />
      )}

      {view === 'residuals' && (
        <ResidualExplorer
          study={study} run={run} group={group}
          context={context}
          draftScope={fibreScope}
          onDraftConsumed={() => setFibreScope(null)}
        />
      )}
    </div>
  )
}
