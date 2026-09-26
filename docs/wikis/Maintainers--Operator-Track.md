<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000021
parent: 0198ba50-0000-7000-8000-000000000020
position: 10
kind: page
tags:
  - maintainers
  - operators
  - deployment
archived: false
-->

# Operator track

**Status: PARTIAL — single-user local operation is IN PLACE and supported;
server/multiuser operation is explicitly NOT (yet).** This page is for
whoever keeps an instance healthy.

## Deployment posture (read this first)

The present server is a **local single-user** application. It binds `:8080`
and serves the workbench to a browser on the same machine. Do **not** expose
it to a network as if it were multiuser-ready — no authn/authz layer exists,
and job execution is not isolated between users. A standing line in
`docs/migration/STATUS.md` says exactly this; repeat it to stakeholders.

What "local" still gives you in a lab: multiple analysts can use one machine
(same OS account), and the service answer "the analysis station" is the
supported shape.

**COMING:** authenticated remote/multiuser deployment (agreed requirement,
not delivered), standalone archives (below), coordinated signed updater
(below).

## The install you operate

Source install is the supported lane (see
[Install and First Run](Users--Install-and-First-Run)). The operator's pieces:

| Artefact | You operate | Notes |
|---|---|---|
| `mise.toml` | exact toolchain pins | source of truth; `.bun-version` is generated from it (`just sync-pins`) |
| `guix.scm` + `channels.scm` | the peer dev lane | time-machine-pinned; functional equivalents for tools, not binary identity |
| `renv.lock` | exact R package set | restore via `renv::restore()`; `.Rprofile` activates the project library |
| `config/defaults/tool_versions.yml` | sha256-pinned tool downloads | `install.sh` fetches byte-exact; preflight asserts |
| `config/tools.yml` | resolved tool paths | including SSH-hosted binaries for vsearch etc. |

## Reference databases (the real operational load)

`config/databases.yml` is the one place to manage URIs, local overrides and
remote paths. Operator rules that matter in production:

1. **Mirror the reference FASTAs locally** (`local:` override) before a busy
   period — first use downloads, and you do not want that at 09:00 on batch
   day. The Databases page can trigger downloads explicitly.
2. **Pin the release** you validated for the assay, for **both** formats
   (dada2 + vsearch) of a database. The consensus comparator is string
   equality across the two classifiers — mixed releases silently degrade
   agreement scores.
3. **Renaming/removing a database or its `levels` reports blast radius** —
   which studies it affects, resolved through the real cascade including
   inheritors. Act on the report.
4. For the SSH taxonomy offload: `remote_path` in `databases.yml` keeps the
   database resident on the remote host (no per-run transfer). **Authorisation
   to the remote host is solely yours to ensure** — the disclaimer in
   `config/defaults/pipeline.yml` is deliberate and non-negotiable.

## Capacity and performance

- Memory pressure concentrates in `assignTaxonomy()` (DADA2, large
  databases). Levers: `dada2.taxonomy.multithread` (higher = more memory),
  the SSH offload, or smaller/custom reference sets.
- The OTU lane (swarm) is CPU-scalable (`swarm.threads`); cd-hit-est likewise
  (`cdhit.threads`).
- Benchmarks (`bench/`) carry recorded baselines (table loading, duckdb
  aggregation, tree rendering, PERMANOVA/NMDS, epistemic parsing) — use them
  to detect that *your* host is the regression, not the code.
- Storage: budget per run ≈ trimmed FASTQs + QC reports + tables; `projects/`
  grows monotonically (checkpoints included). Back up `data/` + `projects/`;
  `config/` is small and precious (presets, primers, databases, composition
  library).

## Day-2 operations

| Task | How |
|---|---|
| Update tools | `bash install.sh --update` (re-resolves against the pinned records) |
| Update R packages | **don't**, casually — `renv.lock` is the reproducibility contract; changes go through the steward track with a lockfile diff |
| Backup | `data/`, `projects/`, `config/` — everything else is reconstructable |
| Health | `GET /api/v1/capabilities` (e.g. R availability); jobs panel + SSE stream during runs |
| Port/root changes | `JULIA_METAMANIFOLD_PORT`, `JULIA_METAMANIFOLD_ROOT`, `JULIA_THREADS` |
| Suspected stale outputs | trust the staleness flags (they name changed keys); `run_config.yml` is ground truth for what ran |

## When something refuses at 09:00

Refusals name themselves (unsuccessful states, "Not Implemented", "unknown"
significance). [Troubleshooting](Users--Troubleshooting) decodes them. The
one operational trap: **"Not Implemented" is not an outage** — the method or
package is genuinely absent from the locked environment and the software
refuses rather than guesses. Escalating that means a feature request, not a
restart.

## Coming on this track

- **COMING:** standalone offline archives (Linux x86-64 + ARM64) — unprivileged
  launcher, writable state outside the immutable release, no toolchain on the
  host, lazy science downloads proven, then explicit WSL2 tests. Policy
  exists (`packaging/`, `docs/migration/STATUS.md` workstream B); the builder
  does not exist yet.
- **COMING:** the coordinated updater — one tested pinned combination,
  signed metadata, transactional switch with rollback, offline startup.
- **COMING:** multiuser/authenticated serving — the precondition for
  network deployment.
