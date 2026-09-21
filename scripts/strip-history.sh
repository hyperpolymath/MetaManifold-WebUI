#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ═══════════════════════════════════════════════════════════════════════════
#  PREPARED, NOT RUN. This script rewrites every commit in the repository.
# ═══════════════════════════════════════════════════════════════════════════
#
# It refuses to do anything unless passed --i-have-read-the-warnings, and it
# never pushes. The force-push is left as a separate, deliberate human step,
# printed at the end.
#
# ── WHY ────────────────────────────────────────────────────────────────────
# .git is 269.35 MiB of a 282 MB checkout; the working tree is ~12 MB.
# `git count-objects -vH` reports prune-packable 0 and garbage 0, so `git gc`
# reclaims none of it: the blobs are still reachable from history. Every clone
# pays this forever.
#
# ── WHAT IS ACTUALLY IN THERE (measured 2026-09-21, not estimated) ─────────
# Aggregate blob bytes across all refs, by path:
#
#     170.80 MiB    54 blobs  data/MiSeq_SOP/       ← SPLIT, see below
#     143.17 MiB     6 blobs  data/VESPA_pool/      ← dead, deleted from tree
#      71.56 MiB     2 blobs  data/Multiplex_pool/  ← dead, deleted from tree
#      20.13 MiB    29 blobs  web/                  ← dead, directory gone
#      18.84 MiB  1322 blobs  **/node_modules/      ← dead, was once committed
#      13.67 MiB  1381 blobs  everything else       ← the actual repository
#
# data/MiSeq_SOP/ splits cleanly and must NOT be stripped wholesale:
#
#     163.09 MiB    48 blobs  *.fastq     uncompressed — 0 present in the tree
#       7.71 MiB     6 blobs  *.fastq.gz  LIVE test fixtures, deliberately
#                                         re-whitelisted in .gitignore:294-304
#
# So the strip set below is uncompressed *.fastq only, never *.fastq.gz.
#
# Removing all five classes drops ~416.79 MiB of blob content and leaves
# ~21.4 MiB — the 13.67 MiB of real repository plus the 7.71 MiB of live
# fixtures.
#
# ⚠ Two corrections to the earlier recon, both found by measuring:
#   1. data/MiSeq_SOP/*.fastq (163 MiB) is the SINGLE LARGEST item and was not
#      in the original strip set. Stripping only the two pools would have left
#      the biggest offender in place.
#   2. The recon said "nothing junk is committed — no node_modules". That is
#      true of the WORKING TREE and false of HISTORY: 1,322 node_modules blobs
#      are reachable.
#
# ── THE THREE THINGS THIS BREAKS ───────────────────────────────────────────
# 1. IRREVERSIBLE. Every commit hash in the repository changes.
# 2. It rewrites the head of an OPEN UPSTREAM PULL REQUEST. This fork's `main`
#    IS the head branch of JoshuaJewell/MetaManifold-WebUI#6 (verified: same
#    head sha). Force-pushing main force-pushes somebody else's open PR, and
#    its review history will no longer refer to commits that exist.
# 3. Every existing clone and worktree becomes unmergeable and must be
#    re-cloned. Anyone with work in flight loses their base.
#
# Because of (2) this is a COORDINATED operation. Tell the upstream owner
# before, not after.
#
# ── TOOLING ────────────────────────────────────────────────────────────────
# git-filter-repo is NOT currently installed on this machine (checked). It is
# the only correct tool for this: git filter-branch is deprecated, ~100x
# slower, and mangles tags and merges. Install first:
#
#     pipx install git-filter-repo
#
# (git-filter-repo is a single-file Python program. That is a local toolchain
# install, not estate source code — it introduces no Python into any repo.)
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#     scripts/strip-history.sh --i-have-read-the-warnings [/path/to/scratch]
#
# Operates on a FRESH CLONE in a scratch directory and leaves your working
# clone untouched, so you can inspect the result before deciding anything.
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

if [ "${1:-}" != "--i-have-read-the-warnings" ]; then
  sed -n '5,76p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "REFUSING TO RUN. Re-invoke with --i-have-read-the-warnings to proceed."
  exit 1
fi

SCRATCH="${2:-${CLAUDE_JOB_DIR:-/tmp}/history-rewrite}"
ORIGIN_URL="https://github.com/hyperpolymath/MetaManifold-WebUI.git"
WORK="$SCRATCH/MetaManifold-WebUI"

command -v git-filter-repo >/dev/null 2>&1 || {
  echo "git-filter-repo is not installed. Run: pipx install git-filter-repo" >&2
  exit 1
}

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

echo "==> Fresh mirror-style clone into $WORK"
git clone --no-local "$ORIGIN_URL" "$WORK"
cd "$WORK"

echo "==> BEFORE"
git count-objects -vH | sed 's/^/    /'
BEFORE_HEAD="$(git rev-parse HEAD)"
BEFORE_TREE="$(git rev-parse HEAD^{tree})"

echo "==> Rewriting"
# --invert-paths: everything listed is REMOVED, everything else is kept.
# The regex for MiSeq_SOP ends in \.fastq$ so *.fastq.gz never matches, which
# is what preserves the live fixtures.
git filter-repo --force --invert-paths \
  --path      'data/VESPA_pool' \
  --path      'data/Multiplex_pool' \
  --path      'web' \
  --path      'inputs' \
  --path-glob 'logs_*.zip' \
  --path-regex '^data/MiSeq_SOP/.*\.fastq$' \
  --path-regex '(^|/)node_modules/'

echo "==> Repacking"
git reflog expire --expire=now --all
git gc --prune=now --aggressive

echo "==> AFTER"
git count-objects -vH | sed 's/^/    /'

echo
echo "==> Verification"
printf '    live fixtures still present (expect 6): %s\n' \
  "$(git rev-list --objects --all | grep -c 'data/MiSeq_SOP/.*\.fastq\.gz' || true)"
printf '    uncompressed fastq remaining (expect 0): %s\n' \
  "$(git rev-list --objects --all | grep -cE 'data/MiSeq_SOP/.*\.fastq$' || true)"
printf '    VESPA/Multiplex blobs remaining (expect 0): %s\n' \
  "$(git rev-list --objects --all | grep -cE 'data/(VESPA|Multiplex)_pool/' || true)"
printf '    node_modules blobs remaining (expect 0): %s\n' \
  "$(git rev-list --objects --all | grep -c 'node_modules/' || true)"
printf '    commit count: %s\n' "$(git rev-list --count --all)"
printf '    HEAD was %s, is now %s\n' "$BEFORE_HEAD" "$(git rev-parse HEAD)"
AFTER_TREE="$(git rev-parse HEAD^{tree})"
if [ "$BEFORE_TREE" = "$AFTER_TREE" ]; then
  printf '    HEAD tree identical to pre-rewrite: same (%s)\n' "$AFTER_TREE"
else
  printf '    HEAD tree CHANGED: %s -> %s\n' "$BEFORE_TREE" "$AFTER_TREE"
  echo "    ^^ STOP, DO NOT PUSH. Every stripped path is already absent from"
  echo "       HEAD, so the checked-out tree MUST be byte-identical. A change"
  echo "       here means the strip set caught a LIVE file."
fi
echo "    run the test suite in $WORK before believing any of this."

# A path-based strip CANNOT prove a blob is gone: the same blob can be reachable
# under a SECOND path, and `git rev-list --objects` names each object exactly
# once, so the census that chose the strip set credits it to one path only.
# Measured 2026-09-21: stripping data/Multiplex_pool left its 71.58 MiB intact
# under inputs/fastq/, and the pre-rewrite listing never mentioned inputs/ at
# all. The named checks above all passed while 71 MiB survived. So print what
# actually REMAINS and read it -- an unexpected heavy path here is the tell.
echo
echo "    heaviest paths REMAINING (read this; do not trust the checks above alone):"
git rev-list --objects --all \
 | git cat-file --batch-check='%(objecttype) %(objectsize:disk) %(rest)' \
 | awk '$1=="blob" && $3!="" {
     n=split($3,a,"/"); k=(n>=2 ? a[1]"/"a[2] : a[1]); s[k]+=$2; c[k]++
   }
   END { for (k in s) printf "      %10.2f MiB %6d  %s\n", s[k]/1048576, c[k], k }' \
 | sort -rn | head -8

cat <<'NEXT'

═══════════════════════════════════════════════════════════════════════════
NOTHING HAS BEEN PUSHED. The rewritten history exists only in the scratch
clone above.

To publish it — and only after telling the upstream owner, because this
force-pushes the head of JoshuaJewell/MetaManifold-WebUI#6:

    cd <scratch>/MetaManifold-WebUI
    git remote add origin https://github.com/hyperpolymath/MetaManifold-WebUI.git
    git push --force --all origin
    git push --force --tags origin

Then every other clone must be discarded and re-cloned. There is no
`git pull` that recovers from this.

To prevent a recurrence, land this in .gitattributes BEFORE pushing:

    *.fastq    filter=lfs diff=lfs merge=lfs -text
    *.fastq.gz filter=lfs diff=lfs merge=lfs -text

or add a pre-receive/pre-commit size cap. Nothing currently stops the next
large file from going in.
═══════════════════════════════════════════════════════════════════════════
NEXT
