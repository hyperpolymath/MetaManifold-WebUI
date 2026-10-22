// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import type {
  CladisticsResult, CountNormalisation, ComparisonRunSpec, PhyloStep,
} from '../api/types'
import { uniqueRuns } from '../api/types'
import { useSharedResultsTablesState } from '../components/annotationShared'
import { PlotlyChart } from '../components/PlotlyChart'
import { useToast } from '../components/Toast'
import { useApi } from '../hooks/useApi'
import { saveBlob } from '../utils/download'
import { useWorkflow } from '../phylogeny/common'
import { CumulativeTree } from './CumulativeTree'
import styles from './Clade.module.css'

const runKey = (run: ComparisonRunSpec) => `${run.group ?? ''}/${run.run}`
const BUILD_STEPS = ['align', 'trim', 'tree'] as const
const csvCell = (value: string | number) => `"${String(value).replace(/"/g, '""')}"`

function FaithChart({ result }: { result: CladisticsResult }) {
  const figure = useMemo(() => ({
    data: [{
      type: 'bar', x: result.samples, y: result.faith_pd,
      marker: { color: '#087f5b' },
      hovertemplate: '%{x}<br>Faith PD %{y:.4f}<extra></extra>',
    }],
    layout: {
      title: { text: "Faith's phylogenetic diversity" },
      yaxis: { title: { text: 'Observed branch length' }, rangemode: 'tozero' },
      xaxis: { title: { text: 'Sample' }, automargin: true },
      showlegend: false,
    },
  }), [result])
  return <PlotlyChart figure={figure} heightRatio={0.42} />
}

function UniFracChart({ result }: { result: CladisticsResult }) {
  const [weighted, setWeighted] = useState(true)
  const matrix = weighted ? result.weighted_unifrac : result.unweighted_unifrac
  const figure = useMemo(() => ({
    data: [{
      type: 'heatmap', z: matrix, x: result.samples, y: result.samples,
      zmin: 0, zmax: 1, colorscale: 'Viridis', reversescale: true,
      colorbar: { title: { text: 'Distance' } },
      hovertemplate: '%{y} vs %{x}<br>UniFrac %{z:.4f}<extra></extra>',
    }],
    layout: {
      title: { text: `${weighted ? 'Weighted' : 'Unweighted'} UniFrac` },
      xaxis: { automargin: true }, yaxis: { automargin: true, autorange: 'reversed' },
      showlegend: false,
    },
  }), [matrix, result.samples, weighted])

  const download = () => {
    const lines = [
      ['Sample', ...result.samples].map(csvCell).join(','),
      ...result.samples.map((sample, i) => [sample, ...matrix[i]].map(csvCell).join(',')),
    ]
    saveBlob(new Blob([lines.join('\n') + '\n'], { type: 'text/csv;charset=utf-8' }),
      `${weighted ? 'weighted' : 'unweighted'}_unifrac.csv`)
  }

  return (
    <div>
      <div className={styles.analysisBar} style={{ marginBottom: 8 }}>
        <div className="tabs" role="group" aria-label="UniFrac method">
          <button className={`tab ${weighted ? 'active' : ''}`} aria-pressed={weighted}
            onClick={() => setWeighted(true)}>Weighted</button>
          <button className={`tab ${!weighted ? 'active' : ''}`} aria-pressed={!weighted}
            onClick={() => setWeighted(false)}>Unweighted</button>
        </div>
        <span style={{ flex: 1 }} />
        <button className="btn btn-sm" onClick={download}>Download distances</button>
      </div>
      {result.samples.length > 1
        ? <PlotlyChart figure={figure} heightRatio={0.72} />
        : <p className="empty-state">UniFrac needs at least two retained samples; Faith PD is still available above.</p>}
      <p style={{ color: 'var(--color-muted-fg)', fontSize: '.78rem' }}>
        {weighted
          ? 'Normalized weighted UniFrac uses cumulative clade relative abundances and ranges from 0 (identical) to 1 (no shared branch abundance).'
          : 'Unweighted UniFrac is unique branch length divided by branch length observed in either sample.'}
      </p>
    </div>
  )
}

/** Build and inspect de novo ASV phylogenies for one study. */
export function CladeCumulusPanel({ study, runs }: { study: string; runs: ComparisonRunSpec[] }) {
  const toast = useToast()
  const listFetcher = useCallback(() => api.cladistics.list(study), [study])
  const { data: analyses, loading, error, refetch } = useApi(listFetcher)
  const load = useCallback((id: string) => api.cladistics.get(study, id), [study])
  const onSettled = useCallback(() => { refetch() }, [refetch])
  const { detail: loadedDetail, open, running } = useWorkflow(load, onSettled)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [excluded, setExcluded] = useState<Set<string>>(new Set())
  const [name, setName] = useState('ASV phylogeny')
  const [table, setTable] = useState<string | null>(null)
  const [maxAsvs, setMaxAsvs] = useState(500)
  const [minReads, setMinReads] = useState(1)
  const [normalisation, setNormalisation] = useState<CountNormalisation>('none')
  const [depth, setDepth] = useState(0)
  const [busy, setBusy] = useState(false)
  const [log, setLog] = useState<{ step: string; text: string } | null>(null)
  const detail = loadedDetail?.doc.id === selectedId ? loadedDetail : null

  const selectedRuns = useMemo(() => uniqueRuns(
    runs.filter(run => !excluded.has(runKey(run))).map(run => ({ run: run.run, group: run.group ?? null })),
  ), [runs, excluded])
  const { options, error: tablesError } = useSharedResultsTablesState(study, selectedRuns)

  useEffect(() => {
    setTable(current => current && options.some(o => o.table === current) ? current : options[0]?.table ?? null)
  }, [options])
  useEffect(() => {
    if (!analyses) return
    setSelectedId(current => current && analyses.some(a => a.id === current)
      ? current
      : analyses[0]?.id ?? null)
  }, [analyses])
  useEffect(() => { open(selectedId).catch(() => {}) }, [selectedId, open])
  useEffect(() => { setLog(null) }, [selectedId])

  const toggleRun = (run: ComparisonRunSpec) => setExcluded(previous => {
    const next = new Set(previous)
    const key = runKey(run)
    if (next.has(key)) next.delete(key)
    else next.add(key)
    return next
  })

  const build = async () => {
    if (!table || selectedRuns.length === 0) return
    setBusy(true)
    try {
      const response = await api.cladistics.create(study, {
        name: name.trim() || 'ASV phylogeny', runs: selectedRuns, table,
        min_reads: minReads, max_asvs: maxAsvs, normalisation, depth,
      })
      setSelectedId(response.id)
      toast.success('ASV phylogeny queued')
      refetch()
    } catch (e) {
      toast.error(`Could not build phylogeny: ${errorMessage(e)}`)
    } finally {
      setBusy(false)
    }
  }

  const remove = async () => {
    if (!detail || !window.confirm(`Delete ${detail.doc.name}, its saved counts and published tree?`)) return
    try {
      await api.cladistics.remove(study, detail.doc.id)
      toast.success('Cladistics analysis deleted')
      setSelectedId(null)
      refetch()
    } catch (e) {
      toast.error(errorMessage(e))
    }
  }

  const showLog = async (step: 'align' | 'trim' | 'tree') => {
    if (!selectedId) return
    try {
      const text = await api.cladistics.log(study, selectedId, step)
      setLog({ step, text: text ?? 'No log has been written for this step yet.' })
    } catch (e) {
      toast.error(errorMessage(e))
    }
  }

  const result = detail?.result ?? null
  const status = detail?.status
  const noRuns = runs.length === 0

  return (
    <div className={styles.panel}>
      <div className="card">
        <div className="card-title">CladeCumulus · de novo ASV phylogeny</div>
        <p style={{ marginTop: 0, color: 'var(--color-muted-fg)', fontSize: '.86rem' }}>
          Align ASV sequences with MAFFT, trim with trimAl and infer a tree with IQ-TREE. The finished analysis adds cumulative clade abundances, Faith&apos;s PD and UniFrac.
        </p>
        {noRuns ? (
          <p className="empty-state">Add a run with an ASV results table before building a phylogeny.</p>
        ) : (
          <>
            <span style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)' }}>Runs (whole runs are pooled)</span>
            <div className={styles.runChips}>
              {uniqueRuns(runs).map(run => {
                const on = !excluded.has(runKey(run))
                return <button key={runKey(run)} className={`${styles.runChip} ${on ? styles.on : ''}`}
                  aria-pressed={on} onClick={() => toggleRun(run)}>
                  {run.group ? `${run.group}/` : ''}{run.run}
                </button>
              })}
            </div>
            <div className={styles.buildGrid}>
              <label className={styles.field}>Analysis name
                <input value={name} maxLength={100} onChange={event => setName(event.target.value)} />
              </label>
              <label className={styles.field}>Results table
                <select value={table ?? ''} disabled={!options.length}
                  onChange={event => setTable(event.target.value)}>
                  {!options.length && <option value="">No shared table</option>}
                  {options.map(option => <option key={option.key} value={option.table}>{option.label}</option>)}
                </select>
              </label>
              <label className={styles.field}>Maximum ASVs
                <input type="number" min={4} max={2000} step={100} value={maxAsvs}
                  onChange={event => setMaxAsvs(Number(event.target.value))} />
              </label>
              <label className={styles.field}>Minimum reads / ASV
                <input type="number" min={1} step={1} value={minReads}
                  onChange={event => setMinReads(Number(event.target.value))} />
              </label>
              <label className={styles.field}>Count normalisation
                <select value={normalisation} onChange={event => setNormalisation(event.target.value as CountNormalisation)}>
                  <option value="none">None</option>
                  <option value="rarefy">Rarefy</option>
                  <option value="srs">SRS</option>
                </select>
              </label>
            </div>
            <div style={{ display: 'flex', alignItems: 'end', gap: 12, flexWrap: 'wrap', marginTop: 12 }}>
              <label className={styles.field} style={{ minWidth: 180 }}>Normalisation depth (0 = auto)
                <input type="number" min={0} step={100} value={depth} disabled={normalisation === 'none'}
                  onChange={event => setDepth(Number(event.target.value))} />
              </label>
              <button className="btn btn-primary" disabled={busy || !table || !selectedRuns.length}
                onClick={build}>{busy ? 'Preparing…' : 'Build ASV tree'}</button>
              <span style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)' }}>
                Highest-abundance ASVs are selected deterministically (4–2,000).
              </span>
            </div>
            {tablesError && <p className="error-msg">Could not list results tables: {tablesError}</p>}
          </>
        )}
        <p className={styles.warning}>
          Short-amplicon phylogenies are approximate, especially at deep branches. Large alignments can be expensive; keep the ASV cap appropriate for your data and compute budget.
        </p>
      </div>

      {loading && <p className="loading">Loading Cladistics analyses…</p>}
      {error && <p className="error-msg">{error}</p>}
      {analyses && analyses.length > 0 && (
        <div className="card">
          <div className={styles.analysisBar}>
            <select className={styles.analysisSelect} aria-label="Cladistics analysis"
              value={selectedId ?? ''} onChange={event => setSelectedId(event.target.value)}>
              {analyses.map(analysis => <option key={analysis.id} value={analysis.id}>
                {analysis.name} · {analysis.asv_count} ASVs · {analysis.state}
              </option>)}
            </select>
            {detail?.summary.published && (
              <Link className="btn btn-sm" to={`/${study}/trees/${encodeURIComponent(detail.summary.published)}`}>
                Full tree viewer
              </Link>
            )}
            {detail && <button className="btn btn-sm btn-danger" disabled={running} onClick={remove}>Delete</button>}
          </div>

          {detail && (
            <>
              <div className={styles.steps}>
                {BUILD_STEPS.map(step => {
                  const state = status?.steps?.[step as PhyloStep]?.state
                  return <span key={step} className={`${styles.step} ${state === 'done' || state === 'current' ? styles.stepDone : state === 'running' ? styles.stepRunning : state === 'failed' ? styles.stepFailed : ''}`}>
                    {step}: {state ?? (running ? 'pending' : detail.summary.state)}
                    {status?.steps?.[step as PhyloStep]?.where && <button className="btn btn-sm" onClick={() => showLog(step)}>Log</button>}
                  </span>
                })}
              </div>
              {status?.error && <pre className={styles.log} style={{ color: 'var(--color-danger)' }}>{status.error}</pre>}
              {log && <pre className={styles.log}><strong>{log.step} log</strong>{'\n'}{log.text}</pre>}
              {running && <p className="loading">Building and analysing the phylogeny…</p>}
            </>
          )}
        </div>
      )}

      {detail && result && (
        <>
          <div className="card">
            <div className={styles.stats}>
              <span><strong>{result.nodes.filter(n => n.is_tip).length}</strong> ASVs</span>
              <span><strong>{result.samples.length}</strong> retained samples</span>
              <span><strong>{detail.doc.source.available_asvs}</strong> eligible ASVs before cap</span>
              <span><strong>{result.normalisation.method}</strong>{result.normalisation.method !== 'none' && ` to ${result.normalisation.depth} reads`}</span>
            </div>
            {result.excluded_samples.length > 0 && (
              <p style={{ color: 'var(--color-muted-fg)', fontSize: '.8rem' }}>
                Excluded empty/short samples: {result.excluded_samples.join(', ')}
              </p>
            )}
            <details style={{ marginTop: 8 }}>
              <summary>Provenance and method</summary>
              <div style={{ marginTop: 8, fontSize: '.8rem' }}>
                <p><strong>Source:</strong> {detail.doc.source.runs.map(run => `${run.group ? `${run.group}/` : ''}${run.run}`).join(', ')} · {detail.doc.source.table}</p>
                <p><strong>Selection:</strong> {detail.doc.source.selection}; minimum {detail.doc.source.min_reads.toLocaleString()} reads; cap {detail.doc.source.max_asvs.toLocaleString()} ASVs.</p>
                <div className={styles.hash}>Counts SHA-256: {result.counts_sha256}</div>
                <div className={styles.hash}>Tree SHA-256: {result.tree_sha256}</div>
                <p style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)' }}>
                  MAFFT → trimAl → IQ-TREE settings, commands, tool versions and output hashes are in this analysis&apos;s attestation.yml. Counts and metrics are pinned to the hashes above.
                </p>
              </div>
            </details>
          </div>
          <div className="card"><CumulativeTree key={result.tree_sha256} nodes={result.nodes} /></div>
          <div className="card"><FaithChart result={result} /></div>
          <div className="card"><UniFracChart result={result} /></div>
          <div className="card">
            <details>
              <summary>Per-sample Faith PD and retained reads</summary>
              <div style={{ overflowX: 'auto', marginTop: 10 }}>
                <table>
                  <thead><tr><th>Sample</th><th>Retained reads</th><th>Faith PD</th></tr></thead>
                  <tbody>{result.samples.map((sample, i) => (
                    <tr key={sample}><td>{sample}</td><td>{result.sample_reads[i].toLocaleString()}</td><td>{result.faith_pd[i].toFixed(5)}</td></tr>
                  ))}</tbody>
                </table>
              </div>
            </details>
          </div>
        </>
      )}
    </div>
  )
}
