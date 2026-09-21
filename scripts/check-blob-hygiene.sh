#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Blob-hygiene guard: stop the 269 MiB of sequencing data from coming back.
#
# History carried 269.35 MiB of packed objects, ~96.6% of it dead weight:
# 163.09 MiB of uncompressed *.fastq, 143.17 MiB under data/VESPA_pool/,
# 71.56 MiB under data/Multiplex_pool/ (which ALSO lived at inputs/fastq/),
# 20.13 MiB under a long-gone web/, and 18.84 MiB across 1,322 node_modules
# blobs. Nothing in the repo prevented any of that, and -- until this file --
# nothing prevented it returning after the rewrite.
#
# ONE implementation, TWO callers: .githooks/pre-commit and the CI
# blob-hygiene step both exec this script. That is deliberate. A hook and a CI
# check that re-implement the same rule drift apart, and the drift is invisible
# because both keep reporting success.
#
# THE PRIMARY RULE IS SIZE, NOT PATH. A path rule can only forbid the paths
# somebody already thought of; the Multiplex pool survived a history rewrite
# precisely because it was reachable under a second path nobody had enumerated.
# Size catches the class. The path rules below are secondary -- they exist to
# produce a better error message, not to be the gate.
#
# Usage:
#   check-blob-hygiene.sh --staged        # pre-commit: what is about to land
#   check-blob-hygiene.sh --tree [ref]    # CI: every tracked file at a ref
set -euo pipefail

# Ceiling: the largest legitimate tracked file is 2,723,348 B (a MiSeq_SOP
# fixture). 4 MiB leaves headroom for a comparable fixture without admitting
# anything of the order that caused the problem -- the dead pools ran to tens
# of MiB per blob.
MAX_BLOB_BYTES=$((4 * 1024 * 1024))

# The six deliberately-whitelisted fixtures (.gitignore:294-304). Matched as a
# glob, so a further fixture in run_A/run_B is admitted while
# data/<anything-else>/*.fastq.gz is not.
ALLOW_GLOB='data/MiSeq_SOP/run_[AB]/*.fastq.gz'

violations=0

fail() {
    printf 'BLOB HYGIENE: %s\n' "$1" >&2
    violations=$((violations + 1))
}

# Every rule, applied to one (path, size) pair. Both modes call exactly this
# function, so neither mode can end up with a filter the other lacks.
check_one() {
    local path="$1" size="$2"

    # shellcheck disable=SC2254
    case "$path" in
        $ALLOW_GLOB) return 0 ;;
    esac

    # 1. Uncompressed sequencing data: 48 blobs, 163.09 MiB, none of which ever
    #    existed in a working tree. Anchored so .gz never matches -- the live
    #    fixtures are compressed and must survive.
    case "$path" in
        *.fastq|*.fq|*.fasta|*.fa|*.sam)
            fail "$path -- uncompressed sequencing data must never be committed (gzip it, or keep it out of the repo)"
            ;;
    esac

    # 2. Paths that have already done this once.
    case "$path" in
        node_modules/*|*/node_modules/*)
            fail "$path -- node_modules was committed once before (1,322 blobs, 18.84 MiB)"
            ;;
        inputs/*|*/inputs/*)
            fail "$path -- inputs/ held a second copy of the Multiplex pool and survived a history rewrite by being reachable under two paths"
            ;;
        logs_*.zip|*/logs_*.zip)
            fail "$path -- committed CI log artefact"
            ;;
    esac

    # 3. The rule that catches what the rules above did not think of.
    if [ "$size" -gt "$MAX_BLOB_BYTES" ]; then
        fail "$path -- $size bytes exceeds the $MAX_BLOB_BYTES byte ceiling"
    fi
}

mode="${1:---staged}"

case "$mode" in
    --staged)
        # Added or modified index entries, NUL-separated so a path containing a
        # space or newline cannot split into two.
        while IFS= read -r -d '' path; do
            blob="$(git ls-files -s -- "$path" | awk '{print $2}')"
            [ -n "$blob" ] || continue
            size="$(git cat-file -s "$blob")"
            check_one "$path" "$size"
        # --no-renames is load-bearing, not a tidy-up. With rename detection on,
        # `git mv pool.fastq other.bin` is one R entry, and --diff-filter=AM drops
        # it -- so an oversized blob already in the index can be moved past this
        # hook without check_one() ever seeing it. --no-renames decomposes the
        # rename into D + A, and the A is examined like any other addition.
        # The --tree mode is immune (it walks the whole tree), which is exactly
        # why the gap was invisible: CI stayed correct while the hook did not.
        done < <(git diff --cached --no-renames --name-only --diff-filter=AM -z)
        ;;
    --tree)
        # Every tracked file at a ref, rather than a commit range. A range needs
        # history CI does not fetch (the hygiene job checks out at depth 2), and
        # the whole tree also catches anything that landed before this guard
        # existed -- which a range, by construction, cannot.
        #
        # Deliberately NOT `git rev-list --objects`: that emits each object once
        # paired with only ONE of the paths it is reachable under, which is
        # exactly how the duplicated pool went unnoticed.
        ref="${2:-HEAD}"
        while IFS= read -r -d '' path; do
            blob="$(git rev-parse --quiet --verify "$ref:$path" 2>/dev/null || true)"
            [ -n "$blob" ] || continue
            size="$(git cat-file -s "$blob")"
            check_one "$path" "$size"
        done < <(git ls-tree -r -z --name-only "$ref")
        ;;
    *)
        echo "usage: $0 --staged | --tree [ref]" >&2
        exit 2
        ;;
esac

if [ "$violations" -gt 0 ]; then
    echo "" >&2
    echo "$violations violation(s). If one is a deliberate fixture, add it to" >&2
    echo "ALLOW_GLOB in scripts/check-blob-hygiene.sh and say why in the commit." >&2
    exit 1
fi

echo "blob hygiene: ok"
