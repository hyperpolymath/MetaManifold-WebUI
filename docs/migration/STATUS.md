# Migration and distribution status

Updated 2026-09-18. This document distinguishes implemented work from agreed requirements. Packaging policy is in ../../packaging/; UI execution instructions are in ../../ui/README.md.

## Implemented and published before this update

Commit a4b9f81 contains the first opt-in Stipple/Vue UI slice: isolated Julia environment and manifest, read-only studies/list/detail, refresh and error states, typed study DTOs and validated backend adapter, tests, CI and migration inventories. The legacy React app remains the default and the scientific backend is unchanged.

Evidence at that milestone: 38 local Julia checks and browser fixture tests passed. GitHub's main CI and Stipple contract workflow subsequently passed. The GitHub contract workflow runs 31 contract/URL checks; the extra seven HTTP-adapter checks and browser suite were run locally, not by that workflow. Full scientific-backend integration with the new UI remains pending.

## Agreed requirements, not yet delivered functionality

- Julia-authored Stipple/Vue frontend; all existing features retained, progressively. Small JavaScript adapters are allowed. No new application TypeScript; existing TS can remain until replacement reaches parity.
- Bun only for JavaScript tooling. No npm, pnpm or Deno commands. The new browser test currently still uses Node instructions and must be converted and verified under Bun.
- Local single-user operation first; authenticated remote/multiuser deployment later. Do not expose the present local server as if it were multiuser-ready.
- Standalone offline-first release archives for native Linux x86-64 and ARM64. Guix builds the environment; users do not install Guix. Bundle mise, just and Bun, application runtimes/packages, scientific tools and web assets. Users provide sequencing data and reference databases; a compatible host kernel/CPU and existing browser remain prerequisites.
- Secondary WSL2 compatibility using the Linux archives. Native Linux is primary; WSL1/native Windows are outside scope. Neither native standalone artifacts nor WSL2 compatibility has yet been validated.
- Automatic coordinated updates while online and idle. Track latest compatible stable versions as one tested, pinned release; no independent in-place component upgrades. Signed metadata, hashes, transactional switch, health checks and rollback required. Startup must work offline.

## Remaining workstreams

### A. Finish the application migration

1. Integrate the new UI against the actual Oxygen backend with disposable data; verify API contracts beyond synthetic fixtures.
2. Study create/rename/delete with confirmations, invalid-input handling and recovery; groups, runs, pooled-run navigation and legacy deep-link behaviour.
3. Jobs and pipeline controls: submit stages/runs, status/progress/logs, cancellation, event feed, reconnect snapshots, bounded subscriptions and cleanup. Preserve R runtime coordination and job/provenance semantics.
4. Default/study/group/run configuration inheritance and overrides; primer/database editors and downloads; composition/category/filter libraries.
5. Full results table parity: server pagination/sort/filter/distinct values, column settings/persistence, highlighting/copy, OTU details, saved tables, annotation/contamination edits and exports/reports.
6. Plotly parity, sizing/export/cosmetics, replacement for React chart editor, and Euler/UpSet visualisations. These and the custom table are major remaining parity risks. A Julia chart wrapper alone does not replace a chart editor.
7. Browser regression and scientific-result comparisons, default switch, then remove React/TypeScript/Vite/Bun frontend build dependencies that are no longer used. Keep Bun for approved JS adapters/tooling. Retain fallback UI until replacements are accepted.

### B. Build real standalone releases

1. Audit runtime closure and every lazy-download path: both Julia environments/artifacts, R/RCall/Bioconductor, Python tools, Java/FastQC, native libraries, executables, static assets and licenses/source obligations.
2. Define pinned Guix channels/recipes and mise/just build tasks. Current packaging files are policy only; no working Guix release builder exists yet.
3. Implement architecture-specific release build/assembly. Do not upgrade the Oxygen HTTP 1 environment merely to share the UI's HTTP 2 environment.
4. Provide unprivileged launcher, writable state outside immutable releases, browser access and diagnostics. Deliver prebuilt legacy UI while migration is incomplete; never build/install at first launch.
5. Prove relocatable offline execution with no preinstalled application toolchain, Guix or /gnu/store, including paths with spaces and lazy scientific functionality. Establish supported kernel/CPU baseline and storage/RAM guidance; measure artifact sizes rather than guessing.
6. Verify both native architectures, then explicit WSL2 tests: Linux-filesystem install, Windows-browser localhost access, scientific tools, shutdown and update behaviour. Publish verified versus unverified environments honestly.
7. Publish architecture-specific archives, hashes, signed metadata and component/license inventory on GitHub Releases. A source ZIP is not the standalone product.

### C. Implement the coordinated updater

1. Stable-version discovery and candidate lockfile updates through release tooling; test the whole combination. Document held-back incompatible versions.
2. Establish signing/trust-key provisioning and release metadata format; configure publication secrets securely.
3. Build asynchronous online checking/staging, architecture selection, signature/hash verification, archive extraction safety, expiry and anti-replay rules.
4. Add a backend-owned exclusive update/job-submission gate so an idle check cannot race with a new job. Future multiuser installations require installation-wide coordination, not per-tab checks.
5. Atomic release switch, restart/health probes, interruption/disk-full/corruption handling and rollback; keep current release usable offline. Schema/data migration recovery must be explicit: binary rollback alone cannot undo data changes.
6. Add maintenance/pause controls for operators and failure-mode tests on both architectures/WSL2.

### D. Add remote hosting and multiuser operation

Authentication and session security; roles and study permissions; job ownership/quotas/scheduling; persistence and recovery across backend restarts; installation-wide R/runtime concurrency strategy; protected file/download routes; TLS/reverse-proxy and WebSocket origin policy; backups, auditability and operator-managed updates. Per-page state isolation in the first UI slice is necessary but does not implement these requirements.

### E. Testing and delivery follow-through

Convert Node-based browser instructions to Bun and test them. Add actual-backend/browser checks to CI; add native ARM64 and WSL2 acceptance environments. Keep scientific tests unchanged unless justified separately. Version the feature-parity checklist and publish known limitations. No final cutover until existing features have replacements and release acceptance gates pass.

## Recommended next sequence

1. Start runtime/dependency audit and Guix feasibility work now; in parallel, complete disposable actual-backend validation of the Stipple slice.
2. Produce the first real offline x86-64 archive retaining the existing full UI plus the opt-in Stipple UI. Packaging need not wait for complete UI migration.
3. Establish native ARM64 builds and secondary WSL2 verification.
4. Continue feature migration; add signed update infrastructure after immutable releases and acceptance tests exist.
5. Add remote/multiuser capabilities as an explicit later delivery stage, not a networking flag.

## What needs owner input later

No more product clarification is needed to begin the audit or next UI slice. Later requirements: suitable build/test capacity for ARM64 and WSL2; secure GitHub authentication and release-signing configuration; representative non-sensitive scientific fixtures; remote host/identity provider and study-sharing rules. Do not send signing private keys or access tokens in chat. Existing shared access tokens should be revoked.
