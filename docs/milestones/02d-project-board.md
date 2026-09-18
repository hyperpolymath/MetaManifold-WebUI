<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Milestone 2d — Project Board Created and Linked

**Date:** 2026-09-18
**Board:** https://github.com/users/hyperpolymath/projects/45 — "Analysis Layer & Cladistics Development"
**ID:** PVT_kwHOAGclzc4Bj75p
**Owner:** user hyperpolymath (viewer id MDQ6VXNlcjY3NTk4ODU=, global U_kgDOAGclzQ) — org hyperpolymath requires read:org scope PAT lacked (scopes audit_log notifications project repo workflow), so user-level project used. For org-level need new PAT with read:org.

## Fields via GraphQL

- Status PVTSSF_lAHOAGclzc4Bj75pzhiuaug: Backlog 53ac003b GRAY Not started, In Progress ec5c1d4b YELLOW Actively being worked, Review 9a8c5602 PURPLE PR open, Done caf96e7c GREEN Completed, Blocked 0ef6e85a RED Blocked — updated from default Todo/In Progress/Done via updateProjectV2Field String! option id not ID! pitfall
- Method PVTSSF_lAHOAGclzc4Bj75pzhiuax4: NB_GLM e3c27189 BLUE, CLR_LM ddba7c54 GREEN, ILR_LM 2cd33dcc YELLOW, LOGISTIC ed91db60 ORANGE, CladeCumulus 34954efc PURPLE, Epistemic 6b6a371d PINK, Infra 883cbc93 GRAY
- Risk PVTSSF_lAHOAGclzc4Bj75pzhiua0k: Low 176cff2e GREEN, Medium 0e1e5b17 YELLOW, High b687de19 RED, Scientific 76eafa38 ORANGE

## Issues (10) via REST POST https://api.github.com/repos/hyperpolymath/MetaManifold-WebUI/issues

- #3 Exact stats Fisher exact exact NB permutation — I_kwDOUdgzDs8AAAABR-7t7g item PVTI_lAHOAGclzc4Bj75pzg7oYV0 Backlog NB_GLM Scientific — deferred high value hard difficulty risks performance 10-100x memory 100M 800MB
- #4 Symbolic engine formula manipulation — I_kwDOUdgzDs8AAAABR-7uLg PVTI_lAHOAGclzc4Bj75pzg7oYWQ Backlog Infra High — deferred very hard risks complexity wrong conclusions scope creep security injection
- #5 ANCOM-BC ALDEx2 Songbird — I_kwDOUdgzDs8AAAABR-7uew PVTI_lAHOAGclzc4Bj75pzg7oYWg Backlog CLR_LM Scientific — deferred hard dependency hell performance hours controversy reproducibility seed
- #6 CladeCumulus phylogenetic integration — I_kwDOUdgzDs8AAAABR-7uwg PVTI_lAHOAGclzc4Bj75pzg7oYXI Backlog CladeCumulus Medium — deferred hard O(n^3) tree
- #7 Full Evidence Mode epistemic editor fiber visualizer — I_kwDOUdgzDs8AAAABR-7vBg PVTI_lAHOAGclzc4Bj75pzg7oYXY Backlog Epistemic Medium — deferred medium UI clutter 1M candidates
- #8 Zenodo DOI minting — I_kwDOUdgzDs8AAAABR-7vVw PVTI_lAHOAGclzc4Bj75pzg7oYX0 Backlog Infra Low — deferred medium token security irreversibility
- #9 AnalysisConfig v1 NB GLM CLR/ILR+LM logistic BH mandatory DANGER — I_kwDOUdgzDs8AAAABR-7x1g PVTI_lAHOAGclzc4Bj75pzg7oYYc In Progress→Review NB_GLM Scientific — branch feat/analysis-config-v1 addfc7d..8a2a9a3 PR #11 https://github.com/hyperpolymath/MetaManifold-WebUI/pull/11
- #10 CladeCumulus cumulative explorer epistemic colours — I_kwDOUdgzDs8AAAABR-7yDg PVTI_lAHOAGclzc4Bj75pzg7oYZA In Progress→Review CladeCumulus Medium — branch feat/clade-cumulus 099cff3..a6e50e6 PR #12 https://github.com/hyperpolymath/MetaManifold-WebUI/pull/12
- #13 chore(ci) remove Codecov — PR #13 https://github.com/hyperpolymath/MetaManifold-WebUI/pull/13 branch chore/remove-codecov caf98d2 item PVTI_lAHOAGclzc4Bj75pzg7obew Review Infra Low
- #15 Milestone 2 BASELINE TESTS + BENCHMARKS + CI/CD + PROJECT BOARD — I_kwDOUdgzDs8AAAABR_eadQ PR #14 https://github.com/hyperpolymath/MetaManifold-WebUI/pull/14 feat/baseline-benchmarks-ci 24b3836 merged 3ce1d60 → main 18eff7c

All added via addProjectV2ItemById, field values via updateProjectV2ItemFieldValue String! option id

## PRs Linked (4)

- PR #11 feat(analysis) AnalysisConfig v1 — PR_kwDOUdgzDs8AAAABEG4pTg item PVTI_lAHOAGclzc4Bj75pzg7oYyo Review NB_GLM Scientific Closes #9
- PR #12 feat(cladistics) CladeCumulus — PR_kwDOUdgzDs8AAAABEG4qRQ item PVTI_lAHOAGclzc4Bj75pzg7oYzA Review CladeCumulus Medium Closes #10
- PR #13 chore(ci) remove Codecov — PR_kwDOUdgzDs8AAAABEG6Ogg item PVTI_lAHOAGclzc4Bj75pzg7obew Review Infra Low
- PR #14 feat(bench) baseline tests + benchmarks + CI/CD + project board Milestone 2 — PR_kwDOUdgzDs8AAAABEHVpsg merged

Total items on board: 13 (10 issues + 3 PRs active + PR #14 merged still counted) totalCount 13

## Automation (planned, documented in 01-project-board-graphql.md)

```yaml
name: Project Board Automation
on:
  issues: [opened, closed, reopened]
  pull_request: [opened, closed, reopened, synchronize]
jobs:
  update-board:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/add-to-project@v0.5.0
        with:
          project-url: https://github.com/users/hyperpolymath/projects/45
          github-token: ${{ secrets.PROJECT_PAT }}
```

Should be added as .github/workflows/project-board.yml with PROJECT_PAT secret

## Security

- PAT ghp_***REDACTED*** pasted in clear chat — should be revoked, replaced with fine-grained PAT stored as PROJECT_PAT secret, no secrets in code, token used via env var GITHUB_TOKEN remote url reset after push

End 2d
