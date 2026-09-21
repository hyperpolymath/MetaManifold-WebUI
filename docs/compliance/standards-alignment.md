<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Standards repo alignment — checklist

Status: compliant-with-documented-deviations, 2026-09-17.
Reference: `hyperpolymath/standards@main` (in particular
`LICENCE-POLICY.adoc`, `CONTRIBUTING.adoc`, `LANGUAGE-POLICY.adoc`).

## Licence policy (LICENCE-POLICY.adoc)

| Rule | Application here | Status |
|---|---|---|
| Rule 1 (MPL-2.0 code / CC-BY-SA-4.0 prose) | Applied to all **fork-authored** files | ✅ 198-file identifier sweep, CI-gated |
| Rule 3 (co-developed shared work = AGPL-3.0) | This repository **is** the shared work — upstream files stay `AGPL-3.0-only`, headers verbatim | ✅ documented in `NOTICE` |
| Rule 3a (owner-only components stay MPL-2.0 inside an AGPL work) | Test infrastructure, type estate, compliance tooling authored in this fork = MPL-2.0/CC-BY-SA-4.0 | ✅ |
| Five-rule register drift | Authorship classification is mechanical (first-commit author), stated in `NOTICE`; no PMPL anywhere | ✅ |

## Lint

| Standards expectation | Here | Status |
|---|---|---|
| Language-native semantic gates | `scripts/check-lint.sh`: `tsc --noEmit` (strict + exactOptional…), `bash -n` on all `*.sh`, advisory `shellcheck` | ✅ CI step |
| Estate lint dialect for TypeScript | None defined — **TypeScript is fork-exempt** under LANGUAGE-POLICY (banned estate-wide, forks exempt); the strict compiler is declared the lint dialect | ✅ documented deviation |

## Formatting

| Expectation | Here | Status |
|---|---|---|
| Canonical `.editorconfig` / `.gitattributes` | Byte-identical copies | ✅ |
| Conformance gate | `scripts/check-format.sh` (LF, trailing-ws with prose exemption, final newline, tab-indent in TS) | ✅ CI step; three upstream nits fixed (`databases.jl`, `merge_taxa.jl`, `renv/activate.R`) |

## Toolchain manifests (self-contained repo)

| Expectation | Here | Status |
|---|---|---|
| `mise.toml` toolchain manifest, pinned to CI versions, every name verified against the registry (estate doctrine from rsr-template) | `mise.toml` — julia 1.12.5 / bun 1.3.10 / node 20.20.2 / just 1.43.1, all confirmed resolvable 2026-09-18; R absent from registry → documented system exception | ✅ |
| Guix development environment (`guix.scm`, per estate REQUIRED-FILES) | `guix.scm` (dev-shell inputs: julia, r, node-lts, just, git + pipeline-tool equivalents cutadapt/multiqc/fastqc/vsearch/cd-hit; swarm documented as download-lane-only) + `channels.scm` time-machine pin (guix master 2026-09-18; `just` input sighted live at the pinned commit) | ✅ recreation on hosts/CI |
| Pipeline tools byte-exact | `config/defaults/tool_versions.yml` (version + URL + sha256-of-archive per tool) fetched by `install.sh`; preflight asserts against it | ✅ upstream-designed, fork-verified |
| Pin single-sourcing (codegen, minimal duplication) | `.bun-version` is generated from `mise.toml` by `just sync-pins`; overlap copies (`tool_versions.yml`, the `ci.yml` setup-julia step) are drift-checked, not generated | ✅ `coupling-toolchain-pins` test gates it |
| direnv auto-activation (`.envrc`) | `.envrc` — mise lane first, Guix fallback, `METAMANIFOLD_REPO_DIR` export | ✅ |
| Single command to stand up a bare machine | `curl https://mise.run \| sh && just bootstrap` (or the time-machine one-liner) → `just ci` green from a naked env (evidence logged in `docs/reproducibility.md`) | ✅ verified 2026-09-18 |

## Commit conventions

| Expectation | Here | Status |
|---|---|---|
| Documented | `CONTRIBUTING.md` + `.gitmessage` template (`git config commit.template .gitmessage`) | ✅ |
| Enforced (the gate) | CI repo-hygiene `Commit convention check` — binding on this repo, advisory only under upstream (`continue-on-error: github.repository != 'hyperpolymath/MetaManifold-WebUI'`) | ✅ |
| Enforced (local pre-flight) | `.githooks/commit-msg`, enabled by `just hooks` (a `just bootstrap` dependency) | ⚠ opt-in per clone — `core.hooksPath` is local config and cannot be committed |
| Type list | `feat fix docs style refactor perf test build ci chore revert` | ✅ canonical list |

## History hygiene

| Expectation | Here | Status |
|---|---|---|
| Large/dead blobs kept out | `scripts/check-blob-hygiene.sh` — one implementation, two callers: `.githooks/pre-commit` (local) and the CI repo-hygiene `Blob hygiene check` (binding on this repo). Primary rule is a 4 MiB size ceiling, not a path list; the six `data/MiSeq_SOP/run_[AB]/*.fastq.gz` fixtures are allowlisted | ✅ verified by mutant **2026-09-21** — five reintroduction attempts refused, two legitimate files admitted. ⚠ a one-off manual battery, not an enforced control: the date is here so this cell cannot read as ongoing status. Re-run `scripts/check-blob-hygiene.sh` against fresh mutants after any change to its rules |
| Diff/linguist markings | `.gitattributes` marks `*.fastq{,.gz}`, `*.fq{,.gz}`, `*.fasta`, `*.fa`, `*.sam`, `*.bam` binary `-diff linguist-generated=true` | ✅ hygiene only, not the gate |

## Branch conventions

Documented in `CONTRIBUTING.md`: `feat/… fix/… chore/… test/… docs/…`,
lower-hyphenated, single-concept, rebase-before-PR. ✅

## PR conventions

`.github/pull_request_template.md` (RSR-adapted; base-ownership checklist
item guarding against the GitHub fork-PR default to the upstream parent). ✅

## Security/support/governance surfaces

`SECURITY.md` (root), issue forms with a private-advisory contact link,
`CODE_OF_CONDUCT.md` (Contributor Covenant 2.1). GOVERNANCE.md and
SUPPORT.md are **not** added: a two-party fork adds ceremony without
content; decision revisited if the contributor base grows. Documented
absence, not an oversight.

## Prose format deviation

Standards docs are authored in `.adoc`; this repository's prose stays
`.md` to match upstream's documentation convention (upstream README,
`docs/*`, and this fork's own docs from the engineering series are
Markdown). The policy binding is licence/SPDX discipline, not markup
format; the deviation is recorded here rather than converted.
