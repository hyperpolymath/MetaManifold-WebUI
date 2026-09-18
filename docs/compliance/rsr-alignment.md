<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# RSR template alignment — checklist

Status: compliant-with-documented-deviations, 2026-09-17 (alignment commit).
Reference: `rsr-template-repo@main` as cloned in the verification sandbox.

## Files

| rsr-template artifact | MetaManifold-WebUI | Status / rationale |
|---|---|---|
| `LICENSE` | `LICENSE` (AGPL-3.0, upstream) | ✅ present — MPL in template, but upstream's AGPL work licence is untouchable (fork rule) |
| `LICENSES/{MPL-2.0,CC-BY-SA-4.0}.txt` | `LICENSES/` | ✅ copied verbatim |
| `CITATION.cff` | `CITATION.cff` | ✅ **already present and fully populated upstream** (ORCID, references) — no change needed |
| `NOTICE` | `NOTICE` | ✅ created (licence split + third-party orchestration notice) |
| `.github/SECURITY.md` | `SECURITY.md` | ✅ created at root (GitHub resolves both locations); real URLs and honest targets |
| `.github/CODE_OF_CONDUCT.md` | `CODE_OF_CONDUCT.md` | ✅ Contributor Covenant 2.1, root |
| `CHANGELOG.adoc` | `CHANGELOG.md` | ✅ created — **.md deviation**: repo prose convention is Markdown (upstream README, docs/*, rsr `.github/*` files); type-system entries added per spec |
| `CONTRIBUTING.adoc` | `CONTRIBUTING.md` | ✅ created (.md deviation, same rationale) |
| `.github/pull_request_template.md` | same path | ✅ created, adapted to bun/frontend gates (Rust/ABI-specific items dropped as not applicable) |
| `.github/ISSUE_TEMPLATE/{config,bug_report,feature_request}.yml` | same paths | ✅ created, adapted (upstream-redirect contact link added; scope dropdown → fork/upstream destination) |
| `.github/dependabot.yml` | same path | ✅ created, scoped to real ecosystems (github-actions + bun/frontend) |
| `.github/CODEOWNERS` | same path | ✅ created (`@hyperpolymath`) |
| `.editorconfig` | `.editorconfig` | ✅ canonical copy, byte-identical |
| `.gitattributes` | `.gitattributes` | ✅ canonical copy, byte-identical |
| `.gitmessage` | `.gitmessage` | ✅ canonical copy, byte-identical |
| `Justfile` | ✅ | **present** (41 recipes; reinstated from this deviation on user instruction). Thin wrappers only — every recipe delegates to the canonical entry points (`frontend/package.json` scripts, `scripts/check-*.sh`, the estate launcher, the Julia project), so no logic is duplicated. Mirrors the rsr doctrine of fail-loud lanes (e.g. `test-e2e` without browsers, Julia lanes without Julia) |
| `mise.toml` | ✅ | **present** — exact CI-pinned binaries (julia 1.12.5, bun 1.3.10, node 20.20.2, just 1.43.1); every registry name verified per the header doctrine of the template's own mise.toml; R is a verified-as-absent documented exception (system R + renv.lock) |
| `guix.scm` (+ `channels.scm`) | ✅ | **present** — time-machine-pinned dev shell (guix master 2026-09-18); honest gaps documented in the file header (channel-version drift vs exact CI pins → use mise for parity; bun not packaged by Guix → pinned upstream installer) |
| `.envrc` | ✅ | **present** — direnv activates mise first / Guix fallback; exports `METAMANIFOLD_REPO_DIR` |
| `mise.toml` / `.tool-versions` | `.bun-version` | ❌/✅ toolchain pinning is upstream's `tool_versions.yml` + `.bun-version`; adding a second pin = drift source |
| `README.adoc` | `README.md` | ➖ upstream's, Markdown; refreshed, not converted |
| Agent-context files (`CLAUDE.md`, `.cursorrules`, `GEMINI.md`, …) | — | ❌ intentionally absent — fork carries no agent-instruction surface; estate canon lives in `standards` |
| `.gitleaksignore`, `.hypatia-ignore`, `.envrc`, `guix.scm`, `sonar-*`, `validation/` etc. | — | ❌ not applicable to this repo's lanes |

## SPDX headers

All 198 covered source files (ts/tsx/jl/R/sh/yml/yaml/md) carry
`SPDX-License-Identifier`, verified by `scripts/check-spdx.sh` (CI gate).
Exclusions (machine metadata / generated): JSON, TOML, lockfiles,
`CITATION.cff`, `*.a2ml` manifests, dotfile data (`.gitignore`,
`.bun-version`), `LICENSE*` texts, CSS/HTML, `web/*` artefacts. The
template asks MPL-2.0/CC-BY-SA-4.0 outright; this fork implements it via
the estate **LICENCE-POLICY**: upstream-authored = `AGPL-3.0-only`
(inherited work licence — fork licensing untouched), fork-authored =
`MPL-2.0`/`CC-BY-SA-4.0` (Rule 3a). Documented in `NOTICE`.

## Directory shape

`src/` (Julia app), `frontend/` (TS app + tests/bench), `test/` (Julia),
`bench/`, `docs/`, `scripts/`, `config/`, `.github/`, `LICENSES/` — shape
matches the template's intent; template-specific dirs (`examples/`,
`features/`, `verification/`, `www/`) have no counterpart need here.
