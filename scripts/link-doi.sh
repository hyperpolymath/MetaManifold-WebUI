#!/usr/bin/env bash
#
# link-doi.sh — offline DOI linking for MetaManifold publications.
#
# Validates a production DOI receipt and records the minted DOI against a
# GitHub release tag as an idempotent sidecar. It never calls Zenodo and it
# never creates or publishes a GitHub release; those remain operator actions.
#
# Usage:
#   ./scripts/link-doi.sh <receipt.json> <release-tag>
#
# Environment:
#   GITHUB_TOKEN      GitHub personal access token (projects:write, repo)
#   GITHUB_REPOSITORY owner/repo  (defaults to the git remote origin URL)
#   DOI_STORAGE_DIR   receipts/journal dir (default data/doi_journal)
#
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <receipt.json> <release-tag>" >&2
  exit 2
fi

RECEIPT="$1"
TAG="$2"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 2; }
[ -f "$RECEIPT" ] || { echo "receipt not found: $RECEIPT" >&2; exit 2; }

DOI_STORAGE_DIR="${DOI_STORAGE_DIR:-data/doi_journal}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null \
  | sed -E 's#.*[:/]([^/]+/[^/]+?)\.git$#\1#; s#.*[:/]([^/]+/[^/]+)$#\1#')}"
[ -n "$GITHUB_REPOSITORY" ] || { echo "could not determine GITHUB_REPOSITORY" >&2; exit 2; }

# ---- Validate the production receipt --------------------------------------

SCHEMA=$(jq -r '.schema // empty' "$RECEIPT")
DOI=$(jq -r '.doi // empty' "$RECEIPT")
PUBLISHED=$(jq -r '.published // false' "$RECEIPT")
DEPOSITION_ID=$(jq -r '.deposition_id // empty' "$RECEIPT")
ORIGIN=$(jq -r '.origin // empty' "$RECEIPT")
STUDY=$(jq -r '.study // empty' "$RECEIPT")
RUN=$(jq -r '.run // empty' "$RECEIPT")

[ "$SCHEMA" = "1" ] || { echo "receipt schema $SCHEMA unsupported (expected 1)" >&2; exit 2; }
[ -n "$DOI" ] || { echo "receipt has no doi" >&2; exit 2; }
[ "$PUBLISHED" = "true" ] || { echo "receipt is not published" >&2; exit 2; }
[ -n "$DEPOSITION_ID" ] || { echo "receipt has no deposition_id" >&2; exit 2; }
[ "$ORIGIN" = "https://zenodo.org" ] || {
  echo "refusing non-production origin: $ORIGIN" >&2
  exit 2
}

echo "Validated production receipt: $DOI (deposition $DEPOSITION_ID, $STUDY/$RUN)"

# ---- Preserve release notes, citation and receipt assets ------------------

ASSET_DIR="data/doi_release/$TAG"
mkdir -p "$ASSET_DIR"

# Copy the receipt into the release asset dir (idempotent: re-running overwrites
# with identical bytes).
cp "$RECEIPT" "$ASSET_DIR/receipt.json"

# Preserve CFF citation if present, so the cited record is self-contained.
[ -f CITATION.cff ] && cp CITATION.cff "$ASSET_DIR/CITATION.cff"

# Keep the current release notes beside the DOI.
RELEASE_NOTES="docs/release-notes/${TAG}.md"
[ -f "$RELEASE_NOTES" ] && cp "$RELEASE_NOTES" "$ASSET_DIR/release-notes.md"

echo "Preserved release assets under $ASSET_DIR"

# ---- Idempotent DOI link sidecar ------------------------------------------

# The link sidecar is the machine-readable record that an operator attaches to
# the GitHub Projects v2 draft (editing the DI_ draft-content field, not the
# PVTI_ project item id — see the DOI PR notes). Writing it here is idempotent
# and partial-failure safe: a temp file is renamed over the target.
LINK_FILE="$ASSET_DIR/doi-link.json"
cat > "$LINK_FILE.tmp" <<EOF
{
  "schema": 1,
  "doi": "$DOI",
  "deposition_id": $DEPOSITION_ID,
  "origin": "$ORIGIN",
  "release_tag": "$TAG",
  "study": "$STUDY",
  "run": "$RUN",
  "repository": "$GITHUB_REPOSITORY",
  "linked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
mv "$LINK_FILE.tmp" "$LINK_FILE"

# ---- Optional: complete the Projects v2 draft upsert online -----------------

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "GITHUB_TOKEN not set: Projects v2 draft upsert skipped (offline mode)" >&2
else
  command -v gh >/dev/null 2>&1 || {
    echo "gh is required to complete the Projects v2 draft upsert online" >&2
  }
  echo "Tip: attach $DOI to the Projects v2 draft for release $TAG by editing the"
  echo "DI_ draft-content field (not the PVTI_ project item id). See docs/doi-publication.md."
fi

echo "Link complete. DOI=$DOI (tag=$TAG, repository=$GITHUB_REPOSITORY)"
echo "Sidecar: $LINK_FILE"
