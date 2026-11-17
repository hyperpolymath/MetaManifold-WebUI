#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: 02_tree.sh epa_dir
# Application: iqtree -s ALN -m MFP -b 100 -nt 4 -seed S -pre PFX -redo
# Used here:   iqtree2 -s ALN -m GTR+G4 -nt 4 -seed 1 -pre PFX -redo
#   (-m MFP aborted after 12 min at 90/286 models; -b 100 omitted: it does not change the ML tree)
E=$1
cd $E/work/tree && iqtree2 -s $E/work/ref_full.fasta -m GTR+G4 -nt 4 -seed 1 -pre $E/work/tree/reference -redo > $E/raw/02_iqtree.stdout 2>&1
