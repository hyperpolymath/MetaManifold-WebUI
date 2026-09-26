// SPDX-License-Identifier: MPL-2.0
// Browser adapter contracts. HTML must be emitted by DOIWeb.render_page in the
// Julia suite (DOI_CONTRACT_ARTIFACTS). HTTP below is an explicitly synthetic API;
// no request can reach Zenodo, a real study, or a GitHub release.
import { test, expect, beforeAll, afterAll } from 'bun:test'
import { chromium, expect as browserExpect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const root = resolve(import.meta.dir, '../..')
const artifacts = process.env.DOI_CONTRACT_ARTIFACTS
const configId = '12345678-1234-4234-8234-123456789012'
let browser
beforeAll(async () => {
  if (!artifacts) throw new Error('DOI_CONTRACT_ARTIFACTS must point to Julia-emitted publication HTML. This browser lane does not silently skip missing fixtures.')
  browser = await chromium.launch({
    headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  })
}, 30000)
afterAll(async () => { await browser?.close() })

function record(environment = 'sandbox') {
  return { id: 'a'.repeat(64), state: 'ready', environment, metadata: { title: 'Reviewed fixture', license: 'CC-BY-4.0' },
    binding: { kind: 'configuration', config_id: configId, result_id: null, dangerous: false },
    bundle_sha256: 'b'.repeat(64), deposition_id: '101', reserved_doi: `${environment === 'sandbox' ? '10.5072' : '10.5281'}/zenodo.101`,
    doi: null, doi_url: null, draft_url: `https://${environment === 'sandbox' ? 'sandbox.' : ''}zenodo.org/deposit/101`,
    last_error: null, confirmation_phrase: `PUBLISH ${environment} 101`, test_record: environment === 'sandbox',
  }
}
function published(row) {
  return { ...row, state: 'published', doi: row.reserved_doi, doi_url: `https://doi.org/${row.reserved_doi}`, citation: `Example, Ada. Fixture. https://doi.org/${row.reserved_doi}` }
}

async function fixture(fn, { initial = [], variant = 'publication', failPublish = false } = {}) {
  let rows = structuredClone(initial)
  const calls = []
  const html = readFileSync(join(artifacts, `${variant}.html`), 'utf8')
  const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } })
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(req) {
    const path = new URL(req.url).pathname
    if (path === '/') return new Response(html, { headers: { 'Content-Type': 'text/html' } })
    if (path.startsWith('/api/v1/doi/assets/')) {
      const file = path.split('/').at(-1)
      if (!['publication.js', 'publication.css'].includes(file)) return new Response('', { status: 404 })
      return new Response(readFileSync(join(root, 'src/doi/assets', file)), { headers: { 'Content-Type': file.endsWith('.js') ? 'text/javascript' : 'text/css' } })
    }
    if (req.method === 'GET') {
      if (path.endsWith('/analysis-config')) return json({ configs: [{ id: configId, method: 'nb_glm', formula: '~ group', hash: 'c'.repeat(64), dangerous: false }] })
      if (path.endsWith('/results')) return json({ results: [{ id: 'mock-fixture', hash: 'd'.repeat(64), publishable: false }] })
      if (path.endsWith('/doi-publications')) return json({ publications: rows })
      if (path.includes('/download/')) return new Response('synthetic reviewed fixture')
    }
    const body = await req.json()
    calls.push({ method: req.method, path, body, csrf: req.headers.get('X-DOI-CSRF') })
    if (path.endsWith('/doi-publications')) {
      rows = [{ ...record(), metadata: body.metadata }]
      return json(rows[0])
    }
    if (path.endsWith('/publish')) {
      if (failPublish) {
        rows[0].state = 'publication_uncertain'
        return json({ message: 'Lost Zenodo response. Reconcile the existing publication.' }, 502)
      }
      rows[0] = published(rows[0])
      return json(rows[0])
    }
    if (path.endsWith('/refresh')) { rows[0] = published(rows[0]); return json(rows[0]) }
    return json({ message: 'Unexpected fixture request' }, 500)
  } })
  const context = await browser.newContext()
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    await page.goto(`http://127.0.0.1:${server.port}`)
    await browserExpect(page.locator('#config-id')).toContainText(configId)
    await fn(page, calls)
    expect(errors).toEqual([])
  } finally { await context.close(); server.stop(true) }
}

const enable = page => page.getByRole('checkbox', { name: 'Enable Evidence Mode' }).check()
const publishes = calls => calls.filter(c => c.path.endsWith('/publish'))

test('prepare is explicit, secret-free and not a publish operation', async () => {
  await fixture(async (page, calls) => {
    await browserExpect(page.locator('#advanced')).toBeHidden()
    await page.setViewportSize({ width: 375, height: 812 })
    await enable(page)
    await page.locator('#config-id').selectOption(configId)
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await browserExpect(page.locator('#result-id option[value="mock-fixture"]')).toHaveJSProperty('disabled', true)
    await page.locator('#result-id').selectOption('config-only')
    await page.locator('#title').fill('<img src=x onerror="alert(1)"> Citation fixture')
    await page.locator('#description').fill('Configuration only, no results.')
    await page.locator('#creators').fill('Example, Ada\nExample, Grace')
    await page.locator('#license').selectOption('CC-BY-4.0')
    await page.locator('#upload-ack').check()
    await page.getByRole('button', { name: 'Prepare Zenodo draft' }).click()
    await browserExpect(page.getByRole('button', { name: 'Mint DOI…' })).toBeVisible()
    expect(calls.length).toBe(1)
    expect(calls[0].body.result_id).toBeNull()
    expect(calls[0].body.acknowledge_upload).toBe(true)
    expect(calls[0].body.metadata.creators).toHaveLength(2)
    expect(calls[0].csrf).toBe('fixture-csrf')
    expect(JSON.stringify(calls)).not.toContain('access_token')
    expect(publishes(calls)).toHaveLength(0)
    await browserExpect(page.locator('#publications img')).toHaveCount(0)
    await browserExpect(page.locator('.doi-badge')).toHaveCount(0)
    await browserExpect(page.locator('#publications')).toContainText('not yet a published DOI')
  })
}, 30000)

test('wrong phrase, missing acknowledgement and cancel cannot publish; correct confirmation posts once', async () => {
  await fixture(async (page, calls) => {
    await page.getByRole('button', { name: 'Mint DOI…' }).click()
    await browserExpect(page.getByRole('dialog')).not.toBeVisible()
    await enable(page)
    await page.getByRole('button', { name: 'Mint DOI…' }).click()
    await browserExpect(page.getByRole('dialog')).toBeVisible()
    await browserExpect(page.getByRole('button', { name: 'Publish & mint DOI' })).toBeDisabled()
    await page.locator('#confirmation').fill('PUBLISH production 101')
    await page.locator('#public-ack').check()
    await browserExpect(page.getByRole('button', { name: 'Publish & mint DOI' })).toBeDisabled()
    await page.getByRole('button', { name: 'Cancel — keep draft' }).click()
    expect(publishes(calls)).toHaveLength(0)
    await page.getByRole('button', { name: 'Mint DOI…' }).click()
    await page.locator('#confirmation').fill('PUBLISH sandbox 101')
    await browserExpect(page.getByRole('button', { name: 'Publish & mint DOI' })).toBeDisabled()
    await page.locator('#public-ack').check()
    await page.getByRole('button', { name: 'Publish & mint DOI' }).click()
    await browserExpect(page.locator('.doi-badge')).toHaveText('TEST DOI (sandbox): 10.5072/zenodo.101')
    expect(publishes(calls)).toHaveLength(1)
    expect(publishes(calls)[0].body).toEqual({ confirmation: 'PUBLISH sandbox 101', bundle_sha256: 'b'.repeat(64), acknowledge_public: true })
    await page.getByRole('button', { name: 'Reload saved publications' }).click()
    expect(publishes(calls)).toHaveLength(1)
    await browserExpect(page.getByRole('link', { name: 'Download provenance receipt' })).toBeVisible()
  }, { initial: [record()] })
}, 30000)

test('lost publish response exposes reconciliation, not a retry-publish button', async () => {
  await fixture(async (page, calls) => {
    await enable(page)
    await page.getByRole('button', { name: 'Mint DOI…' }).click()
    await page.locator('#confirmation').fill('PUBLISH sandbox 101')
    await page.locator('#public-ack').check()
    await page.getByRole('button', { name: 'Publish & mint DOI' }).click()
    await browserExpect(page.getByRole('alert')).toContainText('Lost Zenodo response')
    await browserExpect(page.getByRole('button', { name: 'Mint DOI…' })).toHaveCount(0)
    await browserExpect(page.locator('.doi-badge')).toHaveCount(0)
    await page.getByRole('button', { name: 'Refresh from Zenodo' }).click()
    await browserExpect(page.locator('.doi-badge')).toBeVisible()
    expect(publishes(calls)).toHaveLength(1)
  }, { initial: [record()], failPublish: true })
}, 30000)

test('production and sandbox badges are distinct, and disabled servers remain read-only', async () => {
  await fixture(async (page, calls) => {
    await browserExpect(page.locator('.production')).toContainText('real, permanent')
    await browserExpect(page.locator('.doi-badge')).toHaveText('DOI: 10.5281/zenodo.101')
    expect(calls).toHaveLength(0)
  }, { initial: [published(record('production'))], variant: 'publication-production' })
  await fixture(async (page, calls) => {
    await enable(page)
    await browserExpect(page.locator('#disabled-notice')).toBeVisible()
    await browserExpect(page.getByRole('button', { name: 'Prepare Zenodo draft' })).toBeDisabled()
    await browserExpect(page.getByRole('button', { name: 'Mint DOI…' })).toBeDisabled()
    expect(calls).toHaveLength(0)
  }, { initial: [record()], variant: 'publication-disabled' })
}, 30000)
