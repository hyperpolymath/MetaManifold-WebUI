#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: 05_run_epa.sh epa_dir kind   (kind = amp | pos); same command as the application's place step, -T 2, two jobs in parallel
E=$1; K=$2
s=$(date +%s)
ls -d "$E"/work/q/q*/"$K" | xargs -P 2 -n 1 sh -c 'D=$1; cd "$D" || exit 1; raxmlHPC-PTHREADS-SSE3 -f v -m GTRCATI -G 0.2 -n epa -s "$D/aln.fasta" -t "$D/tree.nwk" -T 2 -w "$D/" > "$D/raxml.stdout" 2>&1' _
echo "EPA $E $K: $(ls -d $E/work/q/q*/$K | wc -l) runs, wall clock $(( $(date +%s) - s )) s" >> $E/../raw/epa_timing.txt
