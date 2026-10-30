#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Refuse newly added/modified Python source and manifests. Untouched inherited
# debt is not a blanket authorisation to add more. Deletion is allowed.
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ ^[0-9a-fA-F]{40}$ ]]; then
  printf 'Usage: %s <base-commit-sha>\n' "$0" >&2
  exit 2
fi
base=$1
if ! git cat-file -e "${base}^{commit}"; then
  echo 'Base commit unavailable; no language-policy evidence' >&2
  exit 2
fi
changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
if ! git diff --name-only --diff-filter=ACMR -z "${base}...HEAD" -- > "$changed"; then
  echo 'Cannot determine changed files; refusing a false green' >&2
  exit 2
fi
bad=0
while IFS= read -r -d '' file; do
  case "${file##*/}" in
    *.py|*.pyi|pyproject.toml|Pipfile|Pipfile.lock|poetry.lock|uv.lock|.python-version|setup.cfg|tox.ini|pytest.ini|requirements*.txt|requirements*.in)
      printf 'BANNED Python contribution: %q\n' "$file" >&2
      bad=1 ;;
  esac
done < "$changed"
if (( bad )); then
  echo 'Python is banned for new work; migrate to approved languages. Removal-only cleanup is allowed.' >&2
  echo 'Canon: metadatastician/standards/3-practice/LANGUAGE-POLICY.adoc section 3' >&2
  exit 1
fi
echo 'Language policy PASS: no new or modified Python files/manifests in this diff; legacy untouched files are not certified.'
