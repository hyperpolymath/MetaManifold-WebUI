# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Justfile — MetaManifold-WebUI task runner.
#
# Design doctrine (rsr-template / standards estate):
#   - Every recipe either works or FAILS LOUDLY. A check that cannot
#     fail is not a check; a lane that cannot run in this environment
#     exits non-zero with an actionable message, never a vacuous pass.
#   - Recipes are thin wrappers over the canonical entry points:
#     frontend/package.json scripts, scripts/check-*.sh, the estate
#     launcher, and the Julia project. No duplicated logic lives here.
#   - `just` with no arguments lists the available recipes.
#
# Quick start: `just setup` once, then `just ci` before every push.

set shell := ["bash", "-uc"]
set positional-arguments

# ----------------------------------------------------------------------- #
# Configuration
# ----------------------------------------------------------------------- #

# Julia command. The repo-standard lane is mise (pins 1.12.5 exactly behind
# plain `julia`). juliaup users override: JULIA_CMD="julia +1.12.5".
# CI pins 1.12.5 (see .github/workflows/ci.yml).
export JULIA_CMD := env_var_or_default("JULIA_CMD", "julia")

# Estate launcher (standards repo). Override with METAMANIFOLD_LAUNCHER.
LAUNCHER := env_var_or_default("METAMANIFOLD_LAUNCHER", justfile_directory() / "../standards/launcher/metamanifold-webui-launcher.sh")

export METAMANIFOLD_REPO_DIR := justfile_directory()

FRONTEND := justfile_directory() / "frontend"

# Integration helper (fork↔upstream profiles, triage, component toggles).
INTEGRATE := justfile_directory() / "scripts/integrate.sh"

# Re-anchor helper (turn the divergent histories into a granular, mergeable one).
REANCHOR := justfile_directory() / "scripts/reanchor.sh"

# Free-RAM floor (KB) for the heavy Julia lanes: cold JIT-compilation of the
# server dependency closure needs several GB; below this the lane fails
# loudly instead of thrashing the box into an OOM kill.
JULIA_MIN_AVAIL_KB := "2500000"

# ----------------------------------------------------------------------- #
# Default / orientation
# ----------------------------------------------------------------------- #

# List all recipes (default action).
[private]
default:
    @just --list --unsorted

# Show help for one recipe, or the whole list.
help recipe="":
    #!/usr/bin/env bash
    if [[ -z "{{recipe}}" ]]; then
        echo "MetaManifold-WebUI Justfile — entries: setup, dev, test*,"
        echo "bench*, hygiene (spdx/format/lint), ci, start/stop/status."
        echo "Run 'just help <recipe>' for a recipe's doc comment & body."
        echo
        just --list --unsorted
    else
        just --show "{{recipe}}"
    fi

# Report tool versions (never fails; reports ABSENT for missing tools).
info:
    #!/usr/bin/env bash
    line() { printf '%-12s %s\n' "$1:" "$2"; }
    line "just"    "$(just --version)"
    line "bun"     "$(command -v bun >/dev/null 2>&1 && bun --version || echo ABSENT)"
    line "node"    "$(command -v node >/dev/null 2>&1 && node --version || echo ABSENT)"
    line "julia"   "$({ $JULIA_CMD --version; } 2>/dev/null || echo "ABSENT (or missing 1.12.5 channel)")"
    line "R"       "$(command -v R >/dev/null 2>&1 && R --version | head -1 || echo ABSENT)"
    line "git"     "$(git --version)"
    line "head"    "$(git rev-parse --short HEAD) on $(git branch --show-current)"
    line "dirty"   "$(git status --porcelain | wc -l) files"

# Environment health report; exit 1 if an essential tool is missing.
doctor:
    #!/usr/bin/env bash
    rc=0
    # Hard requirement: absent => FAIL and non-zero exit.
    need() {
        if command -v "$1" >/dev/null 2>&1; then printf 'PASS  %-12s %s\n' "$1" "$($1 --version 2>&1 | head -1)";
        else printf 'FAIL  %-12s %s\n' "$1" "$2"; rc=1; fi
    }
    # Soft requirement: absent => WARN, exit stays 0 (a documented lane is just unavailable).
    soft() {
        if command -v "$1" >/dev/null 2>&1; then printf 'PASS  %-12s %s\n' "$1" "$($1 --version 2>&1 | head -1)";
        else printf 'WARN  %-12s %s\n' "$1" "$2"; fi
    }
    need bun  "install: curl -fsSL https://bun.sh/install | bash  (or: just setup-tools)"
    need git  "install via package manager"
    soft bunx "ships with bun; if absent reinstall bun"
    soft node "needed by vite's production build: just setup-tools"
    soft mise "toolchain pins (mise.toml): curl https://mise.run | sh  (Guix lane is the alternative)"
    if $JULIA_CMD --version >/dev/null 2>&1; then
        printf 'PASS  %-12s %s\n' "julia" "$($JULIA_CMD --version)"
    else
        printf 'WARN  %-12s %s\n' "julia" "Julia lanes unavailable — install via juliaup (install.sh) or just setup-tools"
    fi
    if command -v Rscript >/dev/null 2>&1; then
        printf 'PASS  %-12s %s\n' "R" "$(Rscript --version 2>&1 | head -1)"
        [ -f renv/activate.R ] && echo "PASS  renv        renv/activate.R present (restore with: just renv-restore)" \
            || echo "WARN  renv        renv/activate.R missing — R lane cannot restore"
    else
        printf 'WARN  %-12s %s\n' "R" "system R >= 4.5 not found (documented exception; not in mise registry)"
    fi
    # Merge drivers make lockfiles auto-resolve on the next fork↔upstream merge.
    if git config --get merge.lockfile.driver >/dev/null 2>&1; then
        echo "PASS  merge-drv   merge.lockfile wired (just merge-drivers)"
    else
        echo "WARN  merge-drv   not wired — run: just merge-drivers"
    fi
    [[ -x "{{LAUNCHER}}" ]] && echo "PASS  launcher    {{LAUNCHER}}" || { echo "WARN  launcher    not executable: {{LAUNCHER}}"; }
    echo "-----"
    echo "Integration profile: $({{INTEGRATE}} profile 2>/dev/null || echo base)"
    exit $rc

# Quick repo statistics.
stats:
    #!/usr/bin/env bash
    printf 'tracked files : %s\n' "$(git ls-files | wc -l)"
    printf 'TypeScript    : %s\n' "$(git ls-files '*.ts' '*.tsx' | wc -l)"
    printf 'Julia         : %s\n' "$(git ls-files '*.jl' | wc -l)"
    printf 'unit tests    : %s\n' "$(git ls-files 'frontend/tests/unit/*.test.ts' | wc -l)"
    printf 'test asserts  : %s\n' "$(grep -roh 'expect(\|assert' frontend/tests --include='*.ts' | wc -l)"
    printf 'FIXME/TODO    : %s\n' "$(git grep -oh 'FIXME(types)\|TODO(tests)' -- '*.ts' '*.tsx' 2>/dev/null | wc -l)"

# ----------------------------------------------------------------------- #
# Setup
# ----------------------------------------------------------------------- #

# One-time setup: install frontend dependencies.
setup: install

# One-time setup on a BARE machine: provision the pinned toolchain from
# mise.toml (julia 1.12.5, bun 1.3.10, node 20.20.2, just 1.43.1), then
# install frontend dependencies. R is a documented exception: system R +
# renv.lock (R is not in the mise registry — verified 2026-09-18).
bootstrap: setup-tools install codegen-tools hooks merge-drivers
    @echo "bootstrap: toolchain + deps + hooks + merge drivers + machine tool map ready — next: just ci"

# Point git at .githooks so the commit-msg gate actually runs. core.hooksPath is
# per-clone local config -- it cannot be committed -- so documenting it in
# CONTRIBUTING.md left it unset in every clone that did not read that line.
# Wiring it here makes the enablement a consequence of bootstrapping rather than
# of remembering. Idempotent; safe to re-run.
hooks:
    @git config core.hooksPath .githooks
    @echo "hooks: core.hooksPath -> .githooks (commit-msg gate live)"

# Wire a git merge driver that keeps lockfiles / generated files out of the
# fork↔upstream conflict set. merge.lockfile auto-resolves such a path to the
# branch being merged INTO (ours) and reminds you to regenerate — never a
# line-merged lockfile. Applied via .git/info/attributes (local, overrides the
# tree, never committed) so it is fully opt-in and cannot break a merge on a
# clone that has not run it. The committed .gitattributes already stops git from
# line-merging these (merge: unset); this just makes the choice automatic.
# Local git config, like core.hooksPath — hence a command, not a committed file.
# Idempotent; safe to re-run.
merge-drivers:
    #!/usr/bin/env bash
    git config merge.lockfile.name "keep target-branch lockfile, then regenerate (just heal)"
    git config merge.lockfile.driver 'echo "merge-drivers: kept target-branch copy of %P — regenerate with: just heal" >&2'
    attrs="{{justfile_directory()}}/.git/info/attributes"
    mkdir -p "$(dirname "$attrs")"; touch "$attrs"
    for p in Manifest.toml renv.lock frontend/bun.lock bun.lockb package-lock.json pnpm-lock.yaml renv/activate.R; do
        grep -qxF "$p merge=lockfile" "$attrs" 2>/dev/null || printf '%s merge=lockfile\n' "$p" >> "$attrs"
    done
    echo "merge-drivers: merge.lockfile wired for lockfiles via .git/info/attributes (opt-in, local)"

# Provision the pinned toolchain via mise (fail-loud with the installer
# one-liner when mise is absent; the Guix lane in guix.scm is the
# alternative, see docs/reproducibility.md).
setup-tools:
    #!/usr/bin/env bash
    if ! command -v mise >/dev/null 2>&1; then
        echo "MISE UNAVAILABLE: install with: curl https://mise.run | sh" >&2
        echo "(or use the Guix lane: guix time-machine -C channels.scm -- shell -D -f guix.scm)" >&2
        exit 1
    fi
    mise install
    mise ls

# Install frontend dependencies (bun).
install:
    cd frontend && bun install

# CODEGEN: regenerate generated pin artefacts from their source of truth.
# .bun-version is generated FROM mise.toml (CI consumes it via
# bun-version-file); config/defaults/tool_versions.yml is upstream-owned and
# only cross-CHECKED (by the coupling-toolchain-pins drift test), never
# written by this lane. Idempotent; safe to run any time.
sync-pins:
    #!/usr/bin/env bash
    bunver=$(grep -E '^bun\s*=' mise.toml | sed -E 's/^bun\s*=\s*"([^"]+)".*/\1/')
    [[ -n "$bunver" ]] || { echo "sync-pins: no bun pin in mise.toml" >&2; exit 1; }
    printf '%s\n' "$bunver" > .bun-version
    echo "sync-pins: .bun-version <- mise.toml (bun $bunver)"

# Pin-web drift check (coupling category): mise.toml == .bun-version ==
# tool_versions.yml == CI matrix. Run standalone or via the bun suite.
drift:
    cd frontend && bun test tests/unit/coupling-toolchain-pins.test.ts

# CODEGEN: machine tool-path map. config/tools.yml is gitignored
# (machine-specific); this writes it so a fresh clone is runnable with zero
# manual config — PATH-found tools (inside guix/managed envs) become bare
# names, everything else falls back to install.sh's sha256-pinned download
# lane. Version authority stays with the pipeline preflight.
codegen-tools:
    ./scripts/gen-tools-yml.sh

# Complete first-run on a bare machine, clone-to-launchable in one recipe:
# toolchain + JS deps + machine tool map + hooks + merge drivers (bootstrap),
# Julia package instantiate, R package restore (renv), then install.sh's
# sha256-pinned external pipeline tools. After this: just start.
# (install-tools downloads several hundred MB by design — skip it when you only
# develop the frontend.)
setup-full: bootstrap julia-instantiate renv-restore install-tools
    @echo "setup-full: complete — launch with: just start"

# Pipeline tools via the byte-exact lane: install.sh fetches the archives
# recorded in config/defaults/tool_versions.yml (sha256-verified per tool).
install-tools:
    bash install.sh

# All codegen lanes (repo pins + machine tool map).
codegen: sync-pins codegen-tools
    @echo "codegen: pins synced, machine tool map written"

# Report outdated frontend packages (informational only).
outdated:
    cd frontend && bun outdated || true

# Instantiate the Julia project (downloads + precompiles; heavy first run).
julia-instantiate:
    $JULIA_CMD --project=. -e 'using Pkg; Pkg.instantiate(); println("instantiate OK")'

# Restore the R package set from renv.lock (byte-exact; the R lane). Requires
# system R >= 4.5 (documented exception — R is not in the mise registry). Fails
# loudly if R is absent rather than silently skipping the lane.
renv-restore:
    #!/usr/bin/env bash
    if ! command -v Rscript >/dev/null 2>&1; then
        echo "R LANE UNAVAILABLE: system R (>= 4.5) not found." >&2
        echo "Install R for your OS, then re-run: just renv-restore" >&2
        exit 1
    fi
    Rscript --no-init-file -e 'if (!requireNamespace("renv", quietly=TRUE)) { message("installing renv..."); install.packages("renv", repos="https://cloud.r-project.org") }; renv::restore(prompt=FALSE)'

# ----------------------------------------------------------------------- #
# Hygiene gates (scripts/check-*.sh — the canonical bash lanes)
# ----------------------------------------------------------------------- #

# SPDX licence-header gate.
spdx:
    ./scripts/check-spdx.sh

# Whitespace / final-newline format gate.
format:
    ./scripts/check-format.sh

# ESLint over the typed surface.
lint:
    ./scripts/check-lint.sh

# All hygiene gates together.
hygiene: spdx format lint
    @echo "hygiene: OK"

# Agda proof gate (docs/formal/verification-plan.md): guard, type-check,
# negative controls. Honours AGDA=... and AGDA_STDLIB_LIB=... overrides.
proofs:
    ./scripts/check-proofs.sh

# Lint a commit message against the canonical format (default: HEAD).
commit-check msg="":
    #!/usr/bin/env bash
    f=$(mktemp)
    if [[ -n "{{msg}}" ]]; then printf '%s\n' "{{msg}}" > "$f"; else git log -1 --pretty=%B > "$f"; fi
    ./.githooks/commit-msg "$f"; rc=$?
    rm -f "$f"; exit $rc

# Count tracked annotations (informational; see docs/compliance/fixme-index.md).
todo:
    @git grep -oh 'FIXME(types)\|TODO(tests)\|\[VERIFY\]' -- '*.ts' '*.tsx' '*.jl' 2>/dev/null | wc -l

# ----------------------------------------------------------------------- #
# TypeScript: build, types, tests
# ----------------------------------------------------------------------- #

# Static typecheck (also THE type-level test lane; .type-test.ts files).
typecheck:
    cd frontend && bun run typecheck

# Alias with the estate name: type-safe category = tsc over .type-test.ts.
test-types: typecheck

# Full bun test suite (unit + integration).
test:
    cd frontend && bun test

# Unit category only.
test-unit:
    cd frontend && bun test tests/unit

# Integration (process-to-process boundary) tests.
test-integration:
    cd frontend && bun test tests/integration

# Test coverage report (informational — no gates, by policy).
coverage:
    cd frontend && bun test --coverage

# End-to-end lane (Playwright). Fails loudly if browsers are missing.
test-e2e:
    #!/usr/bin/env bash
    cd frontend
    if ! bunx playwright --version >/dev/null 2>&1 || ! ls ~/.cache/ms-playwright 2>/dev/null | grep -q chromium; then
        echo "E2E LANE UNAVAILABLE: Playwright chromium not installed." >&2
        echo "Install with: cd frontend && bunx playwright install --with-deps chromium" >&2
        exit 1
    fi
    bunx playwright test

# Julia test suite (test/runtests.jl). Fails loudly without Julia; fails
# honestly when the environment cannot fit a cold JIT compile.
julia-test:
    #!/usr/bin/env bash
    if ! timeout 15 $JULIA_CMD --version >/dev/null 2>&1; then
        echo "JULIA LANE UNAVAILABLE: '$JULIA_CMD' not usable." >&2
        echo "Install via juliaup, then: just julia-instantiate" >&2
        exit 1
    fi
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    if [[ $avail -lt {{JULIA_MIN_AVAIL_KB}} ]]; then
        echo "JULIA LANE ENVIRONMENT-BLOCKED: cold compile needs ~2.5 GB free RAM (avail: $((avail/1024)) MB)." >&2
        echo "Run on a CI/dev machine: $JULIA_CMD --project=. -e 'using Pkg; Pkg.test()'" >&2
        exit 1
    fi
    $JULIA_CMD --project=. -e 'using Pkg; Pkg.test()'

# ----------------------------------------------------------------------- #
# Benchmarks (informational; checksums are hard gates, timing is not)
# ----------------------------------------------------------------------- #

# Frontend microbenchmarks vs committed baseline (checksum-verified).
bench:
    cd frontend && bun run bench

# Julia FFI-soak / MockRecovery benchmark lane (heavy; needs instantiate).
bench-julia data="":
    #!/usr/bin/env bash
    if ! timeout 15 $JULIA_CMD --version >/dev/null 2>&1; then
        echo "JULIA BENCH UNAVAILABLE: '$JULIA_CMD' not usable." >&2
        echo "Install via juliaup, then: just julia-instantiate" >&2
        exit 1
    fi
    avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    if [[ $avail -lt {{JULIA_MIN_AVAIL_KB}} ]]; then
        echo "JULIA BENCH ENVIRONMENT-BLOCKED: cold compile needs ~2.5 GB free RAM (avail: $((avail/1024)) MB)." >&2
        exit 1
    fi
    $JULIA_CMD --project=. -t4 bench/layer1_mock_recovery/runner.jl {{data}}

# ----------------------------------------------------------------------- #
# Composites
# ----------------------------------------------------------------------- #

# The pre-push composite: types + tests + bench (mirrors package.json).
check:
    cd frontend && bun run check

# Every green gate, in CI order. This is the 'am I safe to push?' recipe.
ci: spdx format lint typecheck test bench
    @echo "ci: ALL GATES GREEN"

# Full local CI including the production bundle (sandbox-RAM hostile).
ci-full: spdx format lint typecheck test bench build
    @echo "ci-full: ALL GATES GREEN (including build)"

# Estate-quality composite: format + lint + tests.
quality: format lint test
    @echo "quality: OK"

# Every test category wired in this lane (E2E excluded: needs browsers).
test-all: test-types test-unit test-integration
    @echo "test-all: OK (e2e is an opt-in lane: just test-e2e)"

# ----------------------------------------------------------------------- #
# Build / serve (hostile in low-RAM sandboxes: dev server is fine,
# `vite build` may be OOM-killed under ~1.5 GB — that is the known
# environment limitation, not a code defect; CI runs it fine.)
# ----------------------------------------------------------------------- #

# Vite dev server (foreground; http://localhost:5173, exposed on all
# interfaces so the sandboxed live preview can reach it).
dev:
    cd frontend && bun run dev -- --host

# Production bundle (tsc + vite build). RAM-hungry; see note above.
build:
    cd frontend && bun run build

# Preview the production bundle (requires 'just build' first; fails loudly
# rather than idling when no bundle exists).
preview:
    #!/usr/bin/env bash
    if [[ ! -d frontend/dist ]]; then
        echo "PREVIEW UNAVAILABLE: frontend/dist does not exist — run 'just build' first." >&2
        exit 1
    fi
    cd frontend && bun run preview

# ----------------------------------------------------------------------- #
# Estate launcher (Julia server; requires instantiated Julia project)
# ----------------------------------------------------------------------- #

# Start the MetaManifold server via the estate launcher.
start:
    "{{LAUNCHER}}" --start

# Stop it.
stop:
    "{{LAUNCHER}}" --stop

# Restart it.
restart:
    "{{LAUNCHER}}" --stop; sleep 1; "{{LAUNCHER}}" --start

# Server status.
status:
    "{{LAUNCHER}}" --status

# ----------------------------------------------------------------------- #
# Security / audit
# ----------------------------------------------------------------------- #

# Dependency vulnerability audit (informational report, not a gate).
audit:
    cd frontend && bun audit

# ----------------------------------------------------------------------- #
# Cleanup
# ----------------------------------------------------------------------- #

# Remove generated outputs (dist, coverage, playwright/test results).
clean:
    rm -rf frontend/dist frontend/coverage frontend/playwright-report frontend/test-results

# Remove generated outputs AND installed dependencies.
clean-all: clean
    rm -rf frontend/node_modules

# ----------------------------------------------------------------------- #
# Integration & environment healing (fork↔upstream)
#
# The fork and upstream share no git ancestor, so a naive merge conflicts on
# every shared path. These recipes expose config/integration.toml as a set of
# trust decisions the maintainer can make incrementally — from "behave exactly
# like upstream" (base) to "everything verified" (full) — without ever
# compromising a running system: the default profile changes no behaviour.
# Engine: scripts/integrate.sh. Guide: docs/integration/README.md.
# ----------------------------------------------------------------------- #

# Repair the local environment to a known-good state: re-sync repo pins, re-wire
# hooks + merge drivers, regenerate the machine tool map, reinstall frontend
# deps, and (where present) re-instantiate Julia and restore the R lockfile.
# Resilient by design — each lane is attempted and a failure is reported, not
# fatal. Idempotent. The "fix my box" one-shot.
heal:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "heal: re-syncing repo pins...";            just sync-pins            || echo "heal: sync-pins skipped"
    echo "heal: re-wiring hooks + merge drivers...";  just hooks merge-drivers
    echo "heal: regenerating machine tool map...";    just codegen-tools        || echo "heal: codegen-tools skipped"
    echo "heal: reinstalling frontend deps...";       just install              || echo "heal: install skipped"
    if timeout 15 $JULIA_CMD --version >/dev/null 2>&1; then
        echo "heal: re-instantiating Julia...";       just julia-instantiate    || echo "heal: julia-instantiate skipped"
    else
        echo "heal: Julia absent — provision the pinned toolchain with: just setup-tools"
    fi
    if command -v Rscript >/dev/null 2>&1; then
        echo "heal: restoring R lockfile...";         just renv-restore         || echo "heal: renv-restore skipped"
    else
        echo "heal: R absent — R lane left untouched (documented exception)"
    fi
    echo "heal: done. Verify with: just doctor"

# Integration profiles & component toggles (thin wrappers over scripts/integrate.sh).
integrate: integrate-status

integrate-status:
    @{{INTEGRATE}} status

integrate-profiles:
    @{{INTEGRATE}} profiles

# Switch the active profile: just integrate-profile <base|transitional|full>.
integrate-profile profile="base":
    @{{INTEGRATE}} profile "{{profile}}"

# Recommended staging order (safest → riskiest).
integrate-plan:
    @{{INTEGRATE}} plan

# Classify in-progress merge conflicts (auto / component / human).
integrate-triage:
    @{{INTEGRATE}} triage

# Gates for the active selection; add strict="--strict" to require the tools be present.
integrate-verify strict="":
    @{{INTEGRATE}} verify {{strict}}

# Suspend a component: it stops being active (if runtime-gated, it will refuse).
suspend component:
    @{{INTEGRATE}} disable "{{component}}"

# Augment a component: it becomes active for this checkout.
augment component:
    @{{INTEGRATE}} enable "{{component}}"

# ----------------------------------------------------------------------- #
# Re-anchoring — collapse the one-shot merge into granular per-commit work
#
# The fork and upstream share the root commit but diverged early and developed
# in parallel, so a single merge shows ~159 conflicts at once. `reanchor` replays
# the fork's commits one-by-one onto upstream (git auto-applies the clean ones),
# turning that wall into a handful of small decisions. Measured: the whole fork
# re-anchors with 3 decisions and 0 residual conflicts, producing ~206 granular
# commits the maintainer can review/merge incrementally. Runs in an isolated
# worktree — it never touches your current branch. Engine: scripts/reanchor.sh.
# ----------------------------------------------------------------------- #

# Read-only plan: classify each fork commit (auto-apply / overlap / delete-risk).
reanchor-plan:
    @{{REANCHOR}} plan

# Perform the re-anchor; leave a reviewable branch `reanchor/onto-upstream`.
reanchor:
    @{{REANCHOR}} run --branch reanchor/onto-upstream --keep

# Re-anchor but STOP at every conflict for hands-on resolution.
reanchor-manual:
    @{{REANCHOR}} run --policy manual --keep
