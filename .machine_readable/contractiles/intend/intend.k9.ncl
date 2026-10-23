K9!
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# intend.k9.ncl — Architectural commitments and north-star intent declarations
# for the hyperpolymath/MetaManifold-WebUI fork. Evaluated at 'Yard (reporting
# authority; non-gating drift reference).
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "contractile:intend",
    contractile_verb = "intend",
    semantics = "commitment-and-aspiration",
    tier = 'Yard,
    authority = 'reporting,
    security = {
      leash = 'Yard,
      signature_required = false,
      trust_level = "contract-eval-only",
      allow_network = false,
      allow_filesystem_write = false,
      allow_subprocess = false,
      capabilities = [],
    },
    metadata = {
      name = "metamanifold-webui-intend",
      version = "1.0.0",
      description = "North-star commitments for exact ecological statistics, machine-checked Agda proofs, epistemic cladistic overlays, and clean upstream-candidate separation.",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
    warnings = [
      "Evaluated at Yard with reporting authority; records architectural intent without executing host commands.",
    ],
    side_effects = [],
  },

  config = {
    commitments = [
      {
        id = "exact-count-aggregation",
        area = "src/analysis/exact_summaries.jl",
        status = "verified",
        summary = "Aggregate amplicon counts with arbitrary-precision integers and rationals before controlled high-precision projection.",
      },
      {
        id = "constructive-formal-proofs",
        area = "proofs/agda/",
        status = "verified",
        summary = "Maintain machine-checked Agda proofs for Benjamini-Hochberg adjustment and TSS/RLE scaling invariants.",
      },
      {
        id = "warranted-cladistic-overlays",
        area = "src/analysis/clade_cumulus.jl",
        status = "verified",
        summary = "Keep CladeCumulus topology proposals support-warranted, immutable as sidecars, and invariant in tip-level Faith PD across reaggregation.",
      },
      {
        id = "honest-fleet-evidence",
        area = ".gitbot-fleet/enrolment.json",
        status = "in_progress",
        summary = "Surface genuine Hypatia, panic-attack, pons-asinorum, K9, and DEED verdicts while keeping unenrolled or unexecuted bot slots explicitly marked rather than fabricated.",
      },
    ],
  },

  validation = {
    commitment_count_positive = std.array.length config.commitments >= 4,
  },
}
