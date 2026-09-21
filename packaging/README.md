<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# Standalone releases: agreed requirements

Status: **requirements recorded; release builder, signed updater and standalone binaries are not implemented yet.** Do not advertise the current source archive as an offline-ready application.

## Release boundary

Separate Linux x86-64 and ARM64 archives. Download, extract and launch without installing Julia, R, scientific tools, Guix, mise, just or Bun. Bundle mise, just and Bun. No npm/pnpm/Deno commands or new application TypeScript. Users supply their sequencing data and reference databases. Therefore offline startup and tool execution are guaranteed targets, but taxonomy workflows still require user-supplied compatible reference databases.

The ordinary kernel/CPU, sufficient storage/RAM, and a supported browser for the WebUI remain host requirements. Do not bundle Chromium by default: its size is disproportionate to a browser-based application. Establish and publish the Linux kernel baseline through clean-host testing. Native desktop/browser embedding would be a separate release-size decision.

All existing features must remain available during migration. Until Stipple reaches parity, bundle the prebuilt legacy UI alongside the new UI; the runtime must not invoke a frontend build or install dependencies. Data and user configuration must live outside immutable release directories.

## Support priorities

- **Primary:** native Linux x86-64 and ARM64. Native operation drives packaging and release design.
- **Secondary:** WSL2 on matching x86-64 and ARM64 hosts, reusing the Linux archives. This is an intended support target, not a compatibility claim before testing. WSL1 and native Windows execution are outside scope.
- Users install WSL2 and a Linux distribution themselves. No host Guix or additional application dependencies should be required inside that distribution.
- Recommend extraction, runtime state and active scientific work in the WSL Linux filesystem (for example `~/metamanifold`), not `/mnt/c/`. Document Windows-filesystem limitations rather than promising equivalent performance or permissions.
- Use the Windows browser for the UI. Verify localhost access in the supported WSL networking configuration; do not expose the server publicly as a workaround.
- Add explicit WSL2 checks for offline extraction/launch, relocatable execution, native tools/RCall, browser connectivity, shutdown/restart and idle update/rollback. ARM64 WSL2 must be tested independently before being advertised as verified.
- Native releases take priority. Clearly publish per-environment validation status and known WSL limitations; secondary support must not be presented as already tested.

## Guix, mise and just responsibilities

- Guix: pinned channels and package recipes, complete runtime closure, architecture-specific build environments and relocatable pack investigation (`guix pack -RR`). Validate actual relocation and execution without host Guix/root or a preexisting /gnu/store; do not assume this works on every Linux host.
- mise: release-engineering version discovery/pins and bundled tool selection. It must not execute `install`/`upgrade` on application startup or independently mutate an installed scientific environment.
- just: reproducible build/test/package/update-check entrypoints, backed by bundled tools in delivered archives.
- Bun: the only JavaScript package manager/runtime/build tool used by this project. Existing Node browser-test commands need conversion and testing through Bun before satisfying this policy.

The current Julia/Guix combination, binary artifacts, RCall, Bioconductor packages, Java-dependent FastQC, Python tools, native libraries and all scientific executables require a packaging audit. A Guix manifest alone is not a complete offline application. Include licenses/notices and required source offers for distributed components.

## Coordinated update policy

Automatically check for releases while online; do not delay launch or fail offline. Discover stable component updates in release engineering, resolve all lockfiles, build and test complete candidates on both architectures, then publish signed metadata plus hashes. Do not use unpinned `latest` versions inside an installed release.

Target the latest mutually compatible stable versions. If the absolute newest versions cannot coexist or scientific regression tests fail, keep the working release and report the held-back components and reasons. No claim that every upstream latest version can always ship simultaneously.

Runtime updater (to implement):
1. Validate signed metadata against bundled trust roots, platform, version, expiry and replay/rollback rules.
2. Download into staging without touching the current release; verify hashes and archive extraction safety.
3. Coordinate through a backend-owned exclusive update/job-submission gate. All jobs and mutations must be idle; no merely client-side idle check.
4. Take a configuration/data-schema-compatible recovery point before migrations. A binary rollback cannot undo arbitrary data migrations.
5. Switch the complete release atomically, restart services, perform health checks, and roll back on failure. Retain the previous working release.
6. On interruption, insufficient disk, invalid signature, offline operation or failure, leave the current installation usable. Provide administrator pause/maintenance controls for future remote hosting.

Reference databases are not silently downloaded or updated. Their versions and checksums belong to scientific provenance, even though their bytes are user supplied.

## Required acceptance gates

- Both architectures boot from complete release archives on clean compatible hosts with networking disabled, no host /gnu/store and no preinstalled application toolchains.
- Start both UI/backend services; load browser assets with external networking blocked.
- Run tool probes and an appropriate synthetic scientific smoke test. Database-dependent tests use explicit external test fixtures, not undeclared runtime downloads.
- Exercise RCall and lazily loaded Julia/native artifacts; no package-manager/network fallback.
- Verify relocation, spaces in paths, writable state separation, unprivileged launch and documented kernel requirements.
- Verify new-job/update race handling, interrupted download, corrupted archive, invalid/expired signature, failed health check and rollback.
- Produce a component/version/license inventory and measured compressed/unpacked sizes. Remove build-only compilers/caches where safe; do not remove scientific capability for size.

## Next implementation work

1. Preserve the published migration baseline while adding packaging (checkout reconciliation completed before this policy publication).
2. Inventory every runtime dependency and lazy-download path; assess Guix recipes and ARM64 support.
3. Pin Guix channels and add package recipes plus build-only mise/just definitions, without inventing unverified version hashes.
4. Build one offline x86-64 closure, then the ARM64 equivalent; prove clean-host execution.
5. Implement authenticated release publication/updater and failure tests.
6. Integrate feature-parity UI migration and publish architecture-specific release artifacts.

The declarative release-policy.toml records decisions only. It does not enforce these guarantees yet.

## Overall project status

See [migration and distribution status](../docs/migration/STATUS.md) for implemented work, remaining scope, acceptance gates and later owner inputs.
