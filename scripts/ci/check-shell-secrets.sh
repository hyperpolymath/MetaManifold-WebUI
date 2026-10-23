#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Apply the same literal-assignment rules to the working tree and every unique
# historical shell blob. Never print matching source or credential values.
set -euo pipefail
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
patterns=(
  "(export[[:space:]]+)?[A-Z_]*TOKEN[A-Z_]*=[\"'][A-Za-z0-9_./+=-]{20,}[\"']"
  "(export[[:space:]]+)?[A-Z_]*API_KEY[A-Z_]*=[\"'][A-Za-z0-9_./+=-]{20,}[\"']"
  "(export[[:space:]]+)?[A-Z_]*SECRET[A-Z_]*=[\"'][A-Za-z0-9_./+=-]{16,}[\"']"
  "(export[[:space:]]+)?PASSWORD=[\"'][^\"']{6,}[\"']"
)
pragma='(scanner-allow:[[:space:]]*shell-secrets|hypatia:[[:space:]]*allow[[:space:]]+security_errors/secret_detected)'
parameter_rhs=$(cat <<'REGEX'
=["']?\$\{?[A-Za-z_][A-Za-z0-9_]*(:[?-][^}]*)?\}?["']?[[:space:]]*(#.*)?$
REGEX
)
ignore=()
if [ -f .shell-secrets-ignore ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" == \#* ]] || ignore+=("$line")
  done < .shell-secrets-ignore
fi
ignored() {
  local path=${1#./} glob
  for glob in "${ignore[@]}"; do [[ "$path" == $glob ]] && return 0; done
  return 1
}
found=0
scan_file() {
  local file=$1 path=$2 revision=$3 pattern rc line number content source_line previous
  ignored "$path" && return 0
  for pattern in "${patterns[@]}"; do
    rc=0
    grep -noE "$pattern" "$file" > "$scratch/matches" || rc=$?
    if [ "$rc" -gt 1 ]; then echo 'ERROR: shell-secret matcher failed' >&2; return "$rc"; fi
    while IFS= read -r line; do
      number=${line%%:*}; content=${line#*:}
      # PASSWORD allows arbitrary characters, including variable-only RHSs.
      [[ "$content" =~ $parameter_rhs ]] && continue
      # Check exemptions against each assignment separately; a variable on
      # one side of `;` cannot hide a literal credential later on the line.
      source_line=$(sed -n "${number}p" "$file")
      [[ "$source_line" =~ ^[[:space:]]*# ]] && continue
      [[ "$source_line" =~ $pragma ]] && continue
      if [ "$number" -gt 1 ]; then
        previous=$(sed -n "$((number - 1))p" "$file")
        [[ "$previous" =~ $pragma ]] && continue
      fi
      printf 'Potential shell credential at %q:%s (revision %s; content redacted)\n' "$path" "$number" "$revision"
      found=1
    done < "$scratch/matches"
  done
}
find . -type d \( -name .git -o -name node_modules -o -name target \) -prune -o \
  -type f \( -name '*.sh' -o -name '*.bash' \) -print0 > "$scratch/files"
while IFS= read -r -d '' path; do scan_file "$path" "$path" working-tree; done < "$scratch/files"
if [ "$(git rev-parse --is-shallow-repository)" != false ]; then
  echo 'ERROR: refusing a shallow custom shell-history scan' >&2
  exit 1
fi
git rev-list HEAD > "$scratch/commits"
declare -A seen=()
while IFS= read -r revision; do
  git ls-tree -r -z "$revision" > "$scratch/tree"
  while IFS= read -r -d '' entry; do
    header=${entry%%$'\t'*}; path=${entry#*$'\t'}
    read -r mode type oid <<< "$header"
    [ "$type" = blob ] || continue
    case "$path" in *.sh|*.bash) ;; *) continue ;; esac
    case "/$path/" in */node_modules/*|*/target/*) continue ;; esac
    key="$oid:$path"
    [ -z "${seen[$key]+x}" ] || continue
    seen[$key]=1
    git cat-file blob "$oid" > "$scratch/blob"
    scan_file "$scratch/blob" "$path" "$revision"
  done < "$scratch/tree"
done < "$scratch/commits"
if [ "$found" -ne 0 ]; then
  echo 'ERROR: hardcoded shell credentials detected; use environment variables.' >&2
  exit 1
fi
echo 'No hardcoded shell credentials found in the working tree or Git history.'
