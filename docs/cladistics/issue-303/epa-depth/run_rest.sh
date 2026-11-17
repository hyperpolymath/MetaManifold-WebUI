#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: run_rest.sh WORK   (after run_trees.sh has finished)
#   300 amplicon queries per draw (selection seeds 7 and 8); whole-sequence control for the
#   first 60 queries of draw A.
D=$1
cd "$D" || exit 1
julia -O2 scripts/03_prep.jl "$D/A" 300 7 60 > raw/03_prep_A.log 2>&1
julia -O2 scripts/03_prep.jl "$D/B" 300 8 0 > raw/03_prep_B.log 2>&1
sh scripts/05_run_epa.sh "$D/A" amp
sh scripts/05_run_epa.sh "$D/A" pos
sh scripts/05_run_epa.sh "$D/B" amp
