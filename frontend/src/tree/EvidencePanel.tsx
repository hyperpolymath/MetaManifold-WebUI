// SPDX-License-Identifier: MPL-2.0
import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../api/client'
import type { EvidenceResponse } from './evidence'

export function EvidencePanel({ study, file, sha256, onEvidence }: {
  study: string; file: string; sha256: string; onEvidence: (value: EvidenceResponse | null) => void
}) {
  const [data, setData] = useState<EvidenceResponse | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [threshold, setThreshold] = useState('0.95')
  const [confirmRaw, setConfirmRaw] = useState(false)
  const [target, setTarget] = useState('')
  const [enabled, setEnabled] = useState(false)
  const [limit, setLimit] = useState(100)
  const requestId = useRef(0)
  const generating = useRef(false)
  const accept = useCallback((value: EvidenceResponse) => {
    const current = value.state === 'ready' && value.source_sha256 !== sha256
      ? { state: 'stale' as const, message: 'Tree changed. Reload this page before displaying evidence.' } : value
    setData(current)
  }, [sha256])

  useEffect(() => {
    onEvidence(enabled && !busy && !error && data?.state === 'ready' ? data : null)
  }, [data, enabled, busy, error, onEvidence])

  useEffect(() => {
    let cancelled = false
    const refresh = async () => {
      if (generating.current) return
      const id = ++requestId.current
      try {
        const value = await api.trees.evidence(study, file)
        if (!cancelled && id === requestId.current) { setError(''); accept(value) }
      } catch (e) {
        if (!cancelled && id === requestId.current) { setError((e as Error).message); setData(null) }
      }
    }
    void refresh()
    const timer = window.setInterval(refresh, 15000)
    window.addEventListener('focus', refresh)
    return () => { cancelled = true; requestId.current++; window.clearInterval(timer); window.removeEventListener('focus', refresh) }
  }, [study, file, accept, onEvidence])

  const generate = async () => {
    generating.current = true
    const id = ++requestId.current
    setBusy(true); setError(''); onEvidence(null)
    try {
      const value = await api.trees.generateEvidence(study, file, {
        source_sha256: sha256, threshold: Number(threshold), confirm_raw: confirmRaw,
        accumulated_file: target || null,
      })
      if (id === requestId.current) accept(value)
    } catch (e) { if (id === requestId.current) { setError((e as Error).message); setData(null) } }
    finally { generating.current = false; if (id === requestId.current) setBusy(false) }
  }
  const result = data?.state === 'ready' ? data.result : null
  const queries = result?.queries ?? []
  const mappings = new Map(data?.mapping?.map(m => [m.raw_ordinal, m]))
  const counts = (['holds', 'fails', 'undecided'] as const).map(v => `${queries.filter(q => q.verdict === v).length} ${v}`).join(' · ')
  return <details style={{ marginBlock: 12 }}>
    <summary>Placement evidence{result ? ` · ${counts}` : ` · ${data?.state ?? 'loading'}`}</summary>
    <p>Raw best-placement LWR meets threshold. LWR is a likelihood weight, not a probability that the placement is correct.</p>
    <p role="status">{data?.message}{error && <span className="error-msg"> {error}</span>}</p>
    {data?.role === 'accumulated' && <p>Raw LWR evidence, mapped here. Generate or change the threshold in <a href={`/${encodeURIComponent(study)}/trees/${encodeURIComponent(data.raw_file ?? '')}`}>{data.raw_file}</a>.</p>}
    {data?.role !== 'accumulated' && data?.state !== 'not_applicable' && <fieldset disabled={busy}>
      <legend>Calculate raw evidence</legend>
      <label>Threshold <input type="number" min="0.000001" max="1" step="0.01" value={threshold} onChange={e => setThreshold(e.target.value)} /></label>
      {!data?.role && <>
        <label style={{ display: 'block' }}><input type="checkbox" checked={confirmRaw} onChange={e => setConfirmRaw(e.target.checked)} /> I confirm this imported file contains raw placements.</label>
        <label>Accumulated file, if explicitly paired <input value={target} onChange={e => setTarget(e.target.value)} placeholder="Optional exact filename" /></label>
      </>}
      <button className="btn" disabled={(!data?.role && !confirmRaw) || !Number.isFinite(Number(threshold)) || Number(threshold) <= 0 || Number(threshold) > 1} onClick={generate}>{busy ? 'Calculating…' : 'Generate evidence'}</button>
    </fieldset>}
    {result && <>
      <label><input type="checkbox" checked={enabled} onChange={e => setEnabled(e.target.checked)} /> Show evidence markers (✓ holds / ✕ fails / ? undecided)</label>
      <p>Threshold ≥ {result.threshold}; input weight-sum tolerance {result.tolerance}. {result.assurance}.</p>
      {data?.mapping_reason && <p className="error-msg">Mapping unavailable: {data.mapping_reason}</p>}
      <details><summary>All {queries.length} raw query results, including hidden and unmapped queries</summary>
        <div style={{ maxHeight: 320, overflow: 'auto' }}><table><thead><tr><th>Query</th><th>Verdict</th><th>Raw maximum LWR</th><th>Reason / mapping</th></tr></thead><tbody>
          {queries.slice(0, limit).map(q => <tr key={q.key}>
            <td>{q.aliases.map(a => `${a.name} (×${a.multiplicity})`).join(', ') || `Query ${q.ordinal + 1}`}</td>
            <td>{q.verdict}</td><td>{q.value ?? 'Unavailable'}{q.best.length > 1 && ` (${q.best.length} tied candidates)`}</td>
            <td>{q.reason}{mappings.get(q.ordinal)?.reason}</td>
          </tr>)}
        </tbody></table></div>
        {limit < queries.length && <button className="btn" onClick={() => setLimit(n => n + 100)}>Show next 100 queries ({queries.length - limit} remaining)</button>}
      </details>
      <details><summary>Source and provenance</summary><p>Raw source: {data?.raw_file}; SHA-256: <code>{result.source_sha256}</code></p><p>Checker: {result.checker}. Imported files have no inferred run, configuration, seed or tool provenance.</p><pre style={{ maxHeight: 200, overflow: 'auto' }}>{JSON.stringify(data?.provenance, null, 2)}</pre></details>
    </>}
  </details>
}
