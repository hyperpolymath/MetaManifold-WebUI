// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

import { useId, useState } from 'react'
import type { AnnotationSource } from '../api/types'
import { addValue } from './claims'
import type { EvidenceContext, FibreRequest, ProjectionTag } from './types'

/**
 * The labels a projection can take values from, for autocompletion. Rank labels
 * are fetched by the caller (they live in the results table); category labels
 * are the set's own category names, which the library already carries.
 */
export function suggestionsFor(context: EvidenceContext, request: FibreRequest): string[] {
  if (request.tag !== 'category') return []
  const set = context.category_sets.find(s => s.name === request.value)
  if (!set) return []
  return set.categories.map(c => c.name)
}

/** The rank column a request would read, when the context knows it. */
export function rankColumnFor(context: EvidenceContext, request: FibreRequest): string | null {
  if (request.tag !== 'rank') return null
  const sets = request.source
    ? context.ranks.filter(r => r.source === request.source)
    : context.ranks
  for (const set of sets) {
    const i = set.names.indexOf(request.value)
    if (i >= 0) return set.columns[i] ?? null
  }
  return null
}

interface Props {
  context: EvidenceContext
  request: FibreRequest
  onChange: (next: FibreRequest) => void
  /** Labels offered as a datalist, e.g. the rank's distinct values. */
  suggestions?: string[]
  disabled?: boolean
  idPrefix: string
}

const labelStyle: React.CSSProperties = { fontSize: '.8rem', color: 'var(--color-muted-fg)', display: 'block', marginBottom: 2 }

/**
 * The projection picker shared by the fibre visualiser and the residual
 * explorer. Changing the projection clears the values: a label means something
 * different at another rank, and silently keeping it would make the new fibre
 * look like the old one.
 */
export function ProjectionControls({ context, request, onChange, suggestions = [], disabled, idPrefix }: Props) {
  const [valueInput, setValueInput] = useState('')
  const listId = useId()

  const sourceRanks = request.source
    ? context.ranks.filter(r => r.source === request.source)
    : context.ranks
  const rankNames = [...new Set(sourceRanks.flatMap(r => r.names))]
  const setNames = context.category_sets.map(s => s.name)

  const tableOptions = context.tables.length
    ? context.tables.map(t => t.id)
    : [request.table]

  function changeTable(table: string) {
    onChange({ ...request, table, values: [] })
  }

  function changeTag(tag: ProjectionTag) {
    const value = tag === 'rank'
      ? (request.source ? (context.ranks.find(r => r.source === request.source)?.names[0] ?? '') : (rankNames[0] ?? ''))
      : (setNames[0] ?? '')
    onChange({ ...request, tag, value, values: [] })
  }

  function changeProjection(value: string) {
    onChange({ ...request, value, values: [] })
  }

  function changeSource(raw: string) {
    const source = (raw || null) as AnnotationSource | null
    // A rank may not exist under the new classifier; keep it only when it does.
    const available = source
      ? context.ranks.filter(r => r.source === source).flatMap(r => r.names)
      : context.ranks.flatMap(r => r.names)
    const value = request.tag === 'rank' && !available.includes(request.value)
      ? (available[0] ?? '')
      : request.value
    onChange({ ...request, source, value, values: [] })
  }

  function addCurrentValue() {
    const parts = valueInput.split(/[,\n]/)
    let next = request.values
    for (const part of parts) next = addValue(next, part)
    if (next.length !== request.values.length) onChange({ ...request, values: next })
    setValueInput('')
  }

  function removeValue(v: string) {
    onChange({ ...request, values: request.values.filter(x => x !== v) })
  }

  const field: React.CSSProperties = { display: 'flex', flexDirection: 'column', minWidth: 130 }
  const select: React.CSSProperties = { padding: '4px 6px', borderRadius: 4,
    border: '1px solid var(--color-border)', background: 'var(--color-bg)', color: 'var(--color-fg)',
    fontSize: '.85rem' }

  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'flex-end' }}>
      <div style={field}>
        <label style={labelStyle} htmlFor={`${idPrefix}-table`}>Results table</label>
        <select id={`${idPrefix}-table`} value={request.table} disabled={disabled}
          onChange={e => changeTable(e.target.value)} style={select}>
          {tableOptions.map(t => <option key={t} value={t}>{t}</option>)}
        </select>
      </div>

      <div style={field}>
        <label style={labelStyle} htmlFor={`${idPrefix}-tag`}>Projection</label>
        <select id={`${idPrefix}-tag`} value={request.tag} disabled={disabled}
          onChange={e => changeTag(e.target.value as ProjectionTag)} style={select}>
          <option value="rank">Taxonomy rank</option>
          <option value="category">Category set</option>
        </select>
      </div>

      <div style={field}>
        <label style={labelStyle} htmlFor={`${idPrefix}-projection`}>
          {request.tag === 'rank' ? 'Rank' : 'Category set'}
        </label>
        <select id={`${idPrefix}-projection`} value={request.value} disabled={disabled}
          onChange={e => changeProjection(e.target.value)} style={select}>
          {(request.tag === 'rank' ? rankNames : setNames).map(name => (
            <option key={name} value={name}>{name}</option>
          ))}
          {request.value && !(request.tag === 'rank' ? rankNames : setNames).includes(request.value) && (
            <option value={request.value}>{request.value}</option>
          )}
        </select>
      </div>

      <div style={field}>
        <label style={labelStyle} htmlFor={`${idPrefix}-source`}>Classifier</label>
        <select id={`${idPrefix}-source`} value={request.source ?? ''} disabled={disabled}
          onChange={e => changeSource(e.target.value)} style={select}>
          <option value="">run default</option>
          {context.sources.map(s => <option key={s} value={s}>{s}</option>)}
        </select>
      </div>

      <div style={{ ...field, flex: '1 1 260px' }}>
        <label style={labelStyle} htmlFor={`${idPrefix}-values`}>Fibre values</label>
        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', alignItems: 'center' }}>
          {request.values.map(v => (
            <span key={v} style={{ display: 'inline-flex', alignItems: 'center', gap: 4,
                                    padding: '2px 8px', borderRadius: 10, fontSize: '.8rem',
                                    background: 'var(--color-surface)', border: '1px solid var(--color-border)' }}>
              {v}
              <button type="button" className="btn btn-sm" style={{ padding: '0 4px', border: 'none', background: 'transparent' }}
                aria-label={`Remove ${v}`} disabled={disabled} onClick={() => removeValue(v)}>×</button>
            </span>
          ))}
          {request.values.length === 0 && (
            <span style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)' }}>none yet</span>
          )}
        </div>
        <div style={{ display: 'flex', gap: 6, marginTop: 4 }}>
          <input id={`${idPrefix}-values`} list={listId} value={valueInput} disabled={disabled}
            placeholder="type a label, comma-separated"
            onChange={e => setValueInput(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addCurrentValue() } }}
            style={{ ...select, flex: 1 }} />
          <datalist id={listId}>
            {suggestions.slice(0, 1000).map(s => <option key={s} value={s} />)}
          </datalist>
          <button type="button" className="btn btn-sm" disabled={disabled || !valueInput.trim()}
            onClick={addCurrentValue}>Add</button>
        </div>
      </div>
    </div>
  )
}
