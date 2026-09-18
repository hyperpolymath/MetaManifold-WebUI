# Milestone 1 — GitHub Project Board via GraphQL

## Board Name
**Analysis Layer & Cladistics Development**

## Purpose
Track implementation of AnalysisConfig layer (v1: NB GLM, CLR/ILR+LM, logistic, BH mandatory, DANGER banner) and CladeCumulus (cumulative cladistic explorer with epistemic colour coding, cloud sizing, drag-and-drop with present_in_every_admissible_world validation).

## Required Token
GitHub PAT with scopes: `repo`, `workflow`, `project` (and `org:write` if under hyperpolymath org).

If PAT not available, mutations below can be run manually via `gh api graphql` or GitHub CLI.

## GraphQL Mutations — Ready to Paste

### 1. Create ProjectV2 (org-level or user-level)

For org `hyperpolymath`:

```graphql
mutation CreateProject {
  createProjectV2(input: {
    ownerId: "O_kgDO..." # org node ID, get via query below
    title: "Analysis Layer & Cladistics Development"
  }) {
    projectV2 {
      id
      title
      url
    }
  }
}
```

Get ownerId:

```graphql
query GetOrgId {
  organization(login: "hyperpolymath") {
    id
    login
  }
}
```

For user-level (if org not available):

```graphql
query GetUserId {
  viewer {
    id
    login
  }
}
```

Then create with ownerId = viewer id.

### 2. Create Custom Fields

```graphql
mutation CreateFields($projectId: ID!) {
  # Status field (single select)
  createStatus: createProjectV2Field(input: {
    projectId: $projectId
    dataType: SINGLE_SELECT
    name: "Status"
    singleSelectOptions: [
      { name: "Backlog", color: GRAY, description: "Not started, ready for pickup" },
      { name: "In Progress", color: YELLOW, description: "Actively being worked" },
      { name: "Review", color: PURPLE, description: "PR open, awaiting review" },
      { name: "Done", color: GREEN, description: "Completed and closed" },
      { name: "Blocked", color: RED, description: "Blocked by epistemic layer or other dependency" }
    ]
  }) {
    projectV2Field { id name }
  }

  # Method field
  createMethod: createProjectV2Field(input: {
    projectId: $projectId
    dataType: SINGLE_SELECT
    name: "Method"
    singleSelectOptions: [
      { name: "NB_GLM", color: BLUE, description: "Negative Binomial GLM" },
      { name: "CLR_LM", color: GREEN, description: "CLR + Gaussian LM" },
      { name: "ILR_LM", color: YELLOW, description: "ILR + Gaussian LM" },
      { name: "LOGISTIC", color: ORANGE, description: "Logistic regression" },
      { name: "CladeCumulus", color: PURPLE, description: "Cumulative Cladistic Explorer" },
      { name: "Epistemic", color: PINK, description: "Echo + Epistemic + Residual Evidence" },
      { name: "Infra", color: GRAY, description: "Project board, schemas, DOI bundles, CI" }
    ]
  }) {
    projectV2Field { id name }
  }

  # Risk field
  createRisk: createProjectV2Field(input: {
    projectId: $projectId
    dataType: SINGLE_SELECT
    name: "Risk"
    singleSelectOptions: [
      { name: "Low", color: GREEN },
      { name: "Medium", color: YELLOW },
      { name: "High", color: RED },
      { name: "Scientific", color: ORANGE, description: "Risk of false discoveries, DANGER banner needed" }
    ]
  }) {
    projectV2Field { id name }
  }
}
```

### 3. Create Issues (linked to board)

We will create issues via REST then add to board via GraphQL.

Issue list (see 02-deferred-issues.md for full bodies):

1. **feat(analysis): AnalysisConfig v1 — NB GLM, CLR/ILR+LM, logistic, BH mandatory**
2. **feat(analysis): Advanced Analysis expander with heavy validation and context help**
3. **feat(analysis): DANGER banner and hard-stop on BH override**
4. **feat(schemas): JSON + Nickel + DEED schemes from hyperpolymath/standards**
5. **feat(doi): DOI-ready bundles with DataCite, provenance, content-addressed hash**
6. **feat(epistemic): Bridge to echo-types, epistemic-types, residual-evidence-types (avec_fibre, present_in_every_admissible_world)**
7. **feat(cladistics): CladeCumulus — cumulative cladistic explorer tree**
8. **feat(cladistics): Epistemic colour coding and cloud sizing by residual count**
9. **feat(cladistics): Drag-and-drop with live present_in_every_admissible_world validation**
10. **feat(ui): Evidence Mode toggle, clean non-cluttered UI**
11. **test: Coverage for AnalysisConfig and CladeCumulus, benchmark regression gate (<10%)**
12. **deferred: Exact statistics layer (exact tests, symbolic engine) — DO NOT IMPLEMENT HERE**
13. **deferred: Symbolic engine for formula manipulation**

Each issue should be linked to board via:

```graphql
mutation AddIssueToBoard($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
    item { id }
  }
}
```

Where contentId is the issue's node ID (get via `gh api repos/hyperpolymath/MetaManifold-WebUI/issues/123 --jq .node_id`).

### 4. Update Board Status on Every PR

In PR template, add:

```graphql
mutation UpdateItemStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: ID!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId
    itemId: $itemId
    fieldId: $fieldId
    value: { singleSelectOptionId: $optionId }
  }) {
    projectV2Item { id }
  }
}
```

Get optionId via:

```graphql
query GetFieldOptions($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options { id name }
          }
        }
      }
    }
  }
}
```

### 5. Remove Completed Issues When Closed

On issue close, via webhook or manual:

```graphql
mutation DeleteItem($projectId: ID!, $itemId: ID!) {
  deleteProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
    deletedItemId
  }
}
```

Or archive:

```graphql
mutation ArchiveItem($projectId: ID!, $itemId: ID!) {
  archiveProjectV2Item(input: { projectId: $projectId, itemId: $itemId }) {
    item { id }
  }
}
```

## Automation via GitHub Actions

Create `.github/workflows/project-board.yml`:

```yaml
name: Project Board Automation
on:
  issues:
    types: [opened, closed, reopened]
  pull_request:
    types: [opened, closed, reopened, synchronize]

jobs:
  update-board:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/add-to-project@v0.5.0
        with:
          project-url: https://github.com/orgs/hyperpolymath/projects/XX
          github-token: ${{ secrets.PROJECT_PAT }} # PAT with project scope
```

## Current Status (2026-09-18)

- [ ] Board created (pending PAT)
- [ ] Fields created (Status, Method, Risk)
- [ ] Issues created and linked (see 02-deferred-issues.md)
- [ ] PRs linked (feat/analysis-config-v1, feat/clade-cumulus)
- [ ] Automation workflow added

## Local-Only Mode (No PAT)

If PAT not provided, we proceed with:

1. Code on feature branches locally
2. Generate issue bodies as markdown files in `docs/issues/`
3. Prepare GraphQL mutations as above for manual execution when PAT available
4. Milestone reports in `docs/milestones/`

## Security

- PAT must have `repo`, `workflow`, `project` scopes
- Store as `PROJECT_PAT` secret in repo settings, not in code
- Never log PAT in CI output
- Rotate after use if exposed
