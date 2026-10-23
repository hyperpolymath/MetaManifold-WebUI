K9!
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# must.k9.ncl — Release-blocking invariant declarations for the
# hyperpolymath/MetaManifold-WebUI fork. Evaluated at 'Yard (contract-eval-only);
# verification commands run in dedicated CI jobs rather than inside this file.
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "contractile:must",
    contractile_verb = "must",
    semantics = "invariant-assertion",
    tier = 'Yard,
    authority = 'blocking,
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
      name = "metamanifold-webui-must",
      version = "1.0.0",
      description = "Release-blocking fork invariants for DEED/K9 governance, proof soundness, high-precision oracles, and upstream AGPL-3.0 preservation.",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
    warnings = [
      "Evaluated at Yard as typed configuration only; invariant scripts execute in pinned GitHub Actions steps.",
    ],
    side_effects = [],
  },

  config = {
    repository = "hyperpolymath/MetaManifold-WebUI",
    upstream_repository = "JoshuaJewell/MetaManifold-WebUI",
    upstream_license = "AGPL-3.0-only",
    fork_addition_license = "MPL-2.0",
    invariants = [
      {
        id = "repo-deed-present",
        target = "MetaManifold-WebUI_chora.deed",
        check_command = "deed_lint.js MetaManifold-WebUI_chora.deed",
        rationale = "Repository deed must remain syntactically and structurally valid.",
      },
      {
        id = "governance-advisory-sarif-boundary",
        target = "scripts/check-governance-contract.sh",
        check_command = "bash scripts/check-governance-contract.sh",
        rationale = "Pull-request Hypatia scans must publish verdict grids without creating blocking SARIF upload gates, and standards workflow pins must match.",
      },
      {
        id = "agda-axiom-audit",
        target = "proofs/tests/axiom-audit.sh",
        check_command = "bash proofs/tests/axiom-audit.sh",
        rationale = "Agda proofs must retain --safe --without-K with zero postulates or escape pragmas.",
      },
      {
        id = "high-precision-reference-oracle",
        target = "test/references/check_high_precision_references.py",
        check_command = "python3 test/references/check_high_precision_references.py --check test/unit/test_high_precision.jl",
        rationale = "Independent arbitrary-precision reference constants must match the Julia test suite.",
      },
      {
        id = "upstream-license-untouched",
        target = "LICENSE",
        check_command = "test -s LICENSE && test -s CITATION.cff",
        rationale = "Upstream AGPL-3.0-only LICENSE, CITATION.cff, and existing copyright headers are never rewritten on this fork.",
      },
    ],
  },

  validation = {
    has_upstream_license = config.upstream_license == "AGPL-3.0-only",
    has_fork_license = config.fork_addition_license == "MPL-2.0",
    invariant_count_positive = std.array.length config.invariants >= 5,
  },
}
