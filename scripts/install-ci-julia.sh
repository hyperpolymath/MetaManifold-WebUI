#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Install the committed Linux x86-64 runtime after verifying its archive checksum.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
pins=config/defaults/tool_versions.yml
version=$(awk '/^runtimes:/ {r=1;next} r && /^  julia:/ {j=1;next} j && /^    version:/ {gsub(/"/,"",$2);print $2;exit}' "$pins")
# Print the requested field from the Julia linux-x86_64 pin to stdout.
# Arguments: $1 is the field name (url or sha256); missing fields print nothing.
field() {
    awk -v key="$1" '
        /^runtimes:/ {r=1;next}
        r && /^[^ #]/ {r=0}
        r && /^  julia:/ {j=1;next}
        j && /^  [^ ]/ {j=0}
        j && $1 == "linux-x86_64:" {p=1;next}
        p && /^      [^ ]/ {p=0}
        p && $1 == key ":" {gsub(/"/,"",$2);print $2;exit}
    ' "$pins"
}
url=$(field url)
sha=$(field sha256)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$sha" =~ ^[0-9a-f]{64}$ && "$url" == https://* ]] || { echo 'Invalid Julia runtime pin' >&2; exit 1; }
if [[ "${1:-}" == --print-pin ]]; then printf '%s\n' "$version" "$url" "$sha"; exit; fi
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'This CI installer requires Linux x86-64' >&2; exit 1; }
: "${RUNNER_TEMP:?}" "${GITHUB_PATH:?}"
archive=$(mktemp "$RUNNER_TEMP/julia.XXXXXX.tar.gz")
trap 'rm -f "$archive"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 "$url" -o "$archive"
printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
tar --no-same-owner -xzf "$archive" -C "$RUNNER_TEMP"
"$RUNNER_TEMP/julia-$version/bin/julia" --version
printf '%s\n' "$RUNNER_TEMP/julia-$version/bin" >> "$GITHUB_PATH"
