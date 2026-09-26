#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Link an already-published DOI to GitHub. This script NEVER talks to Zenodo or
# publishes a release. Dry-run by default; uses gh's existing authentication.
set -euo pipefail

usage() {
    printf '%s\n' 'Usage: scripts/link-doi.sh --receipt publication-ID.json [--apply]' \
        'Without --apply: validate and print a plan, with no network calls.' \
        'With --apply: update the existing release notes, upload citation/receipt' \
        'assets, and create/update one marked draft item on the optional project.'
}
fail() { printf 'link-doi: %s\n' "$*" >&2; exit 1; }
receipt='' apply=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --receipt) [[ $# -ge 2 ]] || fail '--receipt needs a path'; receipt="$2"; shift 2 ;;
        --apply) apply=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail 'unknown argument' ;;
    esac
done
[[ -f "$receipt" && ! -L "$receipt" ]] || fail 'provide a regular publication receipt file'
command -v jq >/dev/null || fail 'jq is required'
[[ $(wc -c < "$receipt") -le 1048576 ]] || fail 'receipt exceeds 1 MiB'
# Validate before invoking gh. Unknown/unpublished/sandbox receipts are never
# turned into a production citation, even when the caller uses --apply.
jq -e '
  .schema_version == "1.0.0" and .state == "published" and
  .environment == "production" and .test_record == false and
  (.id | type == "string" and test("^[0-9a-f]{64}$")) and
  (.bundle_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.binding.config_hash | type == "string" and test("^[0-9a-f]{64}$")) and
  (.doi | type == "string" and test("^10\\.5281/zenodo\\.[1-9][0-9]*$")) and
  .reserved_doi == .doi and .doi_url == ("https://doi.org/" + .doi) and
  (.metadata.title | type == "string" and length > 0 and length <= 250) and
  (.binding.kind | . == "configuration" or . == "analysis_result") and
  (.binding.dangerous | type == "boolean") and
  (.metadata.creators | type == "array" and length > 0 and length <= 100 and
    all(.[]; (.name | type == "string" and length > 0 and length <= 500) and
      ((.orcid == null) or (.orcid | type == "string" and test("^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$"))))) and
  (.metadata.publication_date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
  (.metadata.version | type == "string" and length > 0) and
  (.metadata.license | . == "CC-BY-4.0" or . == "CC-BY-SA-4.0" or . == "CC0-1.0") and
  (.metadata.github_release_url | type == "string" and
    test("^https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+/releases/tag/[A-Za-z0-9_.~+/-]+$")) and
  ((.metadata.github_project_url == null) or
    (.metadata.github_project_url | type == "string" and
      test("^https://github\\.com/(users|orgs)/[A-Za-z0-9][A-Za-z0-9-]*/projects/[1-9][0-9]*$")))
' "$receipt" >/dev/null || fail 'receipt must describe a verified production publication with valid GitHub links'

id=$(jq -r '.id' "$receipt")
doi=$(jq -r '.doi' "$receipt")
release=$(jq -r '.metadata.github_release_url' "$receipt")
project=$(jq -r '.metadata.github_project_url // empty' "$receipt")
relative=${release#https://github.com/}
repo=${relative%%/releases/tag/*}
tag=${relative#*/releases/tag/}
[[ "/$tag/" != *'/../'* && "/$tag/" != *'/./'* ]] || fail 'release tag contains a traversal segment'
marker="<!-- metamanifold-doi:$id -->"
endmarker="<!-- /metamanifold-doi:$id -->"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Treat user-authored titles as text, not as release-note control markers.
title=$(jq -r '.metadata.title' "$receipt" | tr '\r\n' '  ' | sed 's/[][\\`*_<>#]/\\&/g')
{
    printf '%s\n\n' "$marker"
    printf '### MetaManifold analysis citation\n\n%s\n\n' "$title"
    printf '**DOI:** [%s](https://doi.org/%s)\n\n' "$doi" "$doi"
    printf '**Payload:** %s\n\n' "$(jq -r 'if .binding.kind == "configuration" then "Configuration only — no analysis results" else "Configuration and selected analysis result" end' "$receipt")"
    printf '**Archive SHA-256:** `%s`\n\n' "$(jq -r '.bundle_sha256' "$receipt")"
    printf '**Config SHA-256:** `%s`\n\n' "$(jq -r '.binding.config_hash' "$receipt")"
    if jq -e '.binding.dangerous == true' "$receipt" >/dev/null; then
        printf '**DANGER:** Scientific overrides are present. Preserve and disclose the archived warning.\n\n'
    fi
    printf 'See the attached `publication-%s.json` receipt and `citation-%s.cff`.\n\n' "$id" "$id"
    printf '%s\n' "$endmarker"
} > "$tmp/block.md"

printf 'Release: %s\nDOI: https://doi.org/%s\n' "$release" "$doi"
[[ -z "$project" ]] || printf 'Project: %s (one marked draft item)\n' "$project"
if ! $apply; then
    printf '\nDRY RUN — no GitHub writes or network calls. Proposed managed block:\n\n'
    cat "$tmp/block.md"
    printf '\nReview the receipt and rerun with --apply to link it. No DOI will be minted.\n'
    exit 0
fi
command -v gh >/dev/null || fail 'GitHub CLI (gh) is required for --apply'
command -v flock >/dev/null || fail 'flock is required to serialize local linking of this receipt'
if [[ -n "$project" ]]; then
    gh project --help >/dev/null 2>&1 || fail 'Projects v2 linking requires a gh version with project commands (2.32 or newer)'
fi
# The receipt is an immutable operator-owned file. Multiple --apply invocations
# for it must not race each other. Do not run independent release-note writers
# concurrently; GitHub release edits do not provide a cross-machine transaction.
exec 9< "$receipt"
flock -n 9 || fail 'another linker is using this receipt'

gh_safe() {
    if ! gh "$@" 2> "$tmp/gh-error"; then
        fail 'GitHub operation failed. Check the GitHub connection/permissions and retry this same receipt; do not mint another DOI. No credentials or raw errors are printed.'
    fi
}

gh_safe release view --repo "$repo" --json body,url,isDraft -- "$tag" > "$tmp/release.json"
jq -e --arg url "$release" '.url == $url and .isDraft == false' "$tmp/release.json" >/dev/null || fail 'release must already exist and be published at the exact recorded URL'
jq -r '.body // ""' "$tmp/release.json" > "$tmp/old-notes.md"
starts=$(grep -Fxc "$marker" "$tmp/old-notes.md" || true)
ends=$(grep -Fxc "$endmarker" "$tmp/old-notes.md" || true)
[[ "$starts" == "$ends" && ( "$starts" == 0 || "$starts" == 1 ) ]] || fail 'release notes contain ambiguous managed markers; repair them manually'
awk -v start="$marker" -v end="$endmarker" -v block="$tmp/block.md" '
    function emit( line) { while ((getline line < block) > 0) print line; close(block) }
    $0 == start { inside=1; seen=1; emit(); next }
    $0 == end { if (!inside) exit 2; inside=0; next }
    !inside { print }
    END { if (inside) exit 2; if (!seen) { print ""; emit() } }
' "$tmp/old-notes.md" > "$tmp/notes.md" || fail 'managed release-note block is malformed'
# Skip the PATCH on an exact replay, preserving unrelated notes.
if ! cmp -s "$tmp/old-notes.md" "$tmp/notes.md"; then
    gh_safe release edit --repo "$repo" --notes-file "$tmp/notes.md" -- "$tag" >/dev/null
fi
cp "$receipt" "$tmp/publication-$id.json"
jq -r '
  "cff-version: 1.2.0\nmessage: \"Please cite this published analysis dataset.\"\ntype: dataset\n" +
  "title: " + (.metadata.title|tojson) + "\n" +
  "doi: " + (.doi|tojson) + "\nversion: " + (.metadata.version|tojson) + "\n" +
  "date-released: " + (.metadata.publication_date|tojson) + "\n" +
  "license: " + (.metadata.license|tojson) + "\nauthors:\n" +
  ([.metadata.creators[] | "  - name: " + (.name|tojson) +
    (if .orcid then "\n    orcid: " + (("https://orcid.org/" + .orcid)|tojson) else "" end)] | join("\n"))
' "$receipt" > "$tmp/citation-$id.cff"
gh_safe release upload --repo "$repo" --clobber -- "$tag" "$tmp/publication-$id.json" "$tmp/citation-$id.cff" >/dev/null

if [[ -n "$project" ]]; then
    owner=$(printf '%s' "$project" | cut -d/ -f5)
    number=${project##*/}
    gh_safe project item-list "$number" --owner "$owner" --limit 10000 --format json > "$tmp/items.json"
    jq -e '(.items | type == "array") and (.totalCount | type == "number" and . >= 0 and . == floor) and (.totalCount == (.items|length))' "$tmp/items.json" >/dev/null ||
        fail 'project listing was incomplete; refusing to create a potentially duplicate item'
    jq --arg marker "$marker" '[.items[] | select((.body // .content.body // "") | contains($marker))]' "$tmp/items.json" > "$tmp/matches.json"
    matches=$(jq 'length' "$tmp/matches.json")
    [[ "$matches" -le 1 ]] || fail 'project has duplicate publication markers; reconcile them manually'
    { cat "$tmp/block.md"; printf '\nGitHub release: %s\n' "$release"; } > "$tmp/project-body.md"
    if [[ "$matches" == 0 ]]; then
        gh_safe project item-create "$number" --owner "$owner" --title "MetaManifold DOI: $doi" --body "$(cat "$tmp/project-body.md")" --format json >/dev/null
    else
        # Editing a draft uses its DI_ content ID, NOT the PVTI_ project item ID.
        item=$(jq -r '.[0] | select(.content.type == "DraftIssue") | .content.id // empty' "$tmp/matches.json")
        [[ "$item" =~ ^DI_[A-Za-z0-9_-]+$ ]] || fail 'marked project item must be a draft issue with a valid content identifier'
        gh_safe project item-edit --id "$item" --title "MetaManifold DOI: $doi" --body "$(cat "$tmp/project-body.md")" >/dev/null
    fi
fi
printf 'Linked existing DOI %s to the release%s. No DOI or release was created.\n' "$doi" "${project:+ and project}"
