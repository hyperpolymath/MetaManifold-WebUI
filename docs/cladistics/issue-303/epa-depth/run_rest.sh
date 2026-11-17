#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: run_rest.sh WORK [Q [NPOS]]   (after run_trees.sh has finished)
#   Q amplicon queries per draw (selection seeds 7 and 8), default 300; whole-sequence control for
#   the first NPOS queries of draw A, default 60.  WORK may be relative.  Any failed stage stops
#   the script with a non-zero status.
set -eu
D=$(cd "$1" && pwd) || exit 1
Q=${2:-300}; NPOS=${3:-60}
cd "$D"
julia -O2 scripts/03_prep.jl "$D/A" "$Q" 7 "$NPOS" > raw/03_prep_A.log 2>&1
julia -O2 scripts/03_prep.jl "$D/B" "$Q" 8 0 > raw/03_prep_B.log 2>&1
sh scripts/05_run_epa.sh "$D/A" amp
if [ "$NPOS" -gt 0 ]; then sh scripts/05_run_epa.sh "$D/A" pos; fi
sh scripts/05_run_epa.sh "$D/B" amp
