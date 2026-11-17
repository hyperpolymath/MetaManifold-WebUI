#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: run_trees.sh WORK /path/to/silva.bacteria.fasta
#   WORK holds scripts/ (../epa/ with this directory copied over it) and receives A/, B/ and raw/.
D=$1; SILVA=$2
mkdir -p "$D/raw"
for X in A B; do
  seed=20261117; [ "$X" = B ] && seed=20261118
  mkdir -p "$D/$X/work"
  julia -O2 "$D/scripts/01_select.jl" "$SILVA" "$D/$X/work" 400 "$seed" > "$D/raw/01_select_$X.log" 2>&1
done
sh "$D/scripts/02_tree.sh" "$D/A" A
sh "$D/scripts/02_tree.sh" "$D/B" B
