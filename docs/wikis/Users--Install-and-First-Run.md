<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000011
parent: 0198ba50-0000-7000-8000-000000000010
position: 10
kind: page
tags:
  - users
  - install
  - guide
archived: false
-->

# Install and first run

**Status: IN PLACE** (the install path; standalone offline installers are
**COMING** — `docs/migration/STATUS.md` — until then this source-install path
is the supported one).

MetaManifold runs locally on one machine, single-user, and serves its
workbench to your browser at `http://localhost:8080`.

## What you need before starting

| Requirement | Pin | Why |
|---|---|---|
| Linux or macOS (WSL2 works **PARTIAL**ly, unvalidated) | — | the orchestrator shells out to native tools |
| Julia | 1.12.5 (pinned; auto-installed) | the pipeline engine and API server |
| R ≥ 4.0 | system install (documented exception) | DADA2, vegan — the science lane |
| Bun | 1.3.10 (pinned) | builds the browser UI |
| Node | 20.20.2 (pinned) | toolchain peer |
| just | 1.43.1 (pinned) | task runner for the dev lanes (not needed to *use* the app) |
| Internet (first run only) | — | downloads sha256-pinned pipeline tools and reference databases |

The exact pins live in `mise.toml` (the toolchain source of truth is
`docs/reproducibility.md`). Pipeline tools — cutadapt, FastQC, MultiQC,
vsearch, cd-hit-est, swarm — are fetched **byte-exact** (sha256-verified) by
`install.sh`; no third-party binary is vendored in the repository.

## Install — one command lane

```bash
git clone https://github.com/hyperpolymath/MetaManifold-WebUI.git
cd MetaManifold-WebUI
bash install.sh
```

`install.sh` checks for Julia and R, installs the Julia and R dependencies
(the R side through `renv.lock` — exact package versions), and locates or
downloads each pipeline tool. It writes `config/tools.yml` with resolved
paths.

**Alternative (reproducible shell):** with `mise` installed,
`just bootstrap && just setup-full` gives the CI-pinned toolchain plus
tools; with GNU Guix, `guix time-machine -C channels.scm -- shell -D -f
guix.scm` opens the peer-lane environment.

## Start the server

```bash
bash start.sh        # builds the frontend on first run
# → open http://localhost:8080
```

Environment knobs (all optional):

| Variable | Default | Meaning |
|---|---|---|
| `JULIA_METAMANIFOLD_PORT` | `8080` | server port |
| `JULIA_METAMANIFOLD_ROOT` | working directory | where `data/` and `projects/` live |
| `JULIA_THREADS` | `8` | Julia threads |

**Academics:** pin the toolchain exactly as above and your methods section
can honestly say "versions pinned in `mise.toml` and `renv.lock`". The
reproducibility statement for a paper is mostly written for you — see
[For Academics](Users--For-Academics).

**Lab professionals:** `install.sh --update` re-resolves tools when you
refresh the install. For lab servers, read the operator track —
[Operator Track](Maintainers--Operator-Track) — before running this on a
shared machine.

## Verify the install

The workbench's SYSTEM sidebar (Databases, Primers, Compositions pages) is
populated, and `GET /api/v1/capabilities` reports what the server can see
(e.g. whether R answered). From a checkout with the dev toolchain,
`just ci` runs every gate CI runs — useful after a move to new hardware.

## Known first-run snags

- **R not found.** R is the one documented system install (it is absent from
  the `mise` registry). Install R, re-run `install.sh`; `renv` restores the
  pinned packages into a project-local library via the committed `.Rprofile`.
- **Tool download failures** (firewalled hosts): re-run — the fetcher
  retries and names TLS failures explicitly (#51's behaviour). For air-gapped
  hosts see the operator track.
- **Port 8080 busy:** set `JULIA_METAMANIFOLD_PORT`.
- Everything else: [Troubleshooting](Users--Troubleshooting).

## What is coming at this layer

- **COMING:** standalone offline release archives (Linux x86-64 and ARM64)
  with everything bundled — users then provide only sequencing data and
  reference databases; and the coordinated signed updater. Not built yet;
  tracked in `docs/migration/STATUS.md`. When they land, this page gets a
  second, shorter install path above the source one.
