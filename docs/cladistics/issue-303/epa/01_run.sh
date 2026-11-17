#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: 01_run.sh epa_dir silva.bacteria.fasta
#   epa_dir holds scripts/ (a copy of this directory), and receives work/ and raw/.
E=$1; SILVA=$2
mkdir -p "$E/work/tree" "$E/raw"
julia -O2 "$E/scripts/01_select.jl" "$SILVA" "$E/work" 200 20261117
