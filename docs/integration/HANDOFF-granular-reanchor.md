<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# HANDOFF — land the granular re‑anchor (fork → upstream)

> **This is a brief for the next agent/session.** Everything it needs is already
> in the repo and measured. The goal: turn the fork↔upstream divergence into a
> **granular, reviewable, mergeable history** and land it, without ever
> compromising a running system. Read [`README.md`](./README.md) and
> [`conflict-map-2026-09-25.md`](./conflict-map-2026-09-25.md) first.

## Objective

Produce a branch that is **upstream's history with the fork's ~206 commits
cleanly replayed on top** (`reanchor/onto-upstream`), review the handful of
decisions it makes, verify the gates are green on it, and land it into
`JoshuaJewell/MetaManifold-WebUI` — either whole, or tier‑by‑tier — with a PR
that links the integration guide.

## What already exists (do not rebuild)

- `scripts/reanchor.sh` + `just reanchor` / `reanchor-plan` / `reanchor-manual`
  — the re‑anchor engine. **Proven:** the whole fork re‑anchors with **3
  decisions, 0 residual conflicts, ~206 commits**.
- `scripts/integrate.sh` + `just integrate …` + `config/integration.toml` —
  profiles (`base`/`transitional`/`full`), per‑component toggles, conflict triage.
- `.gitattributes` merge hygiene + `just merge-drivers`; `just heal`/`doctor`/
  `bootstrap`/`setup-full`/`renv-restore` for the turnkey environment.
- Measured facts in `conflict-map-2026-09-25.md`.

## Ground truth (re‑verify, don't assume)

```bash
git remote -v                         # upstream = JoshuaJewell/…, origin = hyperpolymath/…
git fetch --unshallow upstream origin # full history (the Arena clone is depth‑1!)
git merge-base origin/main upstream/main   # → 7884553 "Initial commit"
```

The histories share the root commit and diverged at the 2nd commit (fork 221
commits, upstream 89). A one‑shot merge = 159 conflicts; a re‑anchor = 3 decisions.

## Steps

1. **Plan.** `just reanchor-plan`. Record the auto/overlap/delete‑risk counts
   (expect ~55 auto‑apply, ~152 overlap, delete‑risk on `pipelinesteps.txt`).
2. **Re‑anchor.** `just reanchor` (== `scripts/reanchor.sh run --branch
   reanchor/onto-upstream --keep`). It runs in an isolated worktree; your current
   branch is untouched. Confirm the summary: `206 commits / 0 residual / 3
   decisions`.
3. **Review the 3 decisions.** They should all be `DELETE (upstream):
   pipelinesteps.txt` at commits `06d85ba`, `252299e`, `fed106b` — upstream
   deleted the file; the fork's early commits touched it. Confirm accepting the
   deletion is correct (it is: the file is gone upstream and superseded).
4. **Drop stray build output.** The re‑anchored tree keeps upstream's committed
   `web/dist/*` (7 files) that the fork had removed. On the branch:
   `git -C <worktree> rm -r web/dist` and amend/commit (`chore: drop committed
   web/dist build output`). These are build artefacts and must not be tracked.
5. **Confirm no upstream fix was silently reverted.** The default policy is
   fork‑wins on content, so the re‑anchored tree ≈ the fork tree (+ `web/dist`).
   Diff it against a *manual* three‑way merge to prove the only differences are
   the documented items:
   ```bash
   git -C <worktree> diff origin/main HEAD      # expect only web/dist (+ any you fixed)
   ```
   Spot‑check the high‑risk components named in `config/integration.toml`
   (`real-statistics`, `ui-migration`) against upstream to be sure nothing
   upstream‑authored was clobbered. If it was, resolve it by hand on the branch.
6. **Verify gates on the re‑anchored branch.** `just doctor`, then `just ci`
   (frontend: typecheck + tests + bench) and, where the environment allows,
   `just julia-test` and `just renv-restore`. The tree ≈ the fork's, so gates
   should behave exactly as on `origin/main`. Record the verdicts.
7. **Land it.** Pick one, with Joshua (upstream owner):
   - **Whole:** open a PR `hyperpolymath:reanchor/onto-upstream →
     JoshuaJewell:main`; it is now a normal, granular, mergeable branch.
   - **Tiered (recommended if trust is being built):** keep the branch, and
     cherry‑pick / merge components in the `just integrate plan` order
     (`estate-tooling → install-retry → matrix-1x1-fix → benchmarks-ci →
     exact-offsets → real-statistics → ui-migration`), gating each with CI before
     the next. Use `just integrate profile transitional|full` to mirror the
     adoption on a running checkout.
   Link [`docs/integration/README.md`](./README.md) in the PR body.

## Guardrails (non‑negotiable)

- **Never compromise operations.** The re‑anchored branch must pass its gates and
  must not silently drop an upstream fix. The 3 decisions + step 5 cover the known
  cases; anything else you find, resolve by hand and log it.
- **Branch discipline.** This session is pinned to `arena/01a0daa1-metamanifold-webui`.
  Produce the `reanchor/onto-upstream` branch *via the tool at runtime* (a user
  action), not by committing 206 commits onto the session branch. Do not switch
  the session branch.
- **Keep the aid merge‑clean.** Any further changes to the integration tooling
  stay on fork‑only / new paths (they add zero conflict surface for upstream).
- **Conventional commits** (`feat|fix|docs|…: …`, ≤72‑char subject) and run
  `scripts/check-spdx.sh` + `scripts/check-format.sh` before pushing.

## Decisions to confirm with Joshua (from the owner review, Options A–D)

Full merge · selective/tiered cherry‑pick · dual‑track fork · handover notice.
Also: keep `codecov.yml`? (fork removed Codecov) — recommend **drop**.

## Done when

- [ ] `reanchor/onto-upstream` exists, `git rev-list --count upstream/main..HEAD`
      ≈ 206, residual conflicts 0.
- [ ] `web/dist/*` removed on the branch.
- [ ] Diff vs `origin/main` is only the documented items (no surprise reversions).
- [ ] Gates green on the branch (recorded).
- [ ] PR opened against upstream, guide linked, adoption path agreed with Joshua.
