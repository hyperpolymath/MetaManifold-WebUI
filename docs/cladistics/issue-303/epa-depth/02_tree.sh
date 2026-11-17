#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: 02_tree.sh epa_dir draw [timeout_s] [threads]
#   IQ-TREE GTR+G4 with UFBoot 1000 (default 4 threads); fallback without -B after timeout_s
#   (default 1500 s = 25 min wall clock).  Logs go to ../raw relative to epa_dir.
set -eu
mkdir -p "$1/work"
E=$(cd "$1" && pwd) || exit 1; DR=$2; TMO=${3:-1500}; NT=${4:-4}
T=$E/work/tree; mkdir -p "$T"; cd "$T"
RAW=$(cd "$E/.." && pwd)/raw
LOG=$RAW/tree_$DR.log
s=$(date +%s)
rc=0
timeout "$TMO" iqtree2 -s "$E/work/ref_full.fasta" -m GTR+G4 -B 1000 -nt "$NT" -seed 1 -pre "$T/reference" -redo > "$RAW/02_iqtree_$DR.stdout" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$T/reference.treefile" ]; then
  echo "draw $DR: -B 1000 run rc=$rc after $(( $(date +%s) - s )) s; RERUN WITHOUT -B" > "$LOG"
  s=$(date +%s)
  iqtree2 -s "$E/work/ref_full.fasta" -m GTR+G4 -nt "$NT" -seed 1 -pre "$T/reference" -redo > "$RAW/02_iqtree_$DR.nob.stdout" 2>&1
  echo "draw $DR: rerun without -B took $(( $(date +%s) - s )) s" >> "$LOG"
else
  echo "draw $DR: -B 1000 completed, $(( $(date +%s) - s )) s wall clock, rc=0" > "$LOG"
fi
[ -s "$T/reference.treefile" ] || { echo "02_tree.sh: no reference.treefile for draw $DR" >&2; exit 1; }
cp "$T/reference.treefile" "$T/reference_with_support.treefile"
