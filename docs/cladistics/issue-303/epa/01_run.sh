#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: 01_run.sh epa_dir silva.bacteria.fasta [N]
#   epa_dir (absolute or relative) holds scripts/ (a copy of this directory), and receives work/ and raw/.
#   N = number of references, default 200 (the published size).
set -eu
mkdir -p "$1/work/tree" "$1/raw"
E=$(cd "$1" && pwd) || exit 1
SILVA=$2; N=${3:-200}
julia -O2 "$E/scripts/01_select.jl" "$SILVA" "$E/work" "$N" 20261117
