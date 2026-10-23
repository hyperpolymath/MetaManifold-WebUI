// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import type {
  CladeCumulusResponse,
  CladeCumulusSourcesResponse,
  CladeHierarchyMode,
  CladeMoveValidationResponse,
  CladeNodeData,
  CladeTreeSource,
} from '../api/types'
import { saveBlob } from '../utils/download'
import { AnalysisChart } from './AnalysisChart'
import { useToast } from './Toast'
import {
  EPISTEMIC_META,
  collectAllCladeIds,
  flattenCladeTree,
  formatDistanceMatrixCsv,
  preflightCladeMove,
} from './cladeCumulusModel'

export interface CladeCumulusRunOption {
  run: string
  group: string | null
}

export interface CladeCumulusPanelProps {
  study: string
  runs: CladeCumulusRunOption[]
}

export function CladeCumulusPanel({ study, runs }: CladeCumulusPanelProps) {
  const toast = useToast()
  const reqCounter = useRef(0)

  const [selectedRunIdx, setSelectedRunIdx] = useState(0)
  const selectedRun = runs[selectedRunIdx] ?? null

  const [sources, setSources] = useState<CladeCumulusSourcesResponse | null>(null)
  const [sourcesError, setSourcesError] = useState<string | null>(null)

  const [table, setTable] = useState('merged')
  const [mode, setMode] = useState<CladeHierarchyMode>('combined')
  const [treeSource, setTreeSource] = useState<CladeTreeSource>('auto')
  const [treeFile, setTreeFile] = useState('')
  const [maxAsvs, setMaxAsvs] = useState(500)
  const [supportThreshold, setSupportThreshold] = useState(0.8)
  const [lwrThreshold, setLwrThreshold] = useState(0.95)

  const [result, setResult] = useState<CladeCumulusResponse | null>(null)
  const [computedSnapshot, setComputedSnapshot] = useState<{
    run: string
    group: string | null
    request: {
      table: string
      mode: CladeHierarchyMode
      treeSource: CladeTreeSource
      treeFile?: string
      maxAsvs: number
      supportThreshold: number
      lwrThreshold: number
    }
  } | null>(null)
  const [loading, setLoading] = useState(false)
  const [computeError, setComputeError] = useState<string | null>(null)

  // Interactive clade expansion + non-destructive drag-and-drop / form move state
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set())
  const [dragSourceId, setDragSourceId] = useState<string | null>(null)
  const [moveSourceId, setMoveSourceId] = useState('')
  const [moveTargetId, setMoveTargetId] = useState('')
  const [moveVerdict, setMoveVerdict] = useState<CladeMoveValidationResponse | null>(null)
  const [validatingMove, setValidatingMove] = useState(false)
  const [showProposed, setShowProposed] = useState(false)
  const [unifracKind, setUnifracKind] = useState<'weighted' | 'normalized_weighted' | 'unweighted'>('normalized_weighted')

  useEffect(() => {
    if (!selectedRun) {
      setSources(null)
      return
    }
    let cancelled = false
    setSourcesError(null)
    api.cladeCumulus
      .sources(study, selectedRun.run, selectedRun.group)
      .then(s => {
        if (cancelled) return
        setSources(s)
        if (s.tables.length > 0 && !s.tables.some(t => t.table === table)) {
          setTable(s.tables[0].table)
        }
        if (s.trees.length > 0 && !treeFile) {
          setTreeFile(s.trees[0].file)
        }
      })
      .catch(err => {
        if (!cancelled) setSourcesError(errorMessage(err))
      })
    return () => {
      cancelled = true
    }
  }, [study, selectedRun])

  const computeExplorer = useCallback(async () => {
    if (!selectedRun) return
    const ticket = ++reqCounter.current
    const reqSnapshot = {
      table,
      mode,
      treeSource,
      treeFile: treeSource === 'study_tree' ? treeFile : undefined,
      maxAsvs,
      supportThreshold,
      lwrThreshold,
    }
    setLoading(true)
    setComputeError(null)
    setMoveVerdict(null)
    setShowProposed(false)
    try {
      const resp = await api.cladeCumulus.compute(
        study,
        selectedRun.run,
        reqSnapshot,
        selectedRun.group,
      )
      if (ticket !== reqCounter.current) return
      setResult(resp)
      setComputedSnapshot({
        run: selectedRun.run,
        group: selectedRun.group,
        request: reqSnapshot,
      })
      setExpandedIds(collectAllCladeIds(resp.root))
    } catch (err) {
      if (ticket !== reqCounter.current) return
      setComputeError(errorMessage(err))
    } finally {
      if (ticket === reqCounter.current) setLoading(false)
    }
  }, [study, selectedRun, table, mode, treeSource, treeFile, maxAsvs, supportThreshold, lwrThreshold])

  const displayedRoot: CladeNodeData | null = useMemo(() => {
    if (!result) return null
    if (showProposed && moveVerdict?.allowed && moveVerdict.proposed_root) {
      return moveVerdict.proposed_root
    }
    return result.root
  }, [result, showProposed, moveVerdict])

  const displayedFigure = useMemo(() => {
    if (!result) return null
    if (showProposed && moveVerdict?.allowed && moveVerdict.proposed_plotly) {
      return moveVerdict.proposed_plotly
    }
    return result.plotly
  }, [result, showProposed, moveVerdict])

  const flatRows = useMemo(
    () => (displayedRoot ? flattenCladeTree(displayedRoot, expandedIds) : []),
    [displayedRoot, expandedIds],
  )

  const allNodesFlat = useMemo(
    () => (result ? flattenCladeTree(result.root) : []),
    [result],
  )

  const controlsDirty = useMemo(() => {
    if (!computedSnapshot || !selectedRun) return false
    const expectedTree = treeSource === 'study_tree' ? treeFile : undefined
    return (
      computedSnapshot.run !== selectedRun.run ||
      computedSnapshot.group !== selectedRun.group ||
      computedSnapshot.request.table !== table ||
      computedSnapshot.request.mode !== mode ||
      computedSnapshot.request.treeSource !== treeSource ||
      computedSnapshot.request.treeFile !== expectedTree ||
      computedSnapshot.request.maxAsvs !== maxAsvs ||
      computedSnapshot.request.supportThreshold !== supportThreshold ||
      computedSnapshot.request.lwrThreshold !== lwrThreshold
    )
  }, [computedSnapshot, selectedRun, table, mode, treeSource, treeFile, maxAsvs, supportThreshold, lwrThreshold])

  const submitMoveValidation = useCallback(
    async (sourceId: string, targetId: string, saveProposal = false) => {
      if (!computedSnapshot || !result) return
      const pre = preflightCladeMove(result.root, sourceId, targetId)
      if (!pre.structurallyValid) {
        setMoveVerdict({
          allowed: false,
          source_id: sourceId,
          target_id: targetId,
          target_status: 'rejected_local',
          target_colour: '#c62828',
          reason: pre.reason ?? 'Invalid clade move.',
          proposal_file: null,
          proposed_root: null,
        })
        return
      }
      setValidatingMove(true)
      try {
        const res = await api.cladeCumulus.validateMove(
          study,
          computedSnapshot.run,
          {
            sourceId,
            targetId,
            saveProposal,
            ...computedSnapshot.request,
          },
          computedSnapshot.group,
        )
        setMoveVerdict(res)
        if (res.allowed) {
          setShowProposed(true)
          if (saveProposal && res.proposal_file) {
            toast.success(`Saved non-destructive sidecar ${res.proposal_file}`)
          }
        }
      } catch (err) {
        toast.error(`Move check failed: ${errorMessage(err)}`)
      } finally {
        setValidatingMove(false)
      }
    },
    [study, computedSnapshot, result, toast],
  )

  const toggleExpand = (id: string) => {
    setExpandedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const activeMatrix = useMemo(() => {
    const div = result?.diversity
    if (!div) return null
    if (unifracKind === 'unweighted') return div.unweighted_unifrac
    if (unifracKind === 'weighted') return div.weighted_unifrac
    return div.normalized_weighted_unifrac
  }, [result, unifracKind])

  const exportMatrixCsv = () => {
    if (!result?.diversity || !activeMatrix) return
    const csv = formatDistanceMatrixCsv(result.diversity.samples, activeMatrix)
    saveBlob(
      new Blob([csv], { type: 'text/csv;charset=utf-8' }),
      `${study}_${result.run}_${unifracKind}_unifrac.csv`,
    )
  }

  if (runs.length === 0) {
    return (
      <div className="study-card" style={{ marginBottom: 20 }}>
        <p style={{ margin: 0, color: 'var(--color-muted-fg)' }}>
          Add at least one run with results tables to explore CladeCumulus phylogenies and diversity metrics.
        </p>
      </div>
    )
  }

  return (
    <section
      aria-label="CladeCumulus phylogenetic and epistemic explorer"
      style={{
        padding: 16,
        marginBottom: 24,
        borderRadius: 8,
        border: '1px solid var(--color-border, #d0d7de)',
        background: 'var(--color-bg, #ffffff)',
      }}
    >
      {/* Controls bar */}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'flex-end', marginBottom: 14 }}>
        <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
          <span>Run</span>
          <select
            value={selectedRunIdx}
            onChange={e => setSelectedRunIdx(Number(e.target.value))}
          >
            {runs.map((r, idx) => (
              <option key={`${r.group ?? ''}:${r.run}`} value={idx}>
                {r.group ? `${r.group} / ${r.run}` : r.run}
              </option>
            ))}
          </select>
        </label>

        <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
          <span>Results table</span>
          <select value={table} onChange={e => setTable(e.target.value)}>
            {(sources?.tables.length ? sources.tables : [{ table: 'merged', row_count: 0, sample_count: 0, has_sequence: false, ranks: [] }]).map(t => (
              <option key={t.table} value={t.table}>
                {t.table} {t.row_count ? `(${t.row_count} ASVs)` : ''}
              </option>
            ))}
          </select>
        </label>

        <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
          <span>Hierarchy mode</span>
          <select value={mode} onChange={e => setMode(e.target.value as CladeHierarchyMode)}>
            <option value="combined">Combined (Phylogeny + Taxonomy)</option>
            <option value="phylogenetic">Phylogenetic branches only</option>
            <option value="taxonomic">Taxonomic ranks only</option>
          </select>
        </label>

        {mode !== 'taxonomic' && (
          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
            <span>Phylogeny source</span>
            <select value={treeSource} onChange={e => setTreeSource(e.target.value as CladeTreeSource)}>
              <option value="auto">Auto (FastTree → IQ-TREE → JC69 NJ)</option>
              <option value="study_tree">Existing study tree (.nwk / .jplace)</option>
              <option value="build_fasttree">Build from ASVs via FastTree</option>
              <option value="build_iqtree">Build from ASVs via IQ-TREE 3</option>
              <option value="build_nj">Build from ASVs via JC69 Neighbor-Joining</option>
            </select>
          </label>
        )}

        {mode !== 'taxonomic' && treeSource === 'study_tree' && (
          <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
            <span>Study tree file</span>
            <select value={treeFile} onChange={e => setTreeFile(e.target.value)}>
              {(sources?.trees ?? []).map(tf => (
                <option key={tf.file} value={tf.file}>
                  {tf.file} ({tf.format})
                </option>
              ))}
            </select>
          </label>
        )}

        <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
          <span>Max ASVs guard</span>
          <input
            type="number"
            min={3}
            max={50000}
            step={50}
            value={maxAsvs}
            onChange={e => setMaxAsvs(Math.max(3, Number(e.target.value) || 500))}
            style={{ width: 92 }}
          />
        </label>

        <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
          <span>Support threshold</span>
          <input
            type="number"
            min={0}
            max={1}
            step={0.05}
            value={supportThreshold}
            onChange={e => setSupportThreshold(Math.min(1, Math.max(0, Number(e.target.value) || 0)))}
            style={{ width: 78 }}
          />
        </label>

        <label style={{ display: 'flex', flexDirection: 'column', gap: 4, fontSize: '.82rem' }}>
          <span>LWR threshold</span>
          <input
            type="number"
            min={0.05}
            max={1}
            step={0.05}
            value={lwrThreshold}
            onChange={e => setLwrThreshold(Math.min(1, Math.max(0.05, Number(e.target.value) || 0.95)))}
            style={{ width: 78 }}
          />
        </label>

        <button
          type="button"
          className="btn btn-primary"
          disabled={loading}
          onClick={computeExplorer}
        >
          {loading ? 'Computing phylogeny…' : 'Compute CladeCumulus'}
        </button>
      </div>

      {/* Probed external binary summary */}
      {sources && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, fontSize: '.78rem', color: 'var(--color-muted-fg)', marginBottom: 12 }}>
          <span>Probed toolchain:</span>
          {sources.tools.map(t => (
            <span key={t.key}>
              <strong>{t.key}</strong>: {t.available ? `v${t.version ?? 'detected'}` : 'not installed (fallback active)'}
            </span>
          ))}
        </div>
      )}

      {sourcesError && <p className="error-msg">{sourcesError}</p>}
      {computeError && <p className="error-msg">{computeError}</p>}

      {/* Explicit epistemic colour legend with non-colour symbols */}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 14, padding: '8px 10px', borderRadius: 6, background: 'var(--color-surface, #f6f8fa)', marginBottom: 14, fontSize: '.8rem' }}>
        {(Object.keys(EPISTEMIC_META) as (keyof typeof EPISTEMIC_META)[]).map(key => {
          const m = EPISTEMIC_META[key]
          return (
            <span key={key} title={m.summary} style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
              <span style={{ color: m.colour, fontWeight: 700, fontSize: '.95rem' }}>{m.symbol}</span>
              <span><strong>{m.badge}</strong> (<code>{m.colour}</code>)</span>
            </span>
          )
        })}
        <span style={{ color: 'var(--color-muted-fg)' }}>
          Cloud size = <code>log(1 + residual) * 10 + 5</code>
        </span>
      </div>

      {result && (
        <>
          {controlsDirty && (
            <div
              role="status"
              style={{
                padding: '8px 12px',
                marginBottom: 12,
                borderRadius: 6,
                border: '1px solid #0969da',
                background: 'rgba(9, 105, 218, 0.08)',
                fontSize: '.81rem',
              }}
            >
              Inputs above differ from the currently displayed result ({result.run} / {result.table}). Move checks use the displayed snapshot until you click <strong>Compute CladeCumulus</strong> again.
            </div>
          )}

          {/* Scientific caveats & approximation warnings */}
          {result.warnings.length > 0 && (
            <div
              role="region"
              aria-label="Phylogenetic caveats and approximation warnings"
              style={{
                padding: '10px 12px',
                marginBottom: 14,
                borderRadius: 6,
                border: '1px solid #d97706',
                background: 'rgba(249, 168, 37, 0.12)',
                fontSize: '.82rem',
              }}
            >
              <strong>Scientific caveats ({result.warnings.length}):</strong>
              <ul style={{ margin: '4px 0 0 18px', padding: 0 }}>
                {result.warnings.map((w, idx) => (
                  <li key={idx}>{w}</li>
                ))}
              </ul>
            </div>
          )}

          {/* Counterfactual proposal toggle banner when a move check succeeded */}
          {moveVerdict && (
            <div
              role="status"
              style={{
                padding: '10px 12px',
                marginBottom: 14,
                borderRadius: 6,
                border: `1px solid ${moveVerdict.allowed ? '#2e7d32' : '#c62828'}`,
                background: moveVerdict.allowed ? 'rgba(46, 125, 50, 0.08)' : 'rgba(198, 40, 40, 0.08)',
                fontSize: '.83rem',
                display: 'flex',
                flexWrap: 'wrap',
                alignItems: 'center',
                justifyContent: 'space-between',
                gap: 10,
              }}
            >
              <div>
                <strong>{moveVerdict.allowed ? 'Move admissible: ' : 'Move refused: '}</strong>
                <span>{moveVerdict.reason}</span>
              </div>
              {moveVerdict.allowed && (
                <div style={{ display: 'flex', gap: 8 }}>
                  <button
                    type="button"
                    className="btn btn-sm"
                    onClick={() => setShowProposed(p => !p)}
                  >
                    {showProposed ? 'Show canonical run tree' : 'Preview counterfactual tree'}
                  </button>
                  <button
                    type="button"
                    className="btn btn-primary btn-sm"
                    disabled={validatingMove}
                    onClick={() => submitMoveValidation(moveVerdict.source_id, moveVerdict.target_id, true)}
                  >
                    Save sidecar proposal
                  </button>
                </div>
              )}
            </div>
          )}

          {/* CladeCumulus Plotly Cloud Figure */}
          {displayedFigure && (
            <div style={{ marginBottom: 20 }}>
              <AnalysisChart study={study} figure={displayedFigure} heightRatio={0.58} />
            </div>
          )}

          {/* Interactive Cladistic Hierarchy + Drag-and-Drop / Accessible Move Validator */}
          <div style={{ marginBottom: 22 }}>
            <h3 style={{ fontSize: '.95rem', marginBottom: 8 }}>
              Interactive Clade Hierarchy &amp; Warrant-Gated Reassignment
            </h3>
            <p style={{ fontSize: '.8rem', color: 'var(--color-muted-fg)', marginTop: 0 }}>
              Drag any non-root clade row onto a target clade row—or use the selector controls below—to test
              whether <code>present_in_every_admissible_world</code> permits reassignment without modifying canonical DuckDB tables.
            </p>

            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'flex-end', marginBottom: 10 }}>
              <label style={{ display: 'flex', flexDirection: 'column', gap: 3, fontSize: '.8rem' }}>
                <span>Move clade / tip</span>
                <select value={moveSourceId} onChange={e => setMoveSourceId(e.target.value)}>
                  <option value="">Select source…</option>
                  {allNodesFlat
                    .filter(r => r.depth > 0)
                    .map(r => (
                      <option key={r.node.id} value={r.node.id}>
                        {'· '.repeat(r.depth)}
                        {r.node.name} ({r.node.cumulative_count.toFixed(0)} reads)
                      </option>
                    ))}
                </select>
              </label>

              <label style={{ display: 'flex', flexDirection: 'column', gap: 3, fontSize: '.8rem' }}>
                <span>Into target clade</span>
                <select value={moveTargetId} onChange={e => setMoveTargetId(e.target.value)}>
                  <option value="">Select target…</option>
                  {allNodesFlat
                    .filter(r => r.node.children.length > 0 && r.node.rank !== 'tip' && r.node.rank !== 'ASV')
                    .map(r => (
                      <option key={r.node.id} value={r.node.id}>
                        {'· '.repeat(r.depth)}
                        {r.node.name} [{r.node.epistemic_status}]
                      </option>
                    ))}
                </select>
              </label>

              <button
                type="button"
                className="btn btn-sm"
                disabled={validatingMove || !moveSourceId || !moveTargetId}
                onClick={() => submitMoveValidation(moveSourceId, moveTargetId, false)}
              >
                {validatingMove ? 'Checking…' : 'Validate move'}
              </button>
            </div>

            <div style={{ maxHeight: 360, overflowY: 'auto', border: '1px solid var(--color-border, #d0d7de)', borderRadius: 6 }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.81rem' }}>
                <thead>
                  <tr style={{ background: 'var(--color-surface, #f6f8fa)', textAlign: 'left' }}>
                    <th style={{ padding: '6px 8px' }}>Clade / Tip</th>
                    <th style={{ padding: '6px 8px' }}>Cum. reads</th>
                    <th style={{ padding: '6px 8px' }}>Freq.</th>
                    <th style={{ padding: '6px 8px' }}>Residual (cloud)</th>
                    <th style={{ padding: '6px 8px' }}>Support</th>
                    <th style={{ padding: '6px 8px' }}>Subtree PD</th>
                    <th style={{ padding: '6px 8px' }}>Epistemic status</th>
                  </tr>
                </thead>
                <tbody>
                  {flatRows.map(({ depth, node }) => {
                    const meta = EPISTEMIC_META[node.epistemic_status]
                    const hasKids = node.children.length > 0
                    const isExpanded = expandedIds.has(node.id)
                    return (
                      <tr
                        key={node.id}
                        draggable={depth > 0}
                        onDragStart={() => setDragSourceId(node.id)}
                        onDragOver={e => e.preventDefault()}
                        onDrop={e => {
                          e.preventDefault()
                          if (dragSourceId && dragSourceId !== node.id) {
                            setMoveSourceId(dragSourceId)
                            setMoveTargetId(node.id)
                            void submitMoveValidation(dragSourceId, node.id, false)
                          }
                          setDragSourceId(null)
                        }}
                        style={{
                          borderTop: '1px solid var(--color-border, #eaeef2)',
                          cursor: depth > 0 ? 'grab' : 'default',
                        }}
                      >
                        <td style={{ padding: '5px 8px', paddingLeft: 8 + depth * 16 }}>
                          {hasKids && (
                            <button
                              type="button"
                              aria-label={isExpanded ? `Collapse ${node.name}` : `Expand ${node.name}`}
                              onClick={() => toggleExpand(node.id)}
                              style={{
                                border: 'none',
                                background: 'transparent',
                                cursor: 'pointer',
                                marginRight: 4,
                                padding: 0,
                                fontWeight: 700,
                              }}
                            >
                              {isExpanded ? '▾' : '▸'}
                            </button>
                          )}
                          <span>{node.name}</span>
                        </td>
                        <td style={{ padding: '5px 8px' }}>{node.cumulative_count.toFixed(0)}</td>
                        <td style={{ padding: '5px 8px' }}>{(node.cumulative_frequency * 100).toFixed(1)}%</td>
                        <td style={{ padding: '5px 8px' }}>
                          {node.residual_count.toFixed(1)} ({node.cloud_size.toFixed(1)}px)
                        </td>
                        <td style={{ padding: '5px 8px' }}>
                          {node.support === null ? '—' : node.support.toFixed(3)}
                        </td>
                        <td style={{ padding: '5px 8px' }}>{node.subtree_pd.toFixed(4)}</td>
                        <td style={{ padding: '5px 8px' }}>
                          <span style={{ color: meta.colour, fontWeight: 600 }}>
                            {meta.symbol} {meta.badge}
                          </span>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>

          {/* Concordance diagnostics in Combined mode */}
          {result.concordance.dispersed_taxa.length > 0 && (
            <div style={{ marginBottom: 22 }}>
              <h3 style={{ fontSize: '.95rem', marginBottom: 6 }}>
                Non-Monophyletic / Dispersed Taxa ({result.concordance.dispersed_taxa.length})
              </h3>
              <ul style={{ fontSize: '.82rem', margin: '0 0 0 18px', padding: 0 }}>
                {result.concordance.dispersed_taxa.map(dt => (
                  <li key={dt.taxon}>
                    <strong>{dt.taxon}</strong> ({dt.tip_count} tips): {dt.note}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {/* Faith's PD + Pairwise UniFrac */}
          {result.diversity && (
            <div style={{ marginBottom: 20 }}>
              <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: 10, marginBottom: 8 }}>
                <h3 style={{ fontSize: '.95rem', margin: 0 }}>
                  Phylogenetic Diversity (Faith’s PD &amp; UniFrac — {result.diversity.mapped_tips} tips)
                </h3>
                <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                  <select
                    value={unifracKind}
                    onChange={e => setUnifracKind(e.target.value as typeof unifracKind)}
                    style={{ fontSize: '.8rem' }}
                  >
                    <option value="normalized_weighted">Normalized Weighted UniFrac</option>
                    <option value="weighted">Raw Weighted UniFrac</option>
                    <option value="unweighted">Unweighted UniFrac</option>
                  </select>
                  <button type="button" className="btn btn-sm" onClick={exportMatrixCsv}>
                    Export CSV
                  </button>
                </div>
              </div>

              {/* Faith's PD per sample */}
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 12 }}>
                {result.diversity.samples.map(s => (
                  <div
                    key={s}
                    style={{
                      padding: '6px 10px',
                      borderRadius: 6,
                      border: '1px solid var(--color-border, #d0d7de)',
                      fontSize: '.8rem',
                    }}
                  >
                    <strong>{s}</strong>: Faith’s PD = {(result.diversity!.faith_pd[s] ?? 0).toFixed(4)}
                  </div>
                ))}
              </div>

              {/* Pairwise UniFrac table */}
              {activeMatrix && (
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.8rem' }}>
                    <thead>
                      <tr style={{ background: 'var(--color-surface, #f6f8fa)' }}>
                        <th style={{ padding: '5px 8px', textAlign: 'left' }}>Sample</th>
                        {result.diversity.samples.map(s => (
                          <th key={s} style={{ padding: '5px 8px', textAlign: 'right' }}>{s}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {result.diversity.samples.map((rowSample, ri) => (
                        <tr key={rowSample} style={{ borderTop: '1px solid var(--color-border, #eaeef2)' }}>
                          <td style={{ padding: '5px 8px', fontWeight: 600 }}>{rowSample}</td>
                          {result.diversity!.samples.map((colSample, ci) => (
                            <td key={colSample} style={{ padding: '5px 8px', textAlign: 'right' }}>
                              {(activeMatrix[ri]?.[ci] ?? 0).toFixed(4)}
                            </td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          )}

          {/* Provenance Receipt Disclosure */}
          <details style={{ fontSize: '.79rem', color: 'var(--color-muted-fg)' }}>
            <summary style={{ cursor: 'pointer', fontWeight: 600 }}>
              Provenance attestation receipt (SHA-256: <code>{result.receipt.checksum.slice(0, 16)}…</code>)
            </summary>
            <pre style={{ marginTop: 8, padding: 10, borderRadius: 6, background: 'var(--color-surface, #f6f8fa)', overflowX: 'auto' }}>
              {JSON.stringify(result.receipt, null, 2)}
            </pre>
          </details>
        </>
      )}
    </section>
  )
}
