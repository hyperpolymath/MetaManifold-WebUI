// SPDX-License-Identifier: MPL-2.0
// Progressive-enhancement adapter only. The Julia service owns validation,
// snapshot identities and every lifecycle transition. No tokens or localStorage.
const boot = JSON.parse(document.getElementById('doi-bootstrap').textContent)
const base = `/api/v1/studies/${encodeURIComponent(boot.study)}`
const byId = id => document.getElementById(id)
let configs = []
let records = []
let selected = null
let busy = false

function element(tag, text, className) {
  const node = document.createElement(tag)
  if (text !== undefined) node.textContent = text
  if (className) node.className = className
  return node
}

async function request(path, body) {
  const response = await fetch(path, body === undefined ? { cache: 'no-store' } : {
    method: 'POST', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'X-DOI-CSRF': boot.csrf },
    body: JSON.stringify(body),
  })
  const data = await response.json().catch(() => ({ message: 'The server returned an unreadable response. Reload saved publications before retrying.' }))
  if (!response.ok) {
    const wait = response.headers.get('Retry-After')
    throw new Error((data.message || 'Publication operation failed.') + (wait ? ` Retry after ${wait} seconds.` : ''))
  }
  return data
}

function message(text = '') { byId('message').textContent = text }
function showError(error) {
  byId('error').hidden = false
  byId('error').textContent = error instanceof Error ? error.message : 'Publication operation failed.'
}
function clearError() { byId('error').hidden = true; byId('error').textContent = '' }

function setBusy(value) {
  busy = value
  byId('prepare-fields').disabled = value || !boot.enabled
  byId('reload').disabled = value
  byId('config-form').querySelector('button').disabled = value
  byId('evidence-mode').disabled = value
  for (const button of byId('publications').querySelectorAll('button')) button.disabled = value || !boot.enabled
  updateConfirmation()
}

async function operation(fn) {
  if (busy) return
  clearError()
  setBusy(true)
  try { await fn() } catch (error) { showError(error); message('No success is assumed. Reload or reconcile the existing publication before retrying.') }
  finally {
    // Reload even after a lost response: the write-ahead journal may contain a
    // newly created draft or an uncertain submission that must not be replayed.
    try { await loadPublications() } catch (error) { showError(error) }
    setBusy(false)
  }
}

function externalLink(text, url) {
  const link = element('a', text)
  // Defence in depth; the backend also constructs and validates every URL.
  const parsed = new URL(url, location.origin)
  if (parsed.protocol !== 'https:') return element('span', text)
  link.href = parsed.href
  link.target = '_blank'
  link.rel = 'noopener noreferrer'
  return link
}

function action(text, run, className) {
  const button = element('button', text, className)
  button.type = 'button'
  button.disabled = busy || !boot.enabled
  button.addEventListener('click', () => {
    if (!byId('evidence-mode').checked) {
      showError(new Error('Enable Evidence Mode before taking a publication action.'))
      byId('evidence-mode').focus()
      return
    }
    run()
  })
  return button
}

function renderPublications() {
  const host = byId('publications')
  host.replaceChildren()
  if (!records.length) { host.append(element('p', 'No saved publications. Preparing a draft never publishes it.')); return }
  for (const record of records) {
    const card = element('article', undefined, 'publication')
    card.append(element('h3', record.metadata.title))
    card.append(element('p', `${record.environment.toUpperCase()} · ${record.state.replaceAll('_', ' ')} · ${record.binding.kind === 'configuration' ? 'Configuration only — no analysis results' : 'Selected analysis result'}`, 'state'))
    card.append(element('p', `Config ${record.binding.config_id}${record.binding.result_id ? ` · Result ${record.binding.result_id}` : ''}`))
    if (record.binding.dangerous) card.append(element('p', 'DANGER: this configuration contains scientific overrides. Preserve and disclose the archived warning.', 'warning'))
    if (record.bundle_sha256) {
      card.append(element('pre', `Archive SHA-256\n${record.bundle_sha256}`))
      const download = element('a', 'Download exact archive for review')
      download.href = `${base}/doi-publications/${record.id}/download/bundle`
      card.append(download)
    }
    if (record.state === 'published') {
      const badge = externalLink(`${record.test_record ? 'TEST DOI (sandbox)' : 'DOI'}: ${record.doi}`, record.doi_url)
      badge.className = 'doi-badge'
      card.append(badge, element('p', record.citation))
      for (const [kind, label] of [['receipt', 'Download provenance receipt'], ['citation', 'Download CITATION.cff']]) {
        const link = element('a', label)
        link.href = `${base}/doi-publications/${record.id}/download/${kind}`
        card.append(link, document.createTextNode(' · '))
      }
    } else {
      if (record.reserved_doi) card.append(element('p', `Reserved identifier: ${record.reserved_doi} — not yet a published DOI.`))
      if (record.draft_url) card.append(externalLink('Review draft on Zenodo', record.draft_url))
      if (record.last_error) card.append(element('p', record.last_error.message, 'warning'))
      const controls = element('div', undefined, 'actions')
      if (['preparing', 'draft'].includes(record.state)) {
        controls.append(action('Resume draft preparation', () => operation(async () => {
          message('Resuming the same draft and frozen archive…')
          await request(`${base}/doi-publications/${record.id}/resume`, {})
          message('Draft preparation completed. Review before publishing.')
        })))
      }
      if (['creating', 'creation_uncertain'].includes(record.state)) {
        card.append(element('p', 'Creation outcome is uncertain. Find the existing draft with this publication marker on Zenodo. Never create a replacement automatically.'))
        card.append(element('code', record.id))
        const label = element('label', 'Existing Zenodo deposition ID')
        const input = element('input')
        input.inputMode = 'numeric'
        input.pattern = '[1-9][0-9]*'
        label.append(input)
        controls.append(label, action('Recover matching draft', () => operation(async () => {
          await request(`${base}/doi-publications/${record.id}/recover`, { deposition_id: input.value.trim() })
          message('Recovered the matching draft; no replacement was created.')
        })))
      }
      if (record.state === 'ready') controls.append(action('Mint DOI…', () => openConfirmation(record), 'danger'))
      if (record.deposition_id) controls.append(action('Refresh from Zenodo (never publishes)', () => operation(async () => {
        message('Checking the existing Zenodo deposition…')
        const current = await request(`${base}/doi-publications/${record.id}/refresh`, {})
        message(current.state === 'published' ? 'Publication verified. Your DOI is ready to cite.' : `Current state: ${current.state}. No publish request was sent.`)
      }), 'secondary'))
      if (['publishing', 'publication_uncertain'].includes(record.state)) card.append(element('p', 'Publication may still be processing. Refresh to reconcile it. If Zenodo still shows a draft after review, finish publication there manually, then refresh here; this application will not replay an uncertain publish request.'))
      card.append(controls)
    }
    host.append(card)
  }
}

async function loadPublications() {
  const data = await request(`${base}/doi-publications`)
  records = data.publications
  renderPublications()
}

async function loadConfigs(preferred) {
  const data = await request(`${base}/analysis-config`)
  configs = data.configs
  const select = byId('config-id')
  select.replaceChildren(new Option(configs.length ? 'Choose an immutable saved configuration' : 'No saved configurations — use the JSON form below', ''))
  for (const config of configs) select.add(new Option(`${config.method} · ${config.formula} · ${config.id}`, config.id))
  if (preferred && configs.some(c => c.id === preferred)) select.value = preferred
  await chooseConfig()
}

async function chooseConfig() {
  const id = byId('config-id').value
  const config = configs.find(c => c.id === id)
  byId('config-summary').textContent = config ? `Config SHA-256: ${config.hash}${config.dangerous ? ' — DANGER: scientific overrides present' : ''}` : ''
  byId('result-id').replaceChildren(new Option('Choose explicitly: configuration only or a completed result', ''))
  if (!config) return
  byId('result-id').add(new Option('Configuration only — no scientific result', 'config-only'))
  const data = await request(`${base}/analysis-config/${encodeURIComponent(id)}/results`)
  if (byId('config-id').value !== id) return // stale asynchronous selection
  for (const result of data.results) {
    const option = new Option(`${result.id} · ${result.publishable ? result.hash : 'mock/empty — not publishable'}`, result.id)
    option.disabled = !result.publishable
    byId('result-id').add(option)
  }
}

function openConfirmation(record) {
  selected = record
  byId('confirm-summary').textContent = `${record.environment.toUpperCase()} · ${record.metadata.title} · ${record.metadata.license} · ${record.binding.kind}`
  byId('confirm-hash').textContent = `Deposition ${record.deposition_id}\nSHA-256 ${record.bundle_sha256}`
  byId('expected-phrase').textContent = record.confirmation_phrase
  byId('confirmation').value = ''
  byId('public-ack').checked = false
  updateConfirmation()
  byId('publish-dialog').showModal()
  byId('confirmation').focus()
}
function updateConfirmation() {
  byId('confirm-publish').disabled = busy || !selected || !byId('public-ack').checked || byId('confirmation').value !== selected.confirmation_phrase
}

byId('evidence-mode').addEventListener('change', () => { byId('advanced').hidden = !byId('evidence-mode').checked })
byId('config-id').addEventListener('change', () => chooseConfig().catch(showError))
byId('reload').addEventListener('click', () => operation(async () => { await loadConfigs(byId('config-id').value); message('Saved state reloaded. No Zenodo mutation was requested.') }))
byId('confirmation').addEventListener('input', updateConfirmation)
byId('public-ack').addEventListener('change', updateConfirmation)
byId('cancel-publish').addEventListener('click', () => { byId('publish-dialog').close(); selected = null })
byId('publish-dialog').addEventListener('cancel', () => { selected = null })

byId('config-form').addEventListener('submit', event => {
  event.preventDefault()
  operation(async () => {
    const data = await request(`${base}/analysis-config`, JSON.parse(byId('config-json').value))
    await loadConfigs(data.config.id)
    message('Saved a new immutable configuration. No analysis was executed or DOI published.')
  })
})
byId('prepare-form').addEventListener('submit', event => {
  event.preventDefault()
  operation(async () => {
    const payload = byId('result-id').value
    if (!payload || !byId('upload-ack').checked) throw new Error('Choose a payload and acknowledge the upload first.')
    message('Preparing a private draft and verifying the frozen archive. Please wait…')
    await request(`${base}/doi-publications`, {
      config_id: byId('config-id').value,
      result_id: payload === 'config-only' ? null : payload,
      acknowledge_upload: true,
      metadata: {
        title: byId('title').value, description: byId('description').value,
        creators: byId('creators').value.split('\n').map(name => name.trim()).filter(Boolean).map(name => ({ name })),
        license: byId('license').value, version: byId('version').value,
        publication_date: byId('publication-date').value,
        github_release_url: byId('release-url').value || null,
        github_project_url: byId('project-url').value || null,
      },
    })
    message('Draft prepared — not published. Download and review its exact archive, then choose Mint DOI.')
  })
})
byId('publish-form').addEventListener('submit', event => {
  event.preventDefault()
  if (!selected || byId('confirm-publish').disabled) return
  const record = selected
  const confirmation = byId('confirmation').value
  byId('publish-dialog').close()
  selected = null
  operation(async () => {
    message('Submitting the one confirmed publication request…')
    const result = await request(`${base}/doi-publications/${record.id}/publish`, {
      confirmation, bundle_sha256: record.bundle_sha256, acknowledge_public: true,
    })
    message(result.state === 'published' ? 'Published and verified. Download the receipt and citation.' : 'Zenodo accepted the request but has not confirmed publication. Refresh the existing record; do not resubmit.')
  })
})

Promise.all([loadConfigs(boot.selected_config), loadPublications()]).catch(showError)
