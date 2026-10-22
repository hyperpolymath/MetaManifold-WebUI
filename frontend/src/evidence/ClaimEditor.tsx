// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// The epistemic editor: claims, each with the fibre it is about and the warrant
// that is supposed to carry it.
//
// The editor is deliberately stricter than a free-text note. A claim cannot be
// saved without a scope and at least one value, and cannot be marked 'supported'
// without an evidential warrant. Those two rules are what stop the record from
// becoming a place to write down conclusions the data does not carry - the
// cherry-pick risk the issue names.

import { useEffect, useMemo, useState } from 'react'
import { api } from '../api/client'
import { errorMessage } from '../api/errorMessage'
import { useToast } from '../components/Toast'
import { saveBlob } from '../utils/download'
import {
  claimCountByStatus, draftClaim, emptyWarrant, evidentialWarrants, newClaim,
  nextClaimId, parseValues, scopeSummary, statusTone, validateClaim,
} from './claims'
import { Badge, Notice, sectionTitleStyle } from './ui'
import {
  CLAIM_STATUSES, WARRANT_KINDS, type ClaimScope, type ClaimStatus, type ClaimWarrant,
  type EvidenceClaim, type EvidenceContext, type ProjectionTag, type WarrantKind,
} from './types'
import type { AnnotationSource } from '../api/types'

interface Props {
  study: string
  run: string
  group?: string | null
  context: EvidenceContext
  /** A scope sent over from the fibre visualiser. */
  draftScope?: ClaimScope | null
  onSaved: () => void
  onUseInFibre?: (scope: ClaimScope) => void
  /** Called once a handed-over scope has become a draft, so it is not reapplied. */
  onDraftConsumed?: () => void
}

const inputStyle: React.CSSProperties = {
  width: '100%', padding: '5px 7px', borderRadius: 4, boxSizing: 'border-box',
  border: '1px solid var(--color-border)', background: 'var(--color-bg)',
  color: 'var(--color-fg)', fontSize: '.85rem', fontFamily: 'inherit',
}
const labelStyle: React.CSSProperties = {
  fontSize: '.76rem', textTransform: 'uppercase', letterSpacing: '.03em',
  color: 'var(--color-muted-fg)', display: 'block', marginBottom: 3,
}
const rowStyle: React.CSSProperties = { marginBottom: 12 }

function ScopeEditor({ value, onChange, context }: {
  value: ClaimScope
  onChange: (next: ClaimScope) => void
  context: EvidenceContext
}) {
  const ranks = value.source
    ? context.ranks.filter(r => r.source === value.source)
    : context.ranks
  const rankNames = [...new Set(ranks.flatMap(r => r.names))]
  const setNames = context.category_sets.map(s => s.name)
  const suggestions = value.tag === 'category'
    ? (context.category_sets.find(s => s.name === value.value)?.categories.map(c => c.name) ?? [])
    : []
  const [valueInput, setValueInput] = useState('')

  function setTag(tag: ProjectionTag) {
    const projection = tag === 'rank' ? (rankNames[0] ?? '') : (setNames[0] ?? '')
    onChange({ ...value, tag, value: projection, values: [] })
  }

  function removeValue(v: string) {
    onChange({ ...value, values: value.values.filter(x => x !== v) })
  }

  function addValue() {
    const next = [...value.values]
    for (const part of parseValues(valueInput)) {
      if (!next.includes(part)) next.push(part)
    }
    if (next.length !== value.values.length) onChange({ ...value, values: next })
    setValueInput('')
  }

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(140px, 1fr))', gap: 10, marginBottom: 10 }}>
        <div>
          <label style={labelStyle} htmlFor="claim-table">Table</label>
          <select id="claim-table" style={inputStyle} value={value.table}
            onChange={e => onChange({ ...value, table: e.target.value, values: [] })}>
            {(context.tables.length ? context.tables.map(t => t.id) : [value.table])
              .map(t => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
        <div>
          <label style={labelStyle} htmlFor="claim-tag">Projection</label>
          <select id="claim-tag" style={inputStyle} value={value.tag}
            onChange={e => setTag(e.target.value as ProjectionTag)}>
            <option value="rank">Taxonomy rank</option>
            <option value="category">Category set</option>
          </select>
        </div>
        <div>
          <label style={labelStyle} htmlFor="claim-projection">
            {value.tag === 'rank' ? 'Rank' : 'Category set'}
          </label>
          <select id="claim-projection" style={inputStyle} value={value.value}
            onChange={e => onChange({ ...value, value: e.target.value, values: [] })}>
            {(value.tag === 'rank' ? rankNames : setNames).map(n => (
              <option key={n} value={n}>{n}</option>
            ))}
            {value.value && !(value.tag === 'rank' ? rankNames : setNames).includes(value.value) && (
              <option value={value.value}>{value.value}</option>
            )}
          </select>
        </div>
        <div>
          <label style={labelStyle} htmlFor="claim-source">Classifier</label>
          <select id="claim-source" style={inputStyle} value={value.source ?? ''}
            onChange={e => onChange({
              ...value, source: (e.target.value || null) as AnnotationSource | null,
            })}>
            <option value="">run default</option>
            {context.sources.map(s => <option key={s} value={s}>{s}</option>)}
          </select>
        </div>
      </div>

      <label style={labelStyle} htmlFor="claim-values">Fibre values</label>
      <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', marginBottom: 4 }}>
        {value.values.map(v => (
          <span key={v} style={{
            display: 'inline-flex', alignItems: 'center', gap: 4, padding: '1px 8px',
            borderRadius: 10, fontSize: '.8rem', background: 'var(--color-surface)',
            border: '1px solid var(--color-border)',
          }}>
            {v}
            <button type="button" aria-label={`Remove ${v}`}
              onClick={() => removeValue(v)}
              style={{ border: 'none', background: 'transparent', cursor: 'pointer' }}>×</button>
          </span>
        ))}
        {!value.values.length && (
          <span style={{ fontSize: '.78rem', color: 'var(--color-muted-fg)' }}>
            none yet — a claim is never about everything
          </span>
        )}
      </div>
      <div style={{ display: 'flex', gap: 6 }}>
        <input list="claim-value-suggestions" style={inputStyle} value={valueInput}
          placeholder={value.tag === 'category'
            ? 'a category of this set'
            : 'a taxon label at this rank'}
          onChange={e => setValueInput(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addValue() } }} />
        <datalist id="claim-value-suggestions">
          {suggestions.map(s => <option key={s} value={s} />)}
        </datalist>
        <button type="button" className="btn btn-sm" disabled={!valueInput.trim()} onClick={addValue}>Add</button>
      </div>
    </div>
  )
}

export function ClaimEditor({ study, run, group, context, draftScope, onSaved, onUseInFibre, onDraftConsumed }: Props) {
  const toast = useToast()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [draft, setDraft] = useState<EvidenceClaim | null>(null)
  // Caveats are edited as text and parsed on save, so a blank line while typing
  // is not a validation error.
  const [caveatsText, setCaveatsText] = useState('')
  const [saving, setSaving] = useState(false)
  const [exporting, setExporting] = useState(false)

  const claims = context.claims
  const counts = useMemo(() => claimCountByStatus(claims), [claims])

  const draftKey = draftScope
    ? JSON.stringify([draftScope.table, draftScope.tag, draftScope.value, draftScope.source, draftScope.values])
    : null
  useEffect(() => {
    if (!draftScope) return
    setSelectedId(null)
    setDraft(newClaim(draftScope))
    setCaveatsText('')
    onDraftConsumed?.()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draftKey])

  const parsedCaveats = caveatsText.split('\n').map(c => c.trim()).filter(Boolean)
  const effective: EvidenceClaim | null = draft
    ? {
        ...draft,
        caveats: parsedCaveats,
        id: draft.id || (draft.text.trim() ? nextClaimId(claims, draft.text) : ''),
      }
    : null
  const errors = effective ? validateClaim(effective) : []

  function select(claim: EvidenceClaim) {
    setSelectedId(claim.id)
    setDraft(draftClaim(claim))
    setCaveatsText(claim.caveats.join('\n'))
  }

  function startNew() {
    setSelectedId(null)
    setCaveatsText('')
    setDraft(newClaim({
      table: context.merged_table ?? context.tables[0]?.id ?? 'merged',
      tag: context.ranks[0]?.names.length ? 'rank' : 'category',
      value: context.ranks[0]?.names[0] ?? context.category_sets[0]?.name ?? '',
      source: context.sources[0] ?? null,
    }))
  }

  async function save() {
    if (!effective || errors.length) return
    setSaving(true)
    try {
      const saved = await api.evidence.saveClaim(study, run, {
        ...effective,
        text: effective.text.trim(),
        caveats: effective.caveats.map(c => c.trim()).filter(Boolean),
      }, group)
      toast.success(`Claim “${saved.claim.id}” saved`)
      setSelectedId(saved.claim.id)
      setDraft(draftClaim(saved.claim))
      setCaveatsText(saved.claim.caveats.join('\n'))
      onSaved()
    } catch (err) {
      toast.error(errorMessage(err, 'Could not save the claim'))
    } finally {
      setSaving(false)
    }
  }

  async function remove(claim: EvidenceClaim) {
    if (!window.confirm(`Delete claim “${claim.id}”? The record on disk is rewritten.`)) return
    try {
      await api.evidence.deleteClaim(study, run, claim.id, group)
      toast.success(`Claim “${claim.id}” deleted`)
      if (selectedId === claim.id) { setSelectedId(null); setDraft(null); setCaveatsText('') }
      onSaved()
    } catch (err) {
      toast.error(errorMessage(err, 'Could not delete the claim'))
    }
  }

  async function exportYaml() {
    setExporting(true)
    try {
      const blob = await api.evidence.claimsYaml(study, run, group)
      saveBlob(blob, `${study}-${run}-claims.yml`)
    } catch (err) {
      toast.error(errorMessage(err, 'Could not download the record'))
    } finally {
      setExporting(false)
    }
  }

  function updateWarrant(i: number, patch: Partial<ClaimWarrant>) {
    if (!draft) return
    const warrant = draft.warrant.map((w, j) => (j === i ? { ...w, ...patch } : w))
    setDraft({ ...draft, warrant })
  }

  const supportedWithoutEvidence = draft?.status === 'supported' &&
    evidentialWarrants(draft).length === 0

  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'minmax(220px, 300px) 1fr', gap: 16, alignItems: 'start' }}>
      <div className="card" style={{ margin: 0 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
          <div className="card-title" style={{ margin: 0 }}>Claims ({claims.length})</div>
          <button className="btn btn-sm btn-primary" onClick={startNew}>New</button>
        </div>
        <div style={{ fontSize: '.74rem', color: 'var(--color-muted-fg)', marginBottom: 8 }}>
          {counts.supported} supported · {counts.contested} contested · {counts.refuted} refuted ·{' '}
          {counts.draft} draft
        </div>

        {claims.length === 0 && (
          <p className="empty-state" style={{ fontSize: '.82rem' }}>
            No claims recorded for this run yet.
          </p>
        )}

        {claims.map(claim => (
          <button key={claim.id} onClick={() => select(claim)}
            style={{
              display: 'block', width: '100%', textAlign: 'left', cursor: 'pointer',
              padding: '7px 8px', marginBottom: 6, borderRadius: 4,
              border: `1px solid ${claim.id === selectedId ? 'var(--color-primary)' : 'var(--color-border)'}`,
              background: claim.id === selectedId ? 'var(--color-surface)' : 'transparent',
              color: 'inherit', font: 'inherit',
            }}>
            <span style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 2 }}>
              <span style={{ width: 7, height: 7, borderRadius: '50%', background: statusTone(claim.status) }} />
              <span style={{ fontSize: '.8rem', fontWeight: 600 }}>{claim.status}</span>
            </span>
            <span style={{ display: 'block', fontSize: '.82rem', lineHeight: 1.35 }}>
              {claim.text || <em style={{ color: 'var(--color-muted-fg)' }}>(no text yet)</em>}
            </span>
            <span style={{ display: 'block', fontSize: '.72rem', color: 'var(--color-muted-fg)', marginTop: 3 }}>
              {scopeSummary(claim.scope)}
            </span>
          </button>
        ))}

        <button className="btn btn-sm" style={{ marginTop: 8, width: '100%' }}
          onClick={exportYaml} disabled={exporting}>
          {exporting ? 'Preparing…' : 'Download record as YAML'}
        </button>
        <div style={{ fontSize: '.7rem', color: 'var(--color-muted-fg)', marginTop: 6 }}>
          Written to <code>{context.file}</code>
        </div>
      </div>

      {!draft && (
        <div className="card" style={{ margin: 0 }}>
          <p className="empty-state">
            Select a claim to edit it, or start a new one. A claim records the fibre it is
            about, why it follows, and what would make it false.
          </p>
        </div>
      )}

      {draft && effective && (
        <div className="card" style={{ margin: 0 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ margin: 0 }}>
              {selectedId ? 'Edit claim' : 'New claim'}
            </div>
            <Badge tone={draft.status === 'supported' ? 'good'
              : draft.status === 'contested' ? 'warn'
              : draft.status === 'refuted' ? 'bad' : 'neutral'}>
              {draft.status}
            </Badge>
          </div>

          <div style={rowStyle}>
            <label style={labelStyle} htmlFor="claim-text">Claim</label>
            <textarea id="claim-text" rows={3} style={inputStyle} value={draft.text}
              placeholder="A sentence a reader could disagree with."
              onChange={e => setDraft({ ...draft, text: e.target.value })} />
          </div>

          <div style={{ ...rowStyle, display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10 }}>
            <div>
              <label style={labelStyle} htmlFor="claim-status">Status</label>
              <select id="claim-status" style={inputStyle} value={draft.status}
                onChange={e => setDraft({ ...draft, status: e.target.value as ClaimStatus })}>
                {CLAIM_STATUSES.map(s => <option key={s} value={s}>{s}</option>)}
              </select>
            </div>
            <div>
              <label style={labelStyle} htmlFor="claim-id">Identifier</label>
              <input id="claim-id" style={inputStyle} value={draft.id}
                placeholder="generated from the claim text"
                onChange={e => setDraft({ ...draft, id: e.target.value })} />
              {!draft.id && draft.text.trim() && (
                <div style={{ fontSize: '.72rem', color: 'var(--color-muted-fg)', marginTop: 2 }}>
                  will be saved as <code>{nextClaimId(claims, draft.text)}</code>
                </div>
              )}
            </div>
          </div>

          <div style={rowStyle}>
            <div style={sectionTitleStyle}>Scope — the fibre this claim is about</div>
            <ScopeEditor value={draft.scope} context={context}
              onChange={scope => setDraft({ ...draft, scope })} />
            <div style={{ fontSize: '.74rem', color: 'var(--color-muted-fg)', marginTop: 6 }}>
              {scopeSummary(draft.scope)}
            </div>
            {onUseInFibre && draft.scope.values.length > 0 && (
              <button className="btn btn-sm" style={{ marginTop: 6 }}
                onClick={() => onUseInFibre(draft.scope)}>
                Open this fibre
              </button>
            )}
          </div>

          <div style={rowStyle}>
            <div style={sectionTitleStyle}>Warrant — why it follows</div>
            {draft.warrant.map((w, i) => (
              <div key={i} style={{
                display: 'grid', gridTemplateColumns: '140px 1fr 1fr auto', gap: 6,
                marginBottom: 6, alignItems: 'start',
              }}>
                <select style={inputStyle} value={w.kind} aria-label={`Warrant ${i + 1} kind`}
                  onChange={e => updateWarrant(i, { kind: e.target.value as WarrantKind })}>
                  {WARRANT_KINDS.map(k => <option key={k} value={k}>{k}</option>)}
                </select>
                <input style={inputStyle} value={w.text} placeholder="what it shows"
                  aria-label={`Warrant ${i + 1} text`}
                  onChange={e => updateWarrant(i, { text: e.target.value })} />
                <input style={inputStyle} value={w.ref ?? ''} placeholder="reference (DOI, file, fibre)"
                  aria-label={`Warrant ${i + 1} reference`}
                  onChange={e => updateWarrant(i, { ref: e.target.value })} />
                <button className="btn btn-sm btn-danger" aria-label={`Remove warrant ${i + 1}`}
                  onClick={() => setDraft({ ...draft, warrant: draft.warrant.filter((_, j) => j !== i) })}>
                  ×
                </button>
              </div>
            ))}
            <button className="btn btn-sm" disabled={draft.warrant.length >= 5}
              onClick={() => setDraft({ ...draft, warrant: [...draft.warrant, emptyWarrant()] })}>
              Add warrant
            </button>
            <div style={{ fontSize: '.74rem', color: 'var(--color-muted-fg)', marginTop: 4 }}>
              ‘supported’ needs a measurement, citation or inference. A definition fixes the
              words; it cannot carry an empirical claim.
            </div>
            {supportedWithoutEvidence && (
              <div style={{ marginTop: 6 }}>
                <Notice tone="bad">
                  This claim is marked supported with no evidential warrant, so it cannot be saved.
                </Notice>
              </div>
            )}
          </div>

          <div style={rowStyle}>
            <label style={labelStyle} htmlFor="claim-caveats">Caveats — one per line</label>
            <textarea id="claim-caveats" rows={2} style={inputStyle}
              value={caveatsText}
              placeholder="What would make this claim false, or where it does not apply?"
              onChange={e => setCaveatsText(e.target.value)} />
          </div>

          {errors.length > 0 && (
            <div style={{ marginBottom: 10 }}>
              <Notice tone="warn">
                <ul style={{ margin: 0, paddingLeft: 18 }}>
                  {errors.map((e, i) => <li key={i}>{e}</li>)}
                </ul>
              </Notice>
            </div>
          )}

          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-primary" onClick={save} disabled={saving || errors.length > 0}>
              {saving ? 'Saving…' : 'Save claim'}
            </button>
            {selectedId && (
              <button className="btn btn-danger" onClick={() => remove(effective)} disabled={saving}>
                Delete
              </button>
            )}
            <button className="btn" onClick={() => { setDraft(null); setSelectedId(null); setCaveatsText('') }} disabled={saving}>
              Discard
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
