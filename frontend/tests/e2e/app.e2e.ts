// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Opt-in e2e scaffold (playwright lane) — NOT discovered by `bun test`
// (file suffix is .e2e.ts by design) and NOT part of `bun run check`.
// One smoke: the app shell mounts something into #root. Domain-complete e2e
// is Prompt 5+ territory.
import { test, expect } from '@playwright/test'

test('app shell mounts the React root', async ({ page }) => {
  await page.goto('/')
  await expect(page.locator('#root')).not.toBeEmpty()
})
