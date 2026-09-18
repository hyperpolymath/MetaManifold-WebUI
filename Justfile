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
    need() {
        if command -v "$1" >/dev/null 2>&1; then printf 'PASS  %-10s %s\n' "$1" "$($1 --version 2>&1 | head -1)";
        else printf 'FAIL  %-10s %s\n' "$1" "$2"; rc=1; fi
    }
    need bun  "install: curl -fsSL https://bun.sh/install | bash"
    need git  "install via package manager"
    if $JULIA_CMD --version >/dev/null 2>&1; then
        printf 'PASS  %-10s %s\n' "julia" "$($JULIA_CMD --version)"
    else
        printf 'WARN  %-10s %s\n' "julia" "Julia lanes unavailable — install via juliaup (install.sh)"
    fi
    [[ -x "{{LAUNCHER}}" ]] && echo "PASS  launcher   {{LAUNCHER}}" || { echo "WARN  launcher   not executable: {{LAUNCHER}}"; }
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
bootstrap: setup-tools install
    @echo "bootstrap: toolchain + deps ready — next: just ci"

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

# Report outdated frontend packages (informational only).
outdated:
    cd frontend && bun outdated || true

# Instantiate the Julia project (downloads + precompiles; heavy first run).
julia-instantiate:
    $JULIA_CMD --project=. -e 'using Pkg; Pkg.instantiate(); println("instantiate OK")'

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
