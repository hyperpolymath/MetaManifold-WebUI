<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# Implementation progress — 2026-09-18

The migration is an architectural commitment, not contingent on whether Julia offers stronger static types. Boundary types and validation are useful improvements alongside the move.

## First slice implemented

See [UI setup and commands](../../ui/README.md).

- Separate ui/ project and resolved manifest: Julia 1.12.5, Genie 6.0.5, Stipple 1.0.4, StippleUI 1.0.1, HTTP 2.7.0, JSON3 1.14.3.
- Root project/manifest, existing Oxygen server and React frontend untouched.
- Read-only study list and detail page, direct runs/groups, counts and reactive Refresh.
- Typed StudySummary/Study boundary decoding; missing, malformed and inconsistent data is rejected.
- Server-configured HTTP adapter, encoded study paths, bounded requests, redirects disabled, no browser-configurable backend address.
- Deliberately independent page models: Stipple session model restoration disabled as well as cross-window channel sharing. Disabling only shared channels was insufficient: browser testing caught restored detail state leaking into the list route.
- Explicit route matcher covers underscores in existing study names; default Genie matching excluded them in the tested version.
- Displayed data uses Vue text interpolation, not untrusted raw HTML.
- Fixture-only backend and test-data banner; no scientific data is modified by this slice.

## Verification

- Installed Julia locally for validation after recon; tooling is not committed.
- 31 contract/URL-boundary tests passed.
- 7 real HTTP adapter tests passed against a disposable fixture API: list/detail, missing study, malformed shape, invalid JSON, redirect rejection and unavailable backend.
- Browser regression PASS (`ui/test/browser.cjs`): list, reactive refresh, navigation, direct load/reload, independent tabs, missing/malformed data, and local assets with external HTTP requests blocked. Tested in headless Chromium against the fixture backend.
- Added an isolated GitHub Actions contract-test workflow; it has not been executed on GitHub. It does not yet run the HTTP-fixture or browser suites.
- Normal precompilation exceeded sandbox time budgets; tests and preview run with `--compiled-modules=no --compile=min -O0`. Production startup/performance is not validated.
- No end-to-end run against the full Oxygen/scientific backend, no pipeline executions and no remote deployment/authentication certification.

## Next work

1. Verify against a disposable root served by the actual Oxygen backend, not just fixtures.
2. Port study create/rename/delete and group/run navigation with contract and browser tests.
3. Jobs/status/submission/cancellation and reconnection; preserve existing job/R semantics.
4. Configuration/editors, complete table behaviour and specialised charts per backlog.

Pilot detail paths are /studies/:study, deliberately separate from legacy slug routes. Deep-link compatibility is a later rollout item. The UI is not yet a replacement for the full application. This first slice is being published at the user’s request; consult Git history for the publication commit.

## Pre-publication checks

Fetched remote main before publication: it matched baseline ecefb1c, so no upstream merge conflicts required resolution. Restored workspace-snapshot omissions of tracked web/dist files and executable script modes; these are not migration changes. Reinstantiated the isolated UI environment and reran all 38 contract/URL/HTTP-adapter tests before committing. Root environment, existing frontend and scientific source remain unchanged.
