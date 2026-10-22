// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { useMemo, useState } from 'react'
import type { CumulativeCladeNode } from '../api/types'
import { cumulativeRadius, cumulativeStroke, layoutCumulativeTree } from './cumulativeLayout'
import styles from './Clade.module.css'

const percent = (value: number) => `${(value * 100).toFixed(value < 0.01 && value > 0 ? 2 : 1)}%`

/** Interactive cumulative-frequency view; the Newick source remains unchanged. */
export function CumulativeTree({ nodes }: { nodes: CumulativeCladeNode[] }) {
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [zoom, setZoom] = useState(1)
  const [query, setQuery] = useState('')
  const layout = useMemo(() => layoutCumulativeTree(nodes, collapsed, {
    rowHeight: 26 * zoom,
    levelWidth: 180 * zoom,
    margin: 28 * zoom,
  }), [nodes, collapsed, zoom])
  const matches = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return new Set<string>()
    return new Set(nodes.filter(n => n.label.toLowerCase().includes(q)).map(n => n.id))
  }, [nodes, query])

  const toggle = (id: string) => setCollapsed(previous => {
    const next = new Set(previous)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    return next
  })
  const collapseToRoot = () => {
    const root = nodes.find(n => n.parent_id === null)
    setCollapsed(root ? new Set([root.id]) : new Set())
  }

  return (
    <section className={styles.section} aria-label="Cumulative phylogenetic tree">
      <div className={styles.sectionHeading}>
        <div>
          <h3>Cumulative phylogeny</h3>
          <p>Circle area and branch width show the reads accumulated below each clade. Click a clade to collapse or expand it.</p>
        </div>
        <div className={styles.treeControls}>
          <input aria-label="Search clades" placeholder="Find ASV or clade" value={query}
            onChange={event => setQuery(event.target.value)} />
          <button className="btn btn-sm" onClick={() => setCollapsed(new Set())}>Expand all</button>
          <button className="btn btn-sm" onClick={collapseToRoot}>Root only</button>
          <button className="btn btn-sm" aria-label="Zoom out" disabled={zoom <= 0.6}
            onClick={() => setZoom(z => Math.max(0.6, +(z - 0.2).toFixed(1)))}>−</button>
          <button className="btn btn-sm" aria-label="Zoom in" disabled={zoom >= 1.8}
            onClick={() => setZoom(z => Math.min(1.8, +(z + 0.2).toFixed(1)))}>+</button>
        </div>
      </div>
      <div className={styles.treeMeta}>
        <span>{layout.rows} visible row{layout.rows === 1 ? '' : 's'} · {nodes.filter(n => n.is_tip).length} ASVs</span>
        {query && <span>{matches.size} match{matches.size === 1 ? '' : 'es'}</span>}
        <span><i className={styles.legendDot} /> cumulative read frequency</span>
      </div>
      <div className={styles.treeScroll}>
        <svg width={layout.width} height={layout.height} role="img"
          aria-label="Phylogenetic tree with cumulative clade abundances">
          {layout.links.map(link => (
            <path key={`${link.from}-${link.to}`} d={link.path} fill="none"
              stroke="#94a3b8" strokeWidth={cumulativeStroke(link.frequency)} strokeLinecap="round" />
          ))}
          {layout.nodes.map(node => {
            const radius = cumulativeRadius(node.cumulative_frequency)
            const canCollapse = node.children.length > 0
            const matched = matches.has(node.id)
            const generic = /^Clade n?\d+$/.test(node.label) || /^Tip \d+$/.test(node.label)
            return (
              <g key={node.id} transform={`translate(${node.x} ${node.y})`}
                role={canCollapse ? 'button' : undefined} tabIndex={canCollapse ? 0 : undefined}
                aria-label={canCollapse ? `${node.collapsed ? 'Expand' : 'Collapse'} ${node.label}` : undefined}
                className={canCollapse ? styles.cladeButton : undefined}
                onClick={canCollapse ? () => toggle(node.id) : undefined}
                onKeyDown={canCollapse ? event => {
                  if (event.key === 'Enter' || event.key === ' ') {
                    event.preventDefault()
                    toggle(node.id)
                  }
                } : undefined}>
                <title>
                  {`${node.label}\n${node.tip_count} ASV${node.tip_count === 1 ? '' : 's'}\n${node.cumulative_count.toLocaleString()} cumulative reads (${percent(node.cumulative_frequency)})`}
                </title>
                {node.collapsed && (
                  <path d={`M ${radius + 2} 0 L ${radius + 11} ${-6 * zoom} L ${radius + 11} ${6 * zoom} Z`}
                    fill="#087f5b" opacity={0.35} />
                )}
                <circle r={radius} fill={matched ? '#f9a825' : '#087f5b'} fillOpacity={node.is_tip ? 0.9 : 0.65}
                  stroke={matched ? '#9c6500' : '#ffffff'} strokeWidth={matched ? 2 : 1} />
                <text x={radius + 8} y={4 * zoom} fontSize={11 * zoom} className={styles.nodeLabel}>
                  {!generic && `${node.label} · `}{percent(node.cumulative_frequency)}
                  {node.collapsed && ` · ${node.tip_count} ASVs`}
                </text>
              </g>
            )
          })}
        </svg>
      </div>
    </section>
  )
}
