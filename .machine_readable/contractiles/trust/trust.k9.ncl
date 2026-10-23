K9!
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# trust.k9.ncl — Security and data-integrity boundary declarations for the
# hyperpolymath/MetaManifold-WebUI fork. Evaluated at 'Yard (contract-eval-only).
{
  pedigree = {
    schema_version = "1.0.0",
    component_type = "contractile:trust",
    contractile_verb = "trust",
    semantics = "boundary-verification",
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
      name = "metamanifold-webui-trust",
      version = "1.0.0",
      description = "Trust-boundary declarations covering strict I-JSON/JCS serialisation, HTTP JSON input validation, read-only DuckDB analysis access, and SHA-pinned workflows.",
      author = "Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>",
    },
    warnings = [
      "Evaluated at Yard as typed configuration only; boundary tests run inside the CI workflow.",
    ],
    side_effects = [],
  },

  config = {
    max_statistics_request_bytes = 16777216,
    max_ieee754_safe_integer = 9007199254740991,
    boundaries = [
      {
        id = "strict-ijson-jcs-wire-boundary",
        surface = "src/core/canonical.jl",
        rule = "Validated statistics and canonical responses enforce RFC 7493 I-JSON input parsing and RFC 8785 JCS deterministic output.",
      },
      {
        id = "http-json-body-validation",
        surface = "src/server/server.jl",
        rule = "HTTP JSON route handlers reject malformed or non-object JSON payloads with HTTP 400 rather than throwing unhandled 500 exceptions, without mutating request byte buffers.",
      },
      {
        id = "read-only-duckdb-analysis",
        surface = "src/server/routes/duckdb_helpers.jl",
        rule = "Analysis and validated-statistics routes open run DuckDB files in read-only mode and stream exact integer counts into BigInt accumulators.",
      },
      {
        id = "immutable-ci-and-tool-pins",
        surface = "test/unit/test_install_pins.jl",
        rule = "Workflow actions and bioinformatics tool versions remain pinned and verified by unit tests.",
      },
    ],
  },

  validation = {
    request_limit_positive = config.max_statistics_request_bytes > 0,
    safe_integer_bound = config.max_ieee754_safe_integer == 9007199254740991,
    boundary_count_positive = std.array.length config.boundaries >= 4,
  },
}
