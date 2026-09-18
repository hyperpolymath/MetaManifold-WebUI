<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Milestone 04 — Project Board, Issues, Branches, PRs

**Date:** 2026-09-18
**Board:** https://github.com/users/hyperpolymath/projects/45 — "Analysis Layer & Cladistics Development"
**ID:** PVT_kwHOAGclzc4Bj75p

## What Was Done

### 1. Project Board Created via GraphQL
- Owner: user hyperpolymath (viewer id MDQ6VXNlcjY3NTk4ODU=, global U_kgDOAGclzQ) — org hyperpolymath requires read:org scope which PAT lacked, so user-level project used (same owner, visible at https://github.com/users/hyperpolymath/projects/45)
- Title: "Analysis Layer & Cladistics Development"
- Fields:
  - Status (PVTSSF_lAHOAGclzc4Bj75pzhiuaug): Backlog (53ac003b), In Progress (ec5c1d4b), Review (9a8c5602), Done (caf96e7c), Blocked (0ef6e85a) — updated from default Todo/In Progress/Done
  - Method (PVTSSF_lAHOAGclzc4Bj75pzhiuax4): NB_GLM (e3c27189), CLR_LM (ddba7c54), ILR_LM (2cd33dcc), LOGISTIC (ed91db60), CladeCumulus (34954efc), Epistemic (6b6a371d), Infra (883cbc93)
  - Risk (PVTSSF_lAHOAGclzc4Bj75pzhiua0k): Low (176cff2e), Medium (0e1e5b17), High (b687de19), Scientific (76eafa38)

### 2. Issues Created (8)
Via REST POST https://api.github.com/repos/hyperpolymath/MetaManifold-WebUI/issues with PAT

- #3 Exact statistics layer — Fisher's exact, exact NB, permutation — node I_kwDOUdgzDs8AAAABR-7t7g — item PVTI_lAHOAGclzc4Bj75pzg7oYV0 — Status Backlog, Method NB_GLM, Risk Scientific
- #4 Symbolic engine for formula manipulation — node I_kwDOUdgzDs8AAAABR-7uLg — item PVTI_lAHOAGclzc4Bj75pzg7oYWQ — Backlog, Infra, High
- #5 Advanced compositional methods ANCOM-BC, ALDEx2, Songbird — node I_kwDOUdgzDs8AAAABR-7uew — item PVTI_lAHOAGclzc4Bj75pzg7oYWg — Backlog, CLR_LM, Scientific
- #6 CladeCumulus phylogenetic integration — node I_kwDOUdgzDs8AAAABR-7uwg — item PVTI_lAHOAGclzc4Bj75pzg7oYXI — Backlog, CladeCumulus, Medium
- #7 Full Evidence Mode — epistemic editor, fiber visualizer — node I_kwDOUdgzDs8AAAABR-7vBg — item PVTI_lAHOAGclzc4Bj75pzg7oYXY — Backlog, Epistemic, Medium
- #8 Zenodo integration — DOI minting — node I_kwDOUdgzDs8AAAABR-7vVw — item PVTI_lAHOAGclzc4Bj75pzg7oYX0 — Backlog, Infra, Low
- #9 AnalysisConfig v1 — NB GLM, CLR/ILR+LM, logistic, BH mandatory, DANGER banner — node I_kwDOUdgzDs8AAAABR-7x1g — item PVTI_lAHOAGclzc4Bj75pzg7oYYc — In Progress, NB_GLM, Scientific
- #10 CladeCumulus cumulative explorer with epistemic colours — node I_kwDOUdgzDs8AAAABR-7yDg — item PVTI_lAHOAGclzc4Bj75pzg7oYZA — In Progress, CladeCumulus, Medium

All added to board via addProjectV2ItemById, then field values updated via updateProjectV2ItemFieldValue with String! option id (not ID! — GraphQL type mismatch pitfall documented).

### 3. Branches Pushed
- feat/analysis-config-v1: 21 files, 5276 insertions, single commit addfc7d29ffc56acd0480441aced8c0490388996 with noreply email 6759885+hyperpolymath@users.noreply.github.com (fixed from j.d.a.jewell@open.ac.uk which was blocked by GH007 email privacy)
- feat/clade-cumulus: 21 files, same content plus cladistic explorer, commit 099cff32b9ec12222495eab9a02672cf2b9f9419

Push via https://TOKEN@github.com/... with force-with-lease, then remote url reset to https.

### 4. PRs Opened (Draft)
- PR #11 https://github.com/hyperpolymath/MetaManifold-WebUI/pull/11 — feat(analysis): safe, explicit, versioned AnalysisConfig layer v1 — head feat/analysis-config-v1, base main, draft true, node PR_kwDOUdgzDs8AAAABEG4pTg, item PVTI_lAHOAGclzc4Bj75pzg7oYyo — Status Review, Method NB_GLM, Risk Scientific — Closes #9
- PR #12 https://github.com/hyperpolymath/MetaManifold-WebUI/pull/12 — feat(cladistics): CladeCumulus cumulative explorer with epistemic colours and drag-drop — head feat/clade-cumulus, base main, draft true, node PR_kwDOUdgzDs8AAAABEG4qRQ, item PVTI_lAHOAGclzc4Bj75pzg7oYzA — Status Review, Method CladeCumulus, Risk Medium — Closes #10

Both added to board, statuses updated to Review.

### 5. Token Handling
- PAT provided via chat: ghp_kGEH0... (full redacted in this report). Used via env var GITHUB_TOKEN, never written to file, never logged. Remote URL reset after push. PAT scopes: audit_log, notifications, project, repo, workflow — missing read:org, so org-level project not possible, user-level used. Recommendation: generate new PAT with read:org if org-level board desired, then migrate, and rotate this PAT (it was pasted in clear text in chat, should be revoked after use per security best practice).

### 6. CI/CD Status
- Branches pushed, CI will run via .github/workflows/ci.yml on PRs (repo-hygiene + test matrix julia 1.12.5 ubuntu-24.04, R pinned, Bun 1.3.10, typecheck, bun:test coverage, bench, build, download PR2, RCall rebuild, julia tests, codecov upload). Codecov token residue still in workflow (secrets.CODECOV_TOKEN) — user said codecov is gone, so should be removed in chore PR later.
- No local Julia/Bun in sandbox (mise missing), so tests not run locally — rely on CI.

### 7. Where AnalysisConfig & CladeCumulus Live (Confirmed)
- Julia: src/analysis/analysis_config.jl, src/analysis/clade_cumulus.jl, src/core/epistemic.jl, src/server/routes/analysis_config.jl, src/MetaManifold.jl includes, src/server/server.jl includes
- Config: config/schemas/analysis_config.schema.json (draft 2020-12), config/schemas/analysis_config.ncl (Nickel), config/templates/analysis_config_chora.deed (DEED v0.2.0, :schema-version first, SPDX header)
- Frontend: frontend/src/types/analysis_config.ts, frontend/src/components/AnalysisConfigEditor.tsx, DangerBanner.tsx, AdvancedAnalysisExpander.tsx, EvidenceModeToggle.tsx, CladeCumulus.tsx, frontend/src/api/client.ts extended
- Tests: test/unit/test_analysis_config.jl, bench/analysis_config/benchmark.jl with 10% regression gate
- Docs: docs/milestones/00-reconnaissance.md, 01-project-board-graphql.md, 02-deferred-issues.md, 03-analysis-config-v1.md, 04-project-board-and-prs.md (this file)

### 8. Epistemic Layer Status
- On main: absent (zero hits)
- External specs: /tmp/echo-types, /tmp/epistemic-types, /tmp/residual-evidence-types — Agda proofs present
- In feature branches: additive bridge src/core/epistemic.jl with EchoFiber avec_fibre/sans_fibre, Warrant, Candidate, present_in_every_admissible_world, colour coding, cloud_size log(1+residual)
- No overwrite of colleagues' work — additive, feature-flagged

### 9. Next Steps
1. Wait for CI on PR #11 and #12 — fix any failures (SPDX, format, lint, typecheck, tests)
2. Review PR #11, merge to main (squash), then rebase feat/clade-cumulus onto new main to avoid duplicate AnalysisConfig files
3. Implement full CladeCumulus D3 hierarchy, real DuckDB queries for cumulative frequencies, drag-drop API integration in RunView.tsx
4. Create .github/workflows/project-board.yml with actions/add-to-project@v0.5.0 using PROJECT_PAT secret — automate status updates on PR open/close
5. Rotate PAT (revoke ghp_kGEH...), create new fine-grained PAT with repo, workflow, project, read:org, store as PROJECT_PAT secret in repo settings
6. Remove Codecov step if confirmed gone, or add CODECOV_TOKEN secret
7. For deferred issues, keep Backlog status, update when dependencies met
8. Milestone report after each PR merge

## Links
- Board: https://github.com/users/hyperpolymath/projects/45
- Issues: #3-#10
- PRs: #11, #12
- Recon report: /home/user/COMBINED_ANALYSIS_CLADISTICS_RECONNAISSANCE_v1.md and docs/milestones/00-reconnaissance.md on feature branches

## Security Note
PAT was pasted in clear text in chat — per GitHub security, it should be revoked immediately after use and replaced with fine-grained PAT stored as secret. This report redacts full token.

---
End Milestone 04
