<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Reproducibility — toolchain, build & checks

Status: verified 2026-09-18 (Europe/London) at the prompt-8 commit.
This document is the single source of truth for **what must be installed**
to work on this repository. The *how* is two lanes, either of which makes a
bare machine standalone:

1. **mise** (`mise.toml`) — exact upstream binaries, pinned to CI versions.
   Primary lane; verified in this sandbox on 2026-09-18.
2. **Guix** (`guix.scm` + `channels.scm`) — reproducible GNU package set
   pinned by commit. Peer lane; manifests verified statically + live against
   the pinned guix commit (see evidence below); full `guix shell`
   recreation runs on hosts/CI, not in this 2 GB sandbox.

Application-level data/package reproducibility remains pinned through
`Manifest.toml`, `frontend/bun.lock`, and `renv.lock`; `.envrc` activates
either lane automatically via direnv.

## Toolchain pin table (single source of truth)

| Component | Pin | Pinned where | Verified |
|---|---|---|---|
| Julia | **1.12.5** (exact) | `mise.toml` + CI matrix | `mise install` → `julia version 1.12.5` |
| Bun | **1.3.10** (exact) | `.bun-version` (CI reads the same file) + `mise.toml` | `mise x -- bun --version` → `1.3.10` |
| Node | **20.20.2** (LTS) | `mise.toml` | `mise x -- node --version` → `v20.20.2` |
| just | **1.43.1** | `mise.toml` | `mise x -- just --version` → `just 1.43.1` |
| R | **system ≥ 4.5** — documented exception | renv lane restores packages from `renv.lock` | R is **not in the mise registry** (verified `mise registry r` + `mise ls-remote r` 2026-09-18); CI also uses a host R. |
| Frontend deps | bun text lockfile | `frontend/bun.lock` | sha256-identity checked 2026-09-17 (`dd783de9…56a74`) |
| Julia deps | `Project.toml` + `Manifest.toml` | repo root | `just julia-instantiate` |
| OS | Linux `x86_64` (Ubuntu 24.04 reference) | CI | — |

## Bare-machine bootstrap

```bash
# lane 1 (primary): exact binaries
curl https://mise.run | sh
just bootstrap     # = setup-tools (mise install) + frontend/bun install

# lane 2 (Guix):
guix time-machine -C channels.scm -- shell -D -f guix.scm

# either way, the proof gate is the same:
just ci            # spdx + format + lint + tsc + 577 tests + bench checksums
```

## Verification evidence (2026-09-18, this sandbox)

- `mise install` provisioned all four pinned tools from a cold cache in
  14.3 s; every registry name was checked against `mise registry` AND
  `mise ls-remote` before being written (estate doctrine; `r` failed the
  check and became the documented system-R exception above).
- From a **naked environment** (`env -i`, no shell init, only the `mise`
  binary on PATH): `mise x -- just ci` → **ALL GATES GREEN** (spdx,
  format, lint, `tsc --noEmit`, 577 pass / 5 todo / 0 fail / 3343
  assertions, bench checksums verified). Nothing was sourced from the
  shell profile, `~/.bun`, or system toolchains — the manifests alone
  stood the environment up.
- **Defect found by that clean-env run and fixed**: under the pinned bun
  1.3.10, `bun x tsc --noEmit` resolved the *registry* `tsc` wrapper
  package (which currently delivers TypeScript 7.0.2), producing
  red-herring errors such as "Option 'baseUrl' has been removed" against
  the project's tsconfig. `scripts/check-lint.sh` now executes the
  project's own compiler (`frontend/node_modules/.bin/tsc`,
  lockfile-owned), with `bun run typecheck` as the fallback. This is a
  hard compatibility discovery about the pinned toolchain, recorded here
  and in the commit, not silently worked around.
- Guix lane: the pinned commit `0daef659a232…` (guix master 2026-09-18)
  was fetched live; `(gnu packages rust-apps)` at that commit contains
  `just 1.43.0` (sighted in source). The remaining inputs
  (`julia`/`r`/`node-lts`) come from long-stable canonical modules;
  package-set recreation runs on hosts/CI. Two honest gaps stay in
  `guix.scm`'s header: package versions follow the channel pin (so guix's
  julia/just may differ from the exact CI pins — the mise lane exists for
  parity), and bun is not packaged by Guix, so the guix shell bootstraps
  bun via the pinned upstream installer (`bun-v1.3.10`).

## Frontend environment (unchanged from prompt-6 verification)

`vite build` (production bundle) needs ~2.5–3 GB and is sandbox-OOM here;
CI is the build authority (7 GB runner), running the same command after
typecheck/tests/bench. `bun.lock` is the text format on purpose
(reviewable, stable hashing); `--frozen-lockfile` refuses edits.

## Drift rules

1. Tool bumps: edit the pin in `mise.toml` (and `.bun-version` for bun),
   then run `mise install` + `just ci`. CI reads the same files, so
   machines and CI cannot silently diverge.
2. Never let a check fetch a tool: gates must use lockfile/manifest-owned
   binaries (see the `bun x tsc` defect above). If a gate needs a binary,
   it comes from `node_modules/.bin`, the mise shim, or the guix profile —
   never from a package-registry fallback inside the gate.
3. Lockfile changes outside an intended dependency change are drift: diff
   `frontend/bun.lock`, `Manifest.toml`, and `renv.lock` against `main`.
4. The channels pin (`channels.scm`) moves deliberately: fetch the new
   master sha, update the file, verify `guix.scm`'s inputs still exist at
   that commit, note the bump in the commit message.
