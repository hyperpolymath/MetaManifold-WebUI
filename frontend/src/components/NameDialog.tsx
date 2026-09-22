// SPDX-License-Identifier: AGPL-3.0-only
import { useState, useRef, useEffect } from 'react'
import { errorMessage } from '../api/errorMessage'

interface Props {
  title: string
  initialValue?: string | undefined
  placeholder?: string | undefined
  onConfirm: (name: string) => Promise<void>
  onClose: () => void
}

// Native <dialog> opened with showModal() (#32). The browser supplies what the
// old presentational backdrop div hand-rolled badly or not at all: the dialog
// role, aria-modal, a focus trap, Escape-to-cancel, and focus restoration to
// the invoking control on close. Every dismissal routes through dialog.close()
// so the `close` event -- and therefore onClose -- fires exactly once whether
// the user pressed Escape, clicked the backdrop, or used Cancel.
export function NameDialog({ title, initialValue = '', placeholder = 'Name', onConfirm, onClose }: Props) {
  const [value, setValue] = useState(initialValue)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const dialogRef = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    // showModal() records the currently focused element -- the invoking
    // control -- as the one to restore on close. That record is taken at THIS
    // instant, so the input must not be focused before it: an autoFocus
    // attribute would move focus first and the dialog would then restore
    // focus to an element inside itself, dropping it on unmount. Focus the
    // input explicitly after the modal opens instead.
    dialogRef.current?.showModal()
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  const dismiss = () => dialogRef.current?.close()

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!value.trim()) return
    setBusy(true)
    setError('')
    try {
      await onConfirm(value.trim())
    } catch (err: unknown) {
      setError(errorMessage(err))
      setBusy(false)
    }
  }

  return (
    <dialog
      ref={dialogRef}
      className="mm-modal"
      aria-label={title}
      onClose={onClose}
      onClick={event => { if (event.target === dialogRef.current) dismiss() }}
    >
      <div style={{
        background: 'var(--color-bg)',
        border: '1px solid var(--color-border)',
        borderRadius: 10,
        padding: '20px 24px',
        minWidth: 320,
        boxShadow: '0 8px 32px rgba(0,0,0,.2)',
      }}>
        <h3 style={{ fontSize: '1rem', fontWeight: 700, marginBottom: 14 }}>{title}</h3>
        <form onSubmit={handleSubmit}>
          <input
            ref={inputRef}
            value={value}
            onChange={e => setValue(e.target.value)}
            placeholder={placeholder}
            disabled={busy}
            style={{
              width: '100%',
              padding: '7px 10px',
              fontSize: '.9rem',
              border: '1px solid var(--color-border)',
              borderRadius: 6,
              background: 'var(--color-surface)',
              color: 'var(--color-fg)',
              outline: 'none',
              marginBottom: 8,
            }}
          />
          {error && (
            <p style={{ color: '#c92a2a', fontSize: '.82rem', marginBottom: 8 }}>{error}</p>
          )}
          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button type="button" className="btn" onClick={dismiss} disabled={busy}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary" disabled={busy || !value.trim()}>
              {busy ? 'Saving...' : 'Save'}
            </button>
          </div>
        </form>
      </div>
    </dialog>
  )
}
