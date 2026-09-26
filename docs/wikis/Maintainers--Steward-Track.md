<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000022
parent: 0198ba50-0000-7000-8000-000000000020
position: 20
kind: page
tags:
  - maintainers
  - stewards
  - process
archived: false
-->

# Steward track

**Status: IN PLACE** as a working maintenance regime (since Milestone 2,
2026-09). This page is for whoever merges, releases, and answers for the
repository.

## The gates (all run locally and in CI)

| Gate | Command | Authority |
|---|---|---|
| Strict typecheck | `bun run typecheck` (in `frontend/`) | 0 errors, gated |
| Unit + integration tests | `bun test` | gated (DOM-less lane) |
| Benchmarks | `bun run bench/` | informational, no gate |
| Combined pre-push | `bun run check` | the everything lane |
| Licence headers | `scripts/check-spdx.sh` | gated |
| Formatting | `scripts/check-format.sh` | gated |
| Lint (tsc semantics + shell) | `scripts/check-lint.sh` | gated |
| Julia suite | `just` test recipes | gated |
| Everything CI runs | `just ci` | the proof lane |

CI (`.github/workflows/ci.yml`) runs repo-hygiene first, then the pinned
Julia and frontend jobs — the same commands as local, by design.

## Review and merge conventions

- Commit convention is enforced (the commit gate grades every non-merge
  commit a PR proposes — merge commits themselves are exempt since #37/#45's
  fix, so GitHub's "Update branch" button no longer reds a conforming PR).
- Branch/PR shape: `CONTRIBUTING.md`; the PR template adapts the RSR one to
  the bun/frontend gates (ABI/FFI items dropped as not applicable).
- Dependabot (github-actions + bun/frontend ecosystems) auto-merges **on
  green** — a broken bump fails CI and stays open, never lands red. Do not
  add Dependabot as a ruleset bypass actor (that would skip required
  security checks — a documented anti-pattern in the estate records).
- Required status checks embed toolchain names; when bumping the Julia pin
  remember the known trap (issue #38): update the required-check names in the
  same change or every PR deadlocks.

## Upstream relations (the fork discipline)

This repository is a **fork of JoshuaJewell/MetaManifold-WebUI** and the
relationship is contractual in practice:

1. **Base is always `hyperpolymath`** for day-to-day work. Never push
   directly to `joshuajewell`.
2. **The fork tracks application changes; it does not fork the science.**
   Pipeline semantics (DADA2/swarm/vsearch behaviour) are upstream's domain;
   fixes there flow *to* upstream as patch series/PRs.
3. Upstream PRs are prepared as a reviewed series (the owner-review record in
   `docs/owner-review-2026-09-25.md` documents the PR flow and the four
   options offered to the origin owner). Upstream-facing commitments:
   - Issues #1 (statistics umbrella) and #2 (symbolic engine, BLOCKED) must
     never be closed prematurely.
   - Closed milestone issues mean *the milestone closed* — deferred designs
     are preserved in `docs/milestones/02-deferred-issues.md` and
     `docs/issues/milestone3/`, not discarded.
   - Nothing from the origin repository was ever rewritten; divergence is
     additive.
4. Licence asymmetry is deliberate (`NOTICE`): upstream-authored =
   `AGPL-3.0-only`, fork-authored = `MPL-2.0` / `CC-BY-SA-4.0`. Do not
   "harmonise" headers.

## Milestone and issue discipline

- Milestones document what the repository *does* (audit close-outs in
  `docs/audit/`), not what it wishes.
- The project board is maintained via GraphQL (the classic-projects deprecation
  is already absorbed — see `docs/milestones/01-project-board-graphql.md`).
- Scientific-value and difficulty labels on analysis issues are load-bearing
  for sequencing the deferred queue ([Status and Roadmap](Status-and-Roadmap)
  "Near-term order of work").

## Release mechanics (today)

Tags + CHANGELOG + source. The full release/distribution story is
[Releases and Distribution](Maintainers--Releases-and-Distribution). `v0.1.0`
notes: `docs/release-notes/v0.1.0.md`.

## Settings and repository surface

- **Autolink references** are fully specified (four tiers: lineage/estate,
  upstream tools, toolchain, registries) in
  `docs/integration/autolink-references.md` — paste-ready for
  Settings → Autolink references. Autolink application needs Administration
  permission; the specification file is the source of truth for whoever has
  it.
- Issue templates carry the fork/upstream scope split; CODEOWNERS routes to
  `@hyperpolymath`.
- The wiki (this documentation) is sourced from `docs/wikis/` and published
  to `MetaManifold-WebUI.wiki.git` — review wiki content in PRs like any
  other change (`docs/wikis/README.md`).

## Coming on this track

- **COMING:** coverage gate — lands against a recorded baseline
  (`docs/testing/coverage.md`), not an arbitrary number; OpenSSF Best
  Practices + Scorecard enrolment (badges only on the day); the DOM test-lane
  decision (playwright vs harness) before growing the e2e set; benchmark
  stability window → non-gating regression alert.
