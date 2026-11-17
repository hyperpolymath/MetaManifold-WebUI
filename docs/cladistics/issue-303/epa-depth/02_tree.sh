#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: 02_tree.sh epa_dir draw   -- IQ-TREE GTR+G4 with UFBoot 1000 (4 threads); fallback without -B after 25 min wall clock
E=$1; DR=$2; T=$E/work/tree; mkdir -p $T; cd $T
LOG=$E/../raw/tree_$DR.log
s=$(date +%s)
timeout 1500 iqtree2 -s $E/work/ref_full.fasta -m GTR+G4 -B 1000 -nt 4 -seed 1 -pre $T/reference -redo > $E/../raw/02_iqtree_$DR.stdout 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -s $T/reference.treefile ]; then
  echo "draw $DR: -B 1000 run rc=$rc after $(( $(date +%s) - s )) s; RERUN WITHOUT -B" > $LOG
  s=$(date +%s)
  iqtree2 -s $E/work/ref_full.fasta -m GTR+G4 -nt 4 -seed 1 -pre $T/reference -redo > $E/../raw/02_iqtree_$DR.nob.stdout 2>&1
  echo "draw $DR: rerun without -B took $(( $(date +%s) - s )) s" >> $LOG
else
  echo "draw $DR: -B 1000 completed, $(( $(date +%s) - s )) s wall clock, rc=0" > $LOG
fi
cp $T/reference.treefile $T/reference_with_support.treefile
