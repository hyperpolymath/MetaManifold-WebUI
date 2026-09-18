// SPDX-License-Identifier: AGPL-3.0-only
import { useState, useEffect, useRef } from 'react'

interface CladeNode {
  id: string
  label: string
  rank: string
  parent_id: string | null
  children_ids: string[]
  count: number
  cumulative_count: number
  cumulative_frequency: number
  residual_count: number
  avec_fibre: boolean
  epistemic_status: 'present_in_every_admissible_world' | 'present_in_some_admissible_world' | 'absent_in_every_admissible_world' | 'unknown'
  colour: string
  cloud_size: number
}

interface CladeTree {
  root_id: string
  total_count: number
  nodes: CladeNode[]
}

interface CladeCumulusProps {
  evidenceMode: boolean
  tree?: CladeTree | null
  onDragDrop?: (draggedId: string, targetParentId: string) => Promise<{ valid: boolean; message: string }>
  onNodeClick?: (node: CladeNode) => void
}

function epistemicColour(status: CladeNode['epistemic_status']): string {
  switch (status) {
    case 'present_in_every_admissible_world': return '#2e7d32'
    case 'present_in_some_admissible_world': return '#f9a825'
    case 'absent_in_every_admissible_world': return '#9e9e9e'
    default: return '#c62828'
  }
}

function cloudSize(residual: number): number {
  return Math.log(1 + residual) * 10 + 5
}

export function CladeCumulus({ evidenceMode, tree, onDragDrop, onNodeClick }: CladeCumulusProps) {
  const [draggedId, setDraggedId] = useState<string | null>(null)
  const [validationMsg, setValidationMsg] = useState<string | null>(null)
  const [validationValid, setValidationValid] = useState<boolean | null>(null)
  const [hoveredId, setHoveredId] = useState<string | null>(null)
  const svgRef = useRef<SVGSVGElement>(null)

  if (!evidenceMode) return null // Keep UI clean — only appears when Evidence Mode enabled

  if (!tree) {
    return (
      <div style={{ padding: 16, background: '#f5f5f5', borderRadius: 8, textAlign: 'center', color: '#666' }}>
        <h3>CladeCumulus — Cumulative Cladistic Explorer</h3>
        <p>Tree with cumulative frequencies, epistemic colour coding, cloud sizing by residual count, drag-and-drop with live present_in_every_admissible_world validation.</p>
        <p style={{ fontSize: 12 }}>No tree data yet. Run analysis or load a study with taxonomy to see the cladistic explorer.</p>
        <p style={{ fontSize: 11, fontFamily: 'monospace' }}>
          Based on hyperpolymath/echo-types (Echo f y := Σ (x:A), f x ≡ y), epistemic-types (Warrant without soundness), residual-evidence-types (Candidate, Holds, Identified)
        </p>
      </div>
    )
  }

  const nodesById = new Map(tree.nodes.map(n => [n.id, n]))

  const handleDragStart = (id: string) => {
    setDraggedId(id)
    setValidationMsg(null)
  }

  const handleDragOver = async (targetId: string) => {
    if (!draggedId || !onDragDrop) return
    if (draggedId === targetId) return

    // Live present_in_every_admissible_world validation
    try {
      const result = await onDragDrop(draggedId, targetId)
      setValidationMsg(result.message)
      setValidationValid(result.valid)
    } catch (e) {
      setValidationMsg(`Validation error: ${e}`)
      setValidationValid(false)
    }
  }

  const handleDrop = async (targetId: string) => {
    if (!draggedId || !onDragDrop) return
    const result = await onDragDrop(draggedId, targetId)
    setValidationMsg(result.message)
    setValidationValid(result.valid)
    if (result.valid) {
      // In real implementation, would update tree via API
      console.log(`Valid drop: ${draggedId} -> ${targetId}`)
    }
    setDraggedId(null)
  }

  // Simple tree layout — for production would use D3 hierarchy
  const renderNode = (node: CladeNode, depth: number, x: number, y: number): JSX.Element => {
    const isDragged = draggedId === node.id
    const isHovered = hoveredId === node.id
    const colour = node.colour || epistemicColour(node.epistemic_status)
    const size = node.cloud_size || cloudSize(node.residual_count)

    return (
      <g key={node.id} transform={`translate(${x}, ${y})`}>
        {/* Cloud sizing by residual count */}
        <circle
          r={size}
          fill={colour}
          opacity={isDragged ? 0.5 : isHovered ? 0.8 : 0.6}
          stroke={isHovered ? '#000' : '#fff'}
          strokeWidth={isHovered ? 2 : 1}
          style={{ cursor: 'grab' }}
          draggable
          onDragStart={() => handleDragStart(node.id)}
          onDragOver={e => { e.preventDefault(); handleDragOver(node.id) }}
          onDrop={e => { e.preventDefault(); handleDrop(node.id) }}
          onMouseEnter={() => setHoveredId(node.id)}
          onMouseLeave={() => setHoveredId(null)}
          onClick={() => onNodeClick?.(node)}
        />
        <text
          x={size + 5}
          y={4}
          fontSize={12 - Math.min(depth, 4)}
          fontWeight={depth === 0 ? 700 : 400}
          style={{ pointerEvents: 'none', userSelect: 'none' }}
        >
          {node.label} ({(node.cumulative_frequency * 100).toFixed(1)}%)
        </text>
        {/* Epistemic status indicator */}
        <text x={size + 5} y={16} fontSize={9} fill={colour} style={{ pointerEvents: 'none' }}>
          {node.avec_fibre ? 'avec_fibre' : 'sans_fibre'} • {node.epistemic_status.split('_')[0]}
        </text>

        {/* Children */}
        {node.children_ids.map((childId, idx) => {
          const child = nodesById.get(childId)
          if (!child) return null
          const childX = 40
          const childY = (idx - (node.children_ids.length - 1) / 2) * 60
          return (
            <g key={childId}>
              <line x1={size} y1={0} x2={childX} y2={childY} stroke="#ccc" strokeWidth={1} />
              <g transform={`translate(${childX}, ${childY})`}>
                {renderNode(child, depth + 1, 0, 0)}
              </g>
            </g>
          )
        })}
      </g>
    )
  }

  const root = nodesById.get(tree.root_id)
  if (!root) return <div>Root not found</div>

  return (
    <div style={{ border: '1px solid #e0e0e0', borderRadius: 8, padding: 16, background: 'white', marginTop: 16 }}>
      <h3 style={{ margin: '0 0 8px 0', display: 'flex', alignItems: 'center', gap: 8 }}>
        CladeCumulus — Cumulative Cladistic Explorer
        <span style={{ fontSize: 10, background: '#e8f5e9', padding: '2px 6px', borderRadius: 4 }}>Evidence Mode</span>
      </h3>

      <p style={{ fontSize: 12, color: '#666', marginBottom: 12 }}>
        Tree with cumulative frequencies, epistemic colour coding (green=present in every admissible world, yellow=some, grey=absent, red=unknown/sans fibre),
        cloud sizing by residual count (larger cloud = more candidate worlds), drag-and-drop with live <code>present_in_every_admissible_world</code> validation.
        Clean non-cluttered UI — only visible in Evidence Mode.
      </p>

      {/* Legend */}
      <div style={{ display: 'flex', gap: 16, marginBottom: 12, fontSize: 11, flexWrap: 'wrap' }}>
        <span><span style={{ display: 'inline-block', width: 12, height: 12, background: '#2e7d32', borderRadius: '50%', marginRight: 4 }}></span>present_in_every (solid evidence)</span>
        <span><span style={{ display: 'inline-block', width: 12, height: 12, background: '#f9a825', borderRadius: '50%', marginRight: 4 }}></span>present_in_some (uncertain)</span>
        <span><span style={{ display: 'inline-block', width: 12, height: 12, background: '#9e9e9e', borderRadius: '50%', marginRight: 4 }}></span>absent_in_every</span>
        <span><span style={{ display: 'inline-block', width: 12, height: 12, background: '#c62828', borderRadius: '50%', marginRight: 4 }}></span>unknown / sans fibre</span>
        <span>Cloud size ∝ log(1 + residual_count)</span>
      </div>

      {/* Validation message */}
      {validationMsg && (
        <div style={{
          padding: 8,
          borderRadius: 4,
          marginBottom: 12,
          background: validationValid ? '#e8f5e9' : '#ffebee',
          border: `1px solid ${validationValid ? '#4caf50' : '#c62828'}`,
          color: validationValid ? '#2e7d32' : '#c62828',
          fontSize: 12,
          fontFamily: 'monospace',
        }}>
          {validationValid ? '✓' : '✗'} {validationMsg}
        </div>
      )}

      {/* SVG tree */}
      <div style={{ overflow: 'auto', border: '1px solid #eee', borderRadius: 4, background: '#fafafa' }}>
        <svg ref={svgRef} width={Math.max(800, tree.nodes.length * 20)} height={Math.max(600, tree.nodes.length * 30)} style={{ display: 'block' }}>
          {renderNode(root, 0, 50, 300)}
        </svg>
      </div>

      <div style={{ marginTop: 12, fontSize: 10, color: '#999', fontFamily: 'monospace' }}>
        Total count: {tree.total_count} | Nodes: {tree.nodes.length} | Root: {tree.root_id}
        <br />
        Based on hyperpolymath/echo-types (fiber laws, total space equivalence), epistemic-types (Warrant, SoundWarrant, E κ A), residual-evidence-types (Candidate, Holds, Identified, actual-world-sound)
        <br />
        Drag-and-drop validates live via present_in_every_admissible_world: taxon must be present in every admissible world consistent with observation and evidence (avec_fibre).
      </div>
    </div>
  )
}
