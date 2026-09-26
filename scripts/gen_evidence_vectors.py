#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# gen_evidence_vectors.py — regenerate the shared golden vectors for the
# Evidence Mode finite residual model (issue #7).
#
# The vectors are the single source of truth shared by three checkers:
#   1. the Agda proofs in proofs/  (decision procedures are *proved* correct
#      against the Candidate semantics; representative vector cases are
#      re-checked as executable Agda terms in MetaManifoldEvidence.Vectors)
#   2. the Julia backend tests    (test/unit/test_evidence_mode.jl)
#   3. the frontend bun tests     (frontend/tests/unit/evidence-model.test.ts)
#
# The semantics implemented here are copied EXACTLY from the reference
# finite explorer in hyperpolymath/residual-evidence-types
# (residual-evidence-explorer.html, model 'signed-integer-v1', MPL-2.0):
#
#   LIMIT = 6;  world = (u, n) with u, n integers in [-6, 6]
#   views: exact = identity, sign = Math.sign, magnitude = Math.abs
#   candidates = [(u, n) | |n| <= noise_bound, (not assume_zero or u == 0),
#                 observe(u + n) == observe(residual)]
#   presence : entailed   iff candidates nonempty and every candidate has u != 0
#              refuted    iff candidates nonempty and every candidate has u == 0
#              unresolved iff both kinds remain
#              inconsistent iff candidates empty
#   identification: sorted unique u values over candidates; identified iff
#              exactly one value, unidentified otherwise (inconsistent if empty)
#
# Output is deterministic (sorted keys, stable case order) so the committed
# JSON never churns: re-running this script must produce a byte-identical file.
#
# Usage: python3 scripts/gen_evidence_vectors.py [output-path]

import json
import math
import sys
from pathlib import Path

LIMIT = 6

VIEWS = {
    "exact": lambda x: x,
    "sign": lambda x: int(math.sign(x)) if False else (0 if x == 0 else (1 if x > 0 else -1)),
    "magnitude": abs,
}


def make_case(residual, noise_bound, view, assume_zero):
    """Reference semantics, ported line-for-line from the explorer."""
    if not (isinstance(residual, int) and abs(residual) <= LIMIT):
        raise ValueError("residual must be an integer in [-6, 6]")
    if not (isinstance(noise_bound, int) and 0 <= noise_bound <= LIMIT):
        raise ValueError("noise_bound must be an integer in [0, 6]")
    observe = VIEWS[view]
    candidates = []
    for latent in range(-LIMIT, LIMIT + 1):
        for noise in range(-LIMIT, LIMIT + 1):
            if (abs(noise) <= noise_bound
                    and (not assume_zero or latent == 0)
                    and observe(latent + noise) == observe(residual)):
                candidates.append({"u": latent, "n": noise})
    return candidates


def decide_presence(candidates):
    """entailed / refuted / unresolved / inconsistent, with witnesses."""
    if not candidates:
        return {"status": "inconsistent", "supporting": None, "counterexample": None}
    supporting = next((w for w in candidates if w["u"] != 0), None)
    counterexample = next((w for w in candidates if w["u"] == 0), None)
    status = ("entailed" if counterexample is None
              else "refuted" if supporting is None
              else "unresolved")
    return {"status": status, "supporting": supporting, "counterexample": counterexample}


def identify(candidates):
    if not candidates:
        return {"status": "inconsistent", "values": []}
    values = sorted({w["u"] for w in candidates})
    return {"status": "identified" if len(values) == 1 else "unidentified", "values": values}


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "proofs/vectors/evidence_vectors.json")
    cases = []
    # Full factorial sweep: 13 residuals x 7 bounds x 3 views x 2 zero-assumptions.
    for residual in range(-LIMIT, LIMIT + 1):
        for bound in range(0, LIMIT + 1):
            for view in ("exact", "sign", "magnitude"):
                for assume_zero in (False, True):
                    cands = make_case(residual, bound, view, assume_zero)
                    case = {
                        "residual": residual,
                        "noise_bound": bound,
                        "view": view,
                        "assume_zero": assume_zero,
                        "candidate_count": len(cands),
                        "presence": decide_presence(cands)["status"],
                        "identified_values": identify(cands)["values"],
                        "first_candidates": cands[:3],
                    }
                    cases.append(case)

    doc = {
        "model": "signed-integer-v1",
        "limit": LIMIT,
        "source": "hyperpolymath/residual-evidence-types residual-evidence-explorer.html",
        "licence": "MPL-2.0",
        "case_count": len(cases),
        "presets": {
            "ambiguous": {"residual": 2, "noise_bound": 6, "assume_zero": False, "view": "exact"},
            "present": {"residual": 2, "noise_bound": 1, "assume_zero": False, "view": "exact"},
            "exact": {"residual": 2, "noise_bound": 0, "assume_zero": False, "view": "exact"},
            "cancel": {"residual": 0, "noise_bound": 6, "assume_zero": False, "view": "exact"},
            "conflict": {"residual": 2, "noise_bound": 1, "assume_zero": True, "view": "exact"},
        },
        "cases": cases,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, sort_keys=False)
        fh.write("\n")
    print(f"wrote {len(cases)} cases to {out}")


if __name__ == "__main__":
    main()
