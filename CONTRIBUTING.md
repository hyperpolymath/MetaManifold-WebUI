<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Contributing

## Where to contribute

- **Application behaviour / bioinformatics** (pipeline, analyses, server
  routes, UI features): propose to **upstream**,
  `JoshuaJewell/MetaManifold-WebUI`.
- **Engineering alignment work** (types, test infrastructure, CI,
  tooling): this fork, `hyperpolymath/MetaManifold-WebUI`.

Pull requests against this fork must use base
`hyperpolymath/MetaManifold-WebUI:main`. GitHub's fork PR page defaults the
base to the upstream parent — change it before clicking *Create*.

## Landing fork work on upstream (low-friction integration)

This fork and upstream (`JoshuaJewell/MetaManifold-WebUI`) share no git
ancestor, so a naive merge conflicts on every shared-but-different file. To
integrate without a wall of conflicts — and to let the maintainer adopt the work
incrementally, from "pure upstream" to "partially transitional" to "everything",
without ever breaking a running system — see:

- **`docs/integration/README.md`** — the guide (profiles, merge hygiene, staging).
- **`docs/integration/conflict-map-2026-09-25.md`** — the measured conflict set.
- **`docs/integration/HANDOFF-granular-reanchor.md`** — the brief to actually land it.
- `just reanchor-plan` / `just reanchor` — replay the fork onto upstream as ~206 granular commits (3 decisions, 0 conflicts).
- `just integrate status | profiles | plan | triage` and `just augment`/`just suspend <component>`.
- `just bootstrap` / `just setup-full` / `just heal` / `just doctor` — the turnkey environment.

## Development setup

```bash
# Frontend (gates run here)
cd frontend
bun install                 # bun 1.3.10 — see .bun-version
bun run typecheck           # tsc semantic gate (0 errors required)
bun test                    # unit + integration batteries (no DOM lane)
bun run bench/              # benchmark harness (informational)
bun run check               # all three in sequence — must be green

# Full application (requires Julia + R/renv per README.adoc § Quick start)
./install.sh                # upstream flow
./start.sh
```

Environment requirements and the clean-clone reproducibility procedure are
in `docs/reproducibility.md`.

## Commit conventions

Conventional commit subjects (enforced locally by the commit-msg hook;
reported in CI as an advisory check, not a merge gate — this fork's work
lands on upstream, which does not require conventional commits):

```
<type>(<optional scope>): <subject>        # ≤ 72 chars
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
`test`, `build`, `ci`, `chore`, `revert`. A template with the full
checklist is in `.gitmessage`:

```bash
just hooks                                 # one-time, enables the commit-msg
                                           # and pre-commit gates
git config commit.template .gitmessage     # one-time, loads the template
```

`just hooks` is already a dependency of `just bootstrap`, so a clone that was
bootstrapped has both gates live. It only sets `core.hooksPath`, which is local
config and therefore cannot be committed — that is why it has to be a command
rather than a file. The hooks are `commit-msg` (conventional-commit subject) and
`pre-commit` (blob hygiene: no uncompressed sequencing data, nothing over 4 MiB).
CI re-checks both, so forgetting to run this costs a red build, not a bad commit
on `main`.

---

<body lines, ≤ 72 chars, WHY before HOW>

---

## Branch naming

```
feat/<short-name>      new capability
fix/<short-name>       defect repair
chore/<short-name>     alignment / tooling / metadata
test/<short-name>      test-only change
docs/<short-name>      documentation-only change
```

Lowercase, hyphenated, one concept per branch. Long-lived topic branches
are rebased onto `main` before PR; merge commits from topic branches are
not used.

## Before opening a PR

1. `bun run check` green (`frontend/`)
2. `scripts/check-spdx.sh`, `scripts/check-format.sh`,
   `scripts/check-lint.sh` green (repo root; these run in CI as
   advisory checks and do not block merge)
3. New source files carry the right `SPDX-License-Identifier` header
   (`NOTICE` explains the authorship rule)
4. Docs touched if behaviour/developer workflow changed
5. No secrets, tokens, `.env`, or sequencing data in the diff

The PR template (`.github/pull_request_template.md`) lists the same gates.

## Licence headers

- Files you create in this fork: `MPL-2.0` for code/config/scripts,
  `CC-BY-SA-4.0` for prose — per `NOTICE` and the estate Licence Policy
  (Rule 3a inside an AGPL work).
- Files that exist upstream keep their upstream licence; do not relicense
  them — annotate with `SPDX-License-Identifier: AGPL-3.0-only` only.
