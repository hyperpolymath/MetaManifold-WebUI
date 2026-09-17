<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Migration log: package management to Bun

**Date:** 2026-09-17
**Base commit:** `ecefb1c` (`main`, prior to this change)
**Bun version pinned to:** **1.3.10** (same pin as
`config/defaults/tool_versions.yml` → `toolchain.bun.version`, which CI reads)

## Summary

Prompt 0 (type-system reconnaissance) established that this repository was
**already substantially migrated to Bun** before this task began:

- `frontend/bun.lock` (text lockfile, `lockfileVersion: 1`) was already
  committed and installed reproducibly.
- CI already used `oven-sh/setup-bun@v2` with `bun-version` read from the
  committed pin file, and built the frontend with
  `bun install --frozen-lockfile && bun run build`.
- No npm/deno/yarn/pnpm artefacts existed to remove.

This change therefore **completes** the migration (in-repo version pinning,
`packageManager` declaration, developer-docs alignment, deliverable tracking)
rather than performing it from scratch. Starting state is recorded here so the
diff can be read as intentional, minimal, and complete.

## 1. What was removed and why

After a tree-wide sweep (`find` for each artefact class):

| Artefact | Found? | Action |
|---|---|---|
| `package-lock.json` | No | nothing to remove |
| `deno.lock`, `deno.json`, `deno.jsonc` (import maps) | No | nothing to remove |
| `.npmrc` | No | nothing to remove |
| `yarn.lock`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `.yarnrc*` | No | nothing to remove |
| `npx` / `node` / `npm run` / `deno run|task` in `package.json` scripts | No | nothing to change |
| `https://` imports, `Deno.*` APIs, `npm:` specifiers in source | No | nothing to change (Prompt 0 finding reproduced and re-verified) |
| Node.js / Deno setup steps in CI | None present | nothing to remove |

Nothing was deleted from this repository by this migration.

## 2. What changed and why

| File | Change | Why |
|---|---|---|
| `.bun-version` (new, repo root) | contains `1.3.10` | In-repo version pin so humans, `mise`/`asdf`-style tool managers, and `oven-sh/setup-bun`'s `.bun-version` support all read the same floor. The **authoritative pin remains `config/defaults/tool_versions.yml`** (consumed by CI and `install.jl`); `.bun-version` mirrors it and must not drift ahead of it. |
| `frontend/package.json` | added `"packageManager": "bun@1.3.10"` | Declares the package manager for tools that honour the field (Corepack-style dispatch, IDEs); matches the `.bun-version`/CI pin. No other field changed. |
| `README.md` | Prerequisites now list **Bun >= 1.3.10** and name the pin locations; the "**bun or Node.js** (bun preferred)" phrasing is gone | Task step 6: list Bun with minimum version; drop Node.js as a package-manager alternative. No other README content changed. |
| `.gitignore` | three exception lines: `!docs/migration/`, `!docs/audit/`, `!.bun-version` | Pre-existing rules (`docs/*` keep-out; blanket `.*` dotfile ignore) would have made this log, the Prompt 0 audit deliverable, and the new pin file un-committable. Minimal exceptions only. |

No dependencies were added, removed, or upgraded. No TypeScript configuration,
application source, or CI workflow content was modified (CI needed no changes —
it was already Bun-only; see §5).

### Lockfile format note (`bun.lock` vs `bun.lockb`)

The task deliverable list mentions `bun.lockb`. Bun 1.3.x **generates and
consumes the text `bun.lock` by default**; the binary `bun.lockb` is the legacy
format (Bun still reads it but no longer writes it). The repository correctly
carries `frontend/bun.lock`; no `bun.lockb` was generated, deliberately.

### Lockfile determinism

Three consecutive installs on Bun 1.3.10 — plain `bun install`, a second plain
install, and `bun install --frozen-lockfile` (the CI gate) — all completed and
left `bun.lock` **byte-identical** to the committed version:

```
sha256  dd783de9f76f1e65a242e6b8a59b23de0bde9a66cc1abc6cc5f4e9799df56a74
```

(before and after every run; 533 packages installed fresh, 541 checked on
re-run, "no changes").

## 3. Compatibility shims retained

- **`start.sh` Node fallback.** When `bun` is absent, `start.sh` falls back to
  any pre-existing `frontend/node_modules/.bin/{tsc,vite}` (i.e. a historical
  npm-installed tree) to build the frontend. Retained deliberately: removing it
  would change runtime behaviour for existing developer machines, which is out
  of scope for a no-feature-change migration. It is unreachable when Bun is
  installed and is not used by CI. It also short-circuits to the committed
  `web/dist/` bundle when `BUILD` is unset, so most runs never build at all.
- **`package.json` `overrides`** (`@types/react`, `@types/react-dom`
  self-referential pins) — pre-existing, honoured by Bun, left untouched.
- **Committed `web/dist/`** build output remains tracked (unchanged by this
  migration; a rebuild was not committed — see §4).

## 4. Known issues / verification results

Environment: Linux sandbox, **2 GB RAM**, Bun 1.3.10, Node v20.20.2 present
(used by `vite`'s bin shebang, as on any machine with Node installed).

| Check | Result | Evidence / notes |
|---|---|---|
| `bun install` | **Pass** | clean-tree install 4.64s; deterministic (§2) |
| `bun install --frozen-lockfile` | **Pass** | the CI gate; zero drift |
| `tsc` type gate (first half of `bun run build`) | **Pass** | `tsc --noEmit` exit 0 in ~5.8s |
| `vite build` (second half of `bun run build`) | **Fails in this sandbox — memory only** | Reproducibly identical failure at the final `rendering chunks...` stage after "✓ 1712 modules transformed": default heap → V8 OOM; `--max-old-space-size=1152` → kernel OOM-kill (min. free mem 242 MB); `896`/`1024` caps → V8 heap-limit OOM. Rollup's chunk render for the Plotly/chart-editor bundle needs more than this 2 GB box's ~1.5 GB usable headroom. **Not a Bun incompatibility** — the same command under Bun 1.3.10 is what CI runs on `ubuntu-24.04` runners (16 GB), and `start.sh` normally serves the committed `web/dist/`. On any machine with ≥ ~3 GB free RAM the documented command is unchanged: `bun run build`. Re-running in a bigger environment is recommended before merging. |
| `bun test` | **No tests exist** | `bun test` exits 1 with "No tests found!" — there are no `*.test.*`/`*.spec.*` files under `frontend/`; frontend tests are Prompt 3 scope, not this migration. |
| `bun run dev` | **Pass** | Vite 6.4.1 ready in 195 ms; `GET /` → 200 (554 B), `GET /src/main.tsx` → 200 (module transform works); dev proxies to `127.0.0.1:8080` configured as before. |

One sandbox-preview nit observed during dev-server verification: Vite 6's
host check rejected the ephemeral sandbox proxy hostname (HTTP 403 for that
host only; `localhost`/`127.0.0.1` are unaffected). Not migration-related;
relevant only if MetaManifold's dev server is ever exposed through a dynamic
tunnel hostname, in which case `server.allowedHosts` in `vite.config.ts` would
be the place (left for a future change — config untouched here).

## 5. CI/CD

`.github/workflows/ci.yml` already used `oven-sh/setup-bun@v2` pinned from
`config/defaults/tool_versions.yml` (`BUN_VERSION`, currently 1.3.10) and built
via `bun install --frozen-lockfile && bun run build`. No Node.js or Deno setup
steps existed. **The workflow is unchanged.** No `npm run` references exist in
CI, and none in tracked documentation after the README edit.

## 6. Developer documentation

- `README.md` — prerequisites updated (§2). No `CONTRIBUTING.md` exists
  (Prompt 0 finding; flagged there as an RSR-baseline gap — creating one is not
  migration scope). No `Justfile` exists — nothing to update.
- This log and `docs/audit/type-system-reconnaissance.md` are made committable
  by the `.gitignore` exceptions in §2.

## 7. Bun version pinned to

**1.3.10**, in three coordinated places:

1. `config/defaults/tool_versions.yml` — `toolchain.bun.version` (authoritative;
   consumed by CI and `install.jl`; pre-existing)
2. `.bun-version` (new; repo root)
3. `frontend/package.json` — `packageManager: "bun@1.3.10"` (new)

If the pin is advanced, all three should move together. `test/unit/
test_install_pins.jl` currently cross-checks the Julia/R pins only; extending
it to also cross-check the Bun triad is a candidate follow-up (test change,
out of scope here).
