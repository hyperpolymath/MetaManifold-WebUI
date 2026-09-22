// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Dialog semantics e2e (#32). The two overlay modals were converted from
// presentational backdrop divs to native <dialog> elements opened with
// showModal(); the behaviours that conversion claims -- implicit dialog role,
// Escape-to-cancel, focus containment, focus restoration -- are only
// observable in a real browser, which is what this lane exists to provide.
// Backdrop-click-to-dismiss is dropped deliberately (form dialogs: a stray
// click must not discard typed input); the last test pins that decision.
import { test, expect, type Page, type Locator } from '@playwright/test'

// NameDialog is mounted by several views; StudiesView's "new study" flow is the
// shallowest route to it. The backend may be absent under the dev server, which
// does not matter here: the dialog's open/dismiss contract is client-side.
async function openNameDialog(page: Page): Promise<Locator> {
  await page.goto('/')
  const newStudy = page.getByRole('button', { name: /new study/i }).first()
  await expect(newStudy).toBeVisible({ timeout: 15000 })
  await newStudy.click()
  const dialog = page.locator('dialog')
  await expect(dialog).toBeVisible()
  return dialog
}

test('NameDialog is a native modal dialog with the implicit role', async ({ page }) => {
  const dialog = await openNameDialog(page)
  await expect(dialog).toHaveAttribute('open', '')
  // The claim under test is what the ACCESSIBILITY TREE exposes: showModal()
  // must put an implicit dialog role in front of assistive tech without the
  // component remembering to set role or aria-modal attributes itself.
  await expect(page.getByRole('dialog')).toBeVisible()
  await expect(dialog).toHaveJSProperty('open', true)
})

test('Escape closes the dialog with no hand-rolled keydown listener', async ({ page }) => {
  const dialog = await openNameDialog(page)
  await page.keyboard.press('Escape')
  await expect(dialog).not.toBeVisible()
})

test('Cancel closes the dialog and restores focus to the invoking control', async ({ page }) => {
  const trigger = page.getByRole('button', { name: /new study/i }).first()
  await page.goto('/')
  await expect(trigger).toBeVisible({ timeout: 15000 })
  await trigger.focus()
  await trigger.click()
  const dialog = page.locator('dialog')
  await expect(dialog).toBeVisible()
  await dialog.getByRole('button', { name: /cancel/i }).click()
  await expect(dialog).not.toBeVisible()
  // showModal() remembers the previously focused element; close() restores it.
  await expect(trigger).toBeFocused()
})

test('focus stays inside the open dialog: Tab never reaches the page behind', async ({ page }) => {
  await openNameDialog(page)
  // Cycle Tab far enough to wrap if the trap were broken.
  for (let i = 0; i < 12; i++) await page.keyboard.press('Tab')
  const activeInDialog = await page.evaluate(() => {
    const dialog = document.querySelector('dialog')
    const active = document.activeElement
    return !!dialog && !!active && dialog.contains(active)
  })
  expect(activeInDialog).toBe(true)
})

test('backdrop click deliberately does NOT dismiss a form dialog', async ({ page }) => {
  // Decision recorded per #32 criterion 6: these dialogs carry typed input, so
  // a stray click outside the panel must not discard it. Escape and Cancel are
  // the dismissals. This test pins the decision so a "restore backdrop click"
  // change cannot land silently.
  const dialog = await openNameDialog(page)
  await page.locator('#root').click({ position: { x: 5, y: 5 }, force: true })
  await expect(dialog).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(dialog).not.toBeVisible()
})
