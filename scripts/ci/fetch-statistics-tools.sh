#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Install the pinned tools the statistics standards job needs.
#
# Every version is a literal in this file and every download is verified:
#   - yq is pinned by release tag and by the SHA-256 GitHub publishes for that
#     exact asset, and curl is restricted to HTTPS both for the request and for
#     any redirect it follows (--proto-redir), so a 302 cannot downgrade it.
#   - the standards and ijson-jcs checkers are fetched at an exact commit, not a
#     branch, so a change in either checker arrives as a reviewable bump.
#
# Usage: scripts/ci/fetch-statistics-tools.sh
# Requires: curl, git, cargo (all present on the ubuntu-24.04 runner image).
# Writes the tools under $RUNNER_TEMP and appends their directories to
# $GITHUB_PATH when that variable is set.

set -euo pipefail

YQ_VERSION="v4.53.3"
YQ_SHA256="fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4"
STANDARDS_SHA="c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d"
IJSON_JCS_SHA="3a9a4ee326a968a32b2f152b4faec243a2d00765"

temp="${RUNNER_TEMP:-$(mktemp -d)}"
mkdir -p "$temp/bin"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$temp/bin" >> "$GITHUB_PATH"
fi

# Same retry policy as scripts/ci/fetch_pinned.sh: --retry alone skips TLS and
# receive failures, and a release-asset fetch can also fail with an HTTP status
# (curl exit 22) while GitHub is serving a 5xx or throttling, so the retry has
# to cover every error class. The checksum below is what makes the retry safe.
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --retry 4 --retry-delay 5 --retry-all-errors \
  --connect-timeout 20 --max-time 600 \
  --output "$temp/bin/yq" \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"

printf '%s  %s\n' "$YQ_SHA256" "$temp/bin/yq" | sha256sum -c -
chmod 0755 "$temp/bin/yq"
export PATH="$temp/bin:$PATH"

# Fetch exactly one commit. `git init` + `fetch <sha>` makes the requested
# revision explicit; a clone would resolve whatever the remote branch happened
# to be at run time.
fetch_commit() {
  local repository="$1" commit="$2" destination="$3"
  git init --quiet "$destination"
  git -C "$destination" remote add origin "$repository"
  git -C "$destination" -c protocol.version=2 fetch --quiet --depth 1 origin "$commit"
  git -C "$destination" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]]
}

# The canonical name, not the pre-transfer one. A `git fetch` follows a
# transfer's redirect (that is why this kept working after 2026-10-25 while
# `uses:` references to the same repository did not), but a redirect is a
# courtesy, not a contract: the estate records canonical coordinates, and the
# governance contract already refuses the old owner in workflow refs. The
# commit is unchanged — only the name used to reach it.
fetch_commit https://github.com/metadatastician/standards "$STANDARDS_SHA" "$temp/standards"
fetch_commit https://github.com/hyperpolymath/ijson-jcs "$IJSON_JCS_SHA" "$temp/ijson-jcs"

cargo build --quiet --release --manifest-path "$temp/ijson-jcs/Cargo.toml"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$temp/ijson-jcs/target/release" >> "$GITHUB_PATH"
fi

"$temp/bin/yq" --version
"$temp/ijson-jcs/target/release/ijson-jcs" --help >/dev/null
echo "fetch-statistics-tools: yq ${YQ_VERSION}, standards ${STANDARDS_SHA}, ijson-jcs ${IJSON_JCS_SHA}"
