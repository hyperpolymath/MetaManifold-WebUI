// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Opt-in e2e lane (NOT part of `bun run check` yet — browser binaries are a
// CI provisioning decision for a later prompt; see
// docs/testing/infrastructure.md). Standard Playwright configuration shape;
// file naming uses *.e2e.ts so `bun test` discovery never picks these up
// (bun discovers *.test.* / *.spec.* only).
import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: 'tests/e2e',
  testMatch: '**/*.e2e.ts',
  use: {
    // The dev server is started by webServer below; in split deployments set
    // PLAYWRIGHT_BASE_URL to the already-running instance instead.
    baseURL: process.env['PLAYWRIGHT_BASE_URL'] ?? 'http://localhost:5173',
  },
  webServer: {
    command: 'bun run dev',
    url: 'http://localhost:5173',
    reuseExistingServer: true,
  },
})
