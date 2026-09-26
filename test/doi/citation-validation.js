// SPDX-License-Identifier: MPL-2.0
import Ajv from 'ajv'
import addFormats from 'ajv-formats'
import { parse } from 'yaml'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const ajv = new Ajv({ allErrors: true, strict: false })
addFormats(ajv)
const check = ajv.compile(JSON.parse(readFileSync(join(import.meta.dir, 'vendor/cff-1.2.0.schema.json'), 'utf8')))
export function validateCitation(text) {
  const data = parse(text)
  if (!check(data)) throw new Error(`CFF 1.2.0: ${ajv.errorsText(check.errors)}`)
  return data
}
