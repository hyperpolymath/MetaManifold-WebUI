<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Reproducibility — frontend build & checks

Status: verified 2026-09-17 (Europe/London) at the alignment commit.
Application-level (Julia/R/tool) reproducibility is upstream's domain and is
pinned through `Manifest.toml`, `renv.lock`, and
`config/defaults/tool_versions.yml`; this document covers what this fork
controls and verifies: the **frontend toolchain**.

## Pinned environment

| Component | Pin | Where pinned |
|---|---|---|
| Bun | **1.3.10** | `.bun-version` (also read by CI via `bun-version-file`; mirrored from upstream's `tool_versions.yml`) |
| Frontend deps | bun text lockfile | `frontend/bun.lock` (deterministic; **not** `bun.lockb` — this repo pins the text format for reviewability and stable hashing) |
| Node | none required | bun is the entire JS toolchain |
| OS | Linux `x86_64` (Ubuntu 24.04 reference) | verified on Debian-flavoured sandboxes and ubuntu-24.04 CI |
| TypeScript | per lockfile (devDependency) | `tsc --noEmit` must run the locked version; ethics of the gate depend on it |

## Clean-clone verification (empirical)

At the alignment commit, from a clean clone of this repository:

```bash
cd frontend
bun install        # installs exactly the lockfile's graph
sha256sum bun.lock # unchanged by the install
bun run typecheck  # 0 errors
bun test           # 67 pass / 5 todo / 0 fail (DOM-free lanes)
bun run bench/     # medians against bench/baseline.json, informational
```

Measured results: `bun.lock` sha256 **identical before and after install**
(`dd783de9…56a74` at measurement time); typecheck, tests, and benchmark all
pass on the clean tree. `bun install --frozen-lockfile` (the CI form)
additionally *refuses* to alter the lockfile.

## Known environment caveat — `vite build`

`bun run build` (vite bundling the Plotly bundle) requires roughly **2.5–3 GB
of free memory**. In this 2 GB verification sandbox the build OOMs; the
run is authoritative in **CI** (`ubuntu-24.04`, 7 GB), which runs the same
command after typecheck/tests/bench, every push. This is a documented
sandbox limitation, not a toolchain failure
(`docs/testing/infrastructure.md`).

## Drift rules

1. Bun bumps happen by editing `.bun-version`, regenerating
   `frontend/bun.lock` under the new bun, and committing both together.
   `bun x tsc` on a machine *without* `node_modules` will fetch the latest
   TypeScript instead of the locked one — always `bun install` first (CI
   does; `scripts/check-lint.sh` assumes it).
2. Lockfile changes outside an intended dependency change are drift: diff
   `frontend/bun.lock` against `main`.
3. CI versions come from the same files (`tool_versions.yml` mirror and
   `.bun-version`), so machines and CI cannot silently diverge.
