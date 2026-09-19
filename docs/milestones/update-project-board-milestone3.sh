#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Update Project board "Analysis Layer & Cladistics Development" for Milestone 3
# Requires GITHUB_TOKEN with scopes: repo, workflow, project, org:write (if org project)
# Board URL: https://github.com/users/hyperpolymath/projects/45 (user project) or org project if migrated

set -euo pipefail

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN not set. Create PAT with scopes repo, workflow, project, org:write" >&2
  echo "Go to https://github.com/settings/tokens/new with:" >&2
  echo "  - repo (Full control of private repositories)" >&2
  echo "  - workflow (Update GitHub Action workflows)" >&2
  echo "  - project (Full control of projects) — required for ProjectV2 GraphQL" >&2
  echo "  - org:write (if board is under hyperpolymath org, to write org projects)" >&2
  echo "  - read:org (to read org membership)" >&2
  echo "Then export GITHUB_TOKEN=<your PAT> and re-run this script." >&2
  exit 1
fi

REPO="hyperpolymath/MetaManifold-WebUI"
PROJECT_URL="https://github.com/users/hyperpolymath/projects/45"
PROJECT_ID="" # Will be fetched via GraphQL

echo "=== PAT Requirements ==="
echo "Token must have:"
echo "  - repo: to create issues, push branches, open PRs"
echo "  - workflow: to update .github/workflows/project-board.yml"
echo "  - project: to mutate ProjectV2 via GraphQL (create fields, add items, update status)"
echo "  - org:write: if board is under hyperpolymath org (for org-level ProjectV2)"
echo "  - read:org: to query org ID"
echo "Create at https://github.com/settings/tokens/new or https://github.com/settings/tokens/new?scopes=repo,workflow,project,write:org,read:org"
echo "Classic PAT needs repo, workflow, write:org, read:org, project (if available)."
echo "Fine-grained PAT needs Repository access: All repositories or at least MetaManifold-WebUI, with Contents: Read and write, Metadata: Read, Pull requests: Read and write, Workflows: Read and write, and Organization permissions: Projects: Read and write, Administration: Read and write (for org projects), or User: Projects: Read and write for user projects."
echo ""

# Helper to run GraphQL
graphql() {
  local query="$1"
  curl -s -H "Authorization: bearer $GITHUB_TOKEN" -H "Content-Type: application/json" \
    -d "{\"query\": $(echo "$query" | jq -Rs .)}" https://api.github.com/graphql
}

echo "=== Fetching viewer ID (for user project) ==="
VIEWER_QUERY='query { viewer { id login } }'
VIEWER_RESP=$(graphql "$VIEWER_QUERY")
echo "$VIEWER_RESP" | jq .

echo "=== Fetching org ID (if org project) ==="
ORG_QUERY='query { organization(login: "hyperpolymath") { id login } }'
ORG_RESP=$(graphql "$ORG_QUERY")
echo "$ORG_RESP" | jq .

echo "=== Fetching project ID for $PROJECT_URL ==="
# For user project 45, we need to list projects for user hyperpolymath
PROJECTS_QUERY='query { user(login: "hyperpolymath") { projectsV2(first: 20) { nodes { id title url number } } } }'
PROJECTS_RESP=$(graphql "$PROJECTS_QUERY")
echo "$PROJECTS_RESP" | jq .

# Try to extract project ID for number 45
PROJECT_ID=$(echo "$PROJECTS_RESP" | jq -r '.data.user.projectsV2.nodes[] | select(.number==45) | .id')
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
  echo "WARNING: Could not find project number 45 for user hyperpolymath, trying org..."
  ORG_PROJECTS_QUERY='query { organization(login: "hyperpolymath") { projectsV2(first: 20) { nodes { id title url number } } } }'
  ORG_PROJECTS_RESP=$(graphql "$ORG_PROJECTS_QUERY")
  echo "$ORG_PROJECTS_RESP" | jq .
  PROJECT_ID=$(echo "$ORG_PROJECTS_RESP" | jq -r '.data.organization.projectsV2.nodes[] | select(.number==45) | .id')
fi

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
  echo "ERROR: Could not find project ID for $PROJECT_URL. Please check URL and ensure token has project scope." >&2
  echo "You can manually set PROJECT_ID env var and re-run." >&2
  exit 1
fi

echo "Found PROJECT_ID=$PROJECT_ID"

echo "=== Creating issues from docs/issues/milestone3/*.md ==="
for issue_file in docs/issues/milestone3/*.md; do
  [[ "$issue_file" == *"README.md" ]] && continue
  echo "--- Processing $issue_file ---"
  # Extract title: first line after **Title:**
  TITLE=$(grep -m1 "^\*\*Title:\*\*" "$issue_file" | sed -E 's/.*`([^`]+)`.*/\1/' || echo "feat(analysis): $(basename $issue_file .md)")
  # Extract labels
  LABELS=$(grep -m1 "^\*\*Labels:\*\*" "$issue_file" | sed -E 's/\*\*Labels:\*\* //' || echo "enhancement,analysis,deferred")
  # Body is everything after **Body:**
  BODY=$(awk '/^\*\*Body:\*\*/{flag=1; next} flag' "$issue_file")

  echo "Title: $TITLE"
  echo "Labels: $LABELS"
  # Create issue via REST
  echo "$BODY" > /tmp/issue_body.md
  # Use gh api if available, else curl
  if command -v gh >/dev/null 2>&1; then
    gh issue create --repo "$REPO" --title "$TITLE" --body-file /tmp/issue_body.md --label "$LABELS" || true
  else
    # REST API
    ISSUE_RESP=$(curl -s -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/json" \
      -d "{\"title\": $(echo "$TITLE" | jq -Rs .), \"body\": $(cat /tmp/issue_body.md | jq -Rs .), \"labels\": [$(echo "$LABELS" | tr ',' '\n' | jq -R . | paste -sd, -)]}" \
      https://api.github.com/repos/$REPO/issues)
    echo "$ISSUE_RESP" | jq .
    ISSUE_NODE_ID=$(echo "$ISSUE_RESP" | jq -r .node_id)
    ISSUE_NUMBER=$(echo "$ISSUE_RESP" | jq -r .number)
    if [[ -n "$ISSUE_NODE_ID" && "$ISSUE_NODE_ID" != "null" ]]; then
      echo "Created issue #$ISSUE_NUMBER node_id $ISSUE_NODE_ID"
      # Add to project
      ADD_MUTATION="mutation { addProjectV2ItemById(input: { projectId: \"$PROJECT_ID\", contentId: \"$ISSUE_NODE_ID\" }) { item { id } } }"
      ADD_RESP=$(graphql "$ADD_MUTATION")
      echo "$ADD_RESP" | jq .
    fi
  fi
done

echo "=== Done. Board should now have 6 new issues for Milestone 3 deferred features ==="
echo "Next: Update board status for PR feat/milestone3-analysis-config to Review, then Done after merge."
echo "To update status, use GraphQL mutation updateProjectV2ItemFieldValue with fieldId for Status and optionId for Review/Done."
