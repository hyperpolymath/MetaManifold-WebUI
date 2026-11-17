#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: 05_run_epa.sh epa_dir kind   (kind = amp | pos | neg)
# Application command (src/pipeline/phylogeny.jl, step "place"), threads=4 -> -T max(2,threads) = -T 4 in the app;
# here -T 2 with two runs in parallel on 4 cores (thread count does not change the result).
#   raxmlHPC-PTHREADS-SSE3 -f v -m GTRCATI -G 0.2 -n epa -s <aln> -t <tree> -T N -w <dir>/
E=$1; K=$2
ls -d "$E"/work/q/q*/"$K" | xargs -P 2 -n 1 sh -c 'D=$1; cd "$D" || exit 1; raxmlHPC-PTHREADS-SSE3 -f v -m GTRCATI -G 0.2 -n epa -s "$D/aln.fasta" -t "$D/tree.nwk" -T 2 -w "$D/" > "$D/raxml.stdout" 2>&1' _
