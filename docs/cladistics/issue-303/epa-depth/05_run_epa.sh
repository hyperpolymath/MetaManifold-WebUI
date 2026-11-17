#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: 05_run_epa.sh epa_dir kind   (kind = amp | pos); same command as the application's place step, -T 2, two jobs in parallel
set -eu
E=$(cd "$1" && pwd) || exit 1; K=$2
RAW=$(cd "$E/.." && pwd)/raw
s=$(date +%s)
# one NUL-terminated path per query directory, so paths with spaces stay whole; xargs exits 123 if any worker failed
n=0
for D in "$E"/work/q/q*/"$K"; do [ -d "$D" ] && n=$((n + 1)); done
[ "$n" -gt 0 ] || { echo "05_run_epa.sh: no query directories for kind $K under $E/work/q" >&2; exit 1; }
for D in "$E"/work/q/q*/"$K"; do [ -d "$D" ] && printf "%s\0" "$D"; done |
  xargs -0 -P 2 -n 1 sh -c 'D=$1; cd "$D" || exit 1; raxmlHPC-PTHREADS-SSE3 -f v -m GTRCATI -G 0.2 -n epa -s "$D/aln.fasta" -t "$D/tree.nwk" -T 2 -w "$D/" > "$D/raxml.stdout" 2>&1' _ ||
  { echo "05_run_epa.sh: at least one EPA run failed (kind $K); see raxml.stdout in the query directories" >&2; exit 1; }
echo "EPA $E $K: $n runs, wall clock $(( $(date +%s) - s )) s" >> "$RAW/epa_timing.txt"
