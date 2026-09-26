// SPDX-License-Identifier: MPL-2.0
// These tests execute the real Bash/gh linker against an isolated fake gh binary.
import { describe, test, expect } from 'bun:test'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { validateCitation } from './citation-validation.js'

const root = resolve(import.meta.dir, '../..')
const id = 'a'.repeat(64)
const marker = `<!-- metamanifold-doi:${id} -->`
const receipt = () => ({
  schema_version: '1.0.0', id, state: 'published', environment: 'production', test_record: false,
  doi: '10.5281/zenodo.101', reserved_doi: '10.5281/zenodo.101', doi_url: 'https://doi.org/10.5281/zenodo.101',
  bundle_sha256: 'b'.repeat(64),
  binding: { config_hash: 'c'.repeat(64), kind: 'configuration', dangerous: true },
  metadata: { title: 'Analysis citation', creators: [{ name: 'Example, Ada' }], version: '1.0.0', publication_date: '2026-01-01', license: 'CC-BY-4.0',
    github_release_url: 'https://github.com/example/research/releases/tag/v1.0.0', github_project_url: 'https://github.com/users/example/projects/2' },
})
const gh = `#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_GH_STATE"
jq -cn --args '$ARGS.positional' -- "$@" >> "$state/calls.jsonl"
if [[ "\${GH_FAIL:-}" == "$1 $2" ]]; then echo 'raw error FAKE-SENSITIVE-TOKEN' >&2; exit 1; fi
kind="$1 $2"; shift 2
getarg() { local key="$1"; shift; while [[ $# -gt 0 ]]; do if [[ "$1" == "$key" ]]; then printf '%s' "$2"; return; fi; shift; done; }
case "$kind" in
  'release view') cat "$state/release.json" ;;
  'release edit') notes=$(getarg --notes-file "$@"); jq --rawfile body "$notes" '.body=$body' "$state/release.json" > "$state/new.json"; mv "$state/new.json" "$state/release.json" ;;
  'release upload') for arg in "$@"; do if [[ -f "$arg" ]]; then cp "$arg" "$state/assets/"; fi; done ;;
  'project --help') exit 0 ;;
  'project item-list') cat "$state/items.json" ;;
  'project item-create') body=$(getarg --body "$@"); jq --arg body "$body" '.items += [{id:"PVTI_fixture",content:{id:"DI_fixture",type:"DraftIssue",body:$body}}] | .totalCount=(.items|length)' "$state/items.json" > "$state/new.json"; mv "$state/new.json" "$state/items.json"; echo '{"id":"PVTI_fixture"}' ;;
  'project item-edit') [[ $(getarg --id "$@") == DI_fixture ]] || exit 1; body=$(getarg --body "$@"); jq --arg body "$body" '.items[0].content.body=$body' "$state/items.json" > "$state/new.json"; mv "$state/new.json" "$state/items.json" ;;
  *) echo 'unexpected gh command' >&2; exit 1 ;;
esac
`

function fixture(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'doi-linker-'))
  try {
    mkdirSync(join(dir, 'bin')); mkdirSync(join(dir, 'assets'))
    writeFileSync(join(dir, 'bin/gh'), gh); chmodSync(join(dir, 'bin/gh'), 0o700)
    writeFileSync(join(dir, 'calls.jsonl'), '')
    writeFileSync(join(dir, 'receipt.json'), JSON.stringify(receipt()))
    writeFileSync(join(dir, 'release.json'), JSON.stringify({ body: 'Original release notes.\nDo not remove.', url: receipt().metadata.github_release_url, isDraft: false }))
    writeFileSync(join(dir, 'items.json'), JSON.stringify({ items: [], totalCount: 0 }))
    const run = (apply = false, extraEnv = {}) => spawnSync('bash', [join(root, 'scripts/link-doi.sh'), '--receipt', join(dir, 'receipt.json'), ...(apply ? ['--apply'] : [])], {
      encoding: 'utf8', env: { ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, FAKE_GH_STATE: dir, ...extraEnv },
    })
    const calls = () => readFileSync(join(dir, 'calls.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(s => JSON.parse(s))
    fn({ dir, run, calls })
  } finally { rmSync(dir, { recursive: true, force: true }) }
}

describe('link an existing DOI without ever minting another', () => {
  test('default dry run is validated, descriptive, and completely offline', () => fixture(({ run, calls }) => {
    const out = run()
    expect(out.status).toBe(0)
    expect(out.stdout).toContain('DRY RUN')
    expect(out.stdout).toContain('https://doi.org/10.5281/zenodo.101')
    expect(out.stdout).toContain('Configuration only')
    expect(calls()).toEqual([])
  }))

  test('apply preserves notes, attaches citable assets, and upserts a single project item', () => fixture(({ dir, run, calls }) => {
    let out = run(true)
    expect(out.stderr).toBe('')
    expect(out.status).toBe(0)
    out = run(true)
    expect(out.stderr).toBe('')
    expect(out.status).toBe(0)
    const release = JSON.parse(readFileSync(join(dir, 'release.json'), 'utf8'))
    expect(release.body).toContain('Original release notes.\nDo not remove.')
    expect(release.body.split(marker).length - 1).toBe(1)
    expect(release.body).toContain('DANGER')
    const items = JSON.parse(readFileSync(join(dir, 'items.json'), 'utf8'))
    expect(items.items.length).toBe(1)
    expect(items.items[0].content.body).toContain(marker)
    expect(calls().filter(c => c[0] === 'project' && c[1] === 'item-create').length).toBe(1)
    expect(calls().filter(c => c[0] === 'project' && c[1] === 'item-edit').length).toBe(1)
    expect(calls().some(c => c[0] === 'release' && c[1] === 'create')).toBe(false)
    expect(readFileSync(join(dir, `assets/publication-${id}.json`), 'utf8')).toContain('10.5281/zenodo.101')
    const citation = validateCitation(readFileSync(join(dir, `assets/citation-${id}.cff`), 'utf8'))
    expect(citation.type).toBe('dataset')
    expect(citation.doi).toBe('10.5281/zenodo.101')
  }))

  test('sandbox, pending, malformed and foreign-link receipts fail before any gh invocation', () => {
    for (const mutate of [r => { r.environment = 'sandbox' }, r => { r.state = 'ready' }, r => { r.reserved_doi = '10.5281/zenodo.102' },
      r => { r.metadata.github_release_url = 'https://attacker.example/a/b' }, r => { r.metadata.github_release_url += '?token=secret' }, r => { r.bundle_sha256 = '../bad' }]) {
      fixture(({ dir, run, calls }) => {
        const data = receipt(); mutate(data)
        writeFileSync(join(dir, 'receipt.json'), JSON.stringify(data))
        expect(run(true).status).not.toBe(0)
        expect(calls()).toEqual([])
      })
    }
  })

  test('draft releases and ambiguous release blocks are not edited', () => {
    for (const value of [{ isDraft: true }, { body: marker }, { body: `${marker}\n${marker}\n<!-- /metamanifold-doi:${id} -->` }]) {
      fixture(({ dir, run, calls }) => {
        writeFileSync(join(dir, 'release.json'), JSON.stringify({ url: receipt().metadata.github_release_url, body: '', isDraft: false, ...value }))
        expect(run(true).status).not.toBe(0)
        expect(calls().filter(c => c[0] === 'release' && c[1] === 'edit')).toEqual([])
      })
    }
  })

  test('an incomplete project listing cannot create a duplicate item', () => fixture(({ dir, run, calls }) => {
    writeFileSync(join(dir, 'items.json'), JSON.stringify({ items: [], totalCount: 10001 }))
    const out = run(true)
    expect(out.status).not.toBe(0)
    expect(out.stderr).toContain('incomplete')
    expect(calls().filter(c => c[0] === 'project' && c[1] === 'item-create')).toEqual([])
  }))

  test('titles cannot inject managed markers or release Markdown', () => fixture(({ dir, run }) => {
    const data = receipt(); data.metadata.title = marker
    writeFileSync(join(dir, 'receipt.json'), JSON.stringify(data))
    expect(run(true).status).toBe(0)
    expect(run(true).status).toBe(0)
    const notes = JSON.parse(readFileSync(join(dir, 'release.json'), 'utf8')).body
    expect(notes.split(marker).length - 1).toBe(1)
    expect(notes).toContain('\\<!-- metamanifold-doi:')
  }))

  test('missing counts, duplicate markers, or a converted project item cannot be updated', () => {
    const content = { id: 'DI_fixture', type: 'DraftIssue', body: marker }
    for (const listing of [{ items: [] },
      { items: [{ id: 'PVTI_1', content }, { id: 'PVTI_2', content }], totalCount: 2 },
      { items: [{ id: 'PVTI_1', content: { ...content, type: 'Issue', id: 'I_fixture' } }], totalCount: 1 }]) {
      fixture(({ dir, run, calls }) => {
        writeFileSync(join(dir, 'items.json'), JSON.stringify(listing))
        expect(run(true).status).not.toBe(0)
        expect(calls().filter(c => c[0] === 'project' && ['item-create', 'item-edit'].includes(c[1]))).toEqual([])
      })
    }
  })

  test('partial GitHub failure is sanitized and can be resumed with the same receipt', () => fixture(({ run, calls }) => {
    const out = run(true, { GH_FAIL: 'project item-create' })
    expect(out.status).not.toBe(0)
    expect(out.stderr).toContain('retry this same receipt')
    expect(out.stderr).not.toContain('FAKE-SENSITIVE-TOKEN')
    expect(run(true).status).toBe(0)
    expect(calls().every(c => ['release', 'project'].includes(c[0]))).toBe(true)
  }))
})
