#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Independent awk reference oracle for Issue #19 constrained ordinations.
# Bash driver for check_ordination_references.awk (a port of the former
# check_ordination_references.py). All the maths is hand-written in plain
# double precision awk and shares no code with Julia.
#
# Usage:
#   check_ordination_references.sh [--check PATH] [--generate]
#
#   --check PATH   fixture to verify (default test/fixtures/ordination_reference.json)
#   --generate     first write the canonical JCS schema and fixture
#
# Environment:
#   AWK                       awk program to use (default: awk)
#   ORDINATION_GENERATE_DIR   write generated files here instead of the repo
#                             (constrained-ordination.schema.json and
#                             ordination_reference.json); checks still read the
#                             repo files
#
# Exit: 0 verified, 1 a check failed, 2 usage error.
set -euo pipefail
export LC_ALL=C

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$here/../.." && pwd -P)"
awk_prog="$here/check_ordination_references.awk"
default_fixture="$repo_root/test/fixtures/ordination_reference.json"
schema="$repo_root/docs/schemas/constrained-ordination.schema.json"
kyaml="$repo_root/config/defaults/ordination.kyaml"
oracle="$repo_root/test/fixtures/jcs_oracle.jsonl"

usage() {
  echo "usage: check_ordination_references.sh [-h] [--generate] [--check PATH]"
}

fixture="$default_fixture"
generate=0
while (( $# > 0 )); do
  case "$1" in
    -h|--h|--he|--hel|--help)
      usage
      echo "  --generate    Write canonical JCS schema and reference fixture"
      echo "  --check PATH  Fixture path to verify"
      exit 0 ;;
    --g|--ge|--gen|--gene|--gener|--genera|--generat|--generate) generate=1; shift ;;
    --c|--ch|--che|--chec|--check)
      if (( $# < 2 )); then echo "error: argument --check: expected one argument" >&2; usage >&2; exit 2; fi
      fixture="$2"; shift 2 ;;
    --c=*|--ch=*|--che=*|--chec=*|--check=*) fixture="${1#*=}"; shift ;;
    *) echo "error: unrecognized arguments: $1" >&2; usage >&2; exit 2 ;;
  esac
done

AWK="${AWK:-awk}"
command -v "$AWK" >/dev/null || { echo "error: awk is required" >&2; exit 2; }

# 1 when the file ends with exactly one LF (the JCS file rule), else 0.
lf_ok() {
  local tail2
  [[ -f "$1" ]] || { echo 0; return; }
  tail2="$(tail -c 2 -- "$1" | od -An -v -tx1 | tr -d ' \n')"
  case "$tail2" in
    *0a0a) echo 0 ;;
    *0a) echo 1 ;;
    *) echo 0 ;;
  esac
}

# The schema as plain JSON. Key order is irrelevant: the awk JCS serialiser
# sorts keys, so this is the content of build_schema_document().
schema_source() {
  cat <<'SCHEMA_JSON'
{
  "$id": "https://github.com/hyperpolymath/MetaManifold-WebUI/blob/main/docs/schemas/constrained-ordination.schema.json",
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "additionalProperties": false,
  "description": "Canonical RFC 7493 I-JSON / RFC 8785 JCS response schema for MetaManifold constrained ordinations (RDA, CCA, CAP, dbRDA).",
  "properties": {
    "adj_r2": {
      "type": [
        "number",
        "null"
      ]
    },
    "artifact": {
      "additionalProperties": false,
      "properties": {
        "analysis_id": {
          "pattern": "^[0-9a-f]{64}$",
          "type": "string"
        },
        "created": {
          "type": "boolean"
        }
      },
      "required": [
        "analysis_id",
        "created"
      ],
      "type": "object"
    },
    "available_covariates": {
      "items": {
        "type": "string"
      },
      "type": "array"
    },
    "axis_labels": {
      "items": {
        "type": "string"
      },
      "maxItems": 2,
      "minItems": 2,
      "type": "array"
    },
    "axis_names": {
      "items": {
        "type": "string"
      },
      "maxItems": 2,
      "minItems": 2,
      "type": "array"
    },
    "axis_tests": {
      "$ref": "#/$defs/termTestArray"
    },
    "biplot": {
      "additionalProperties": false,
      "properties": {
        "data": {
          "items": {
            "type": "object"
          },
          "type": "array"
        },
        "layout": {
          "type": "object"
        }
      },
      "required": [
        "data",
        "layout"
      ],
      "type": "object"
    },
    "biplot_arrows": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "axis1": {
            "type": "number"
          },
          "axis2": {
            "type": "number"
          },
          "label": {
            "type": "string"
          },
          "length": {
            "minimum": 0,
            "type": "number"
          }
        },
        "required": [
          "label",
          "axis1",
          "axis2",
          "length"
        ],
        "type": "object"
      },
      "type": "array"
    },
    "cautions": {
      "items": {
        "type": "string"
      },
      "type": "array"
    },
    "centroids": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "axis1": {
            "type": "number"
          },
          "axis2": {
            "type": "number"
          },
          "label": {
            "type": "string"
          }
        },
        "required": [
          "label",
          "axis1",
          "axis2"
        ],
        "type": "object"
      },
      "type": "array"
    },
    "condition_terms": {
      "items": {
        "type": "string"
      },
      "type": "array"
    },
    "conditioned_inertia": {
      "minimum": 0,
      "type": "number"
    },
    "conditioned_proportion": {
      "minimum": 0,
      "type": "number"
    },
    "constrained_eigenvalues": {
      "$ref": "#/$defs/eigenvalueArray"
    },
    "constrained_inertia": {
      "minimum": 0,
      "type": "number"
    },
    "constrained_proportion": {
      "minimum": 0,
      "type": "number"
    },
    "constrained_terms": {
      "items": {
        "type": "string"
      },
      "minItems": 1,
      "type": "array"
    },
    "distance": {
      "enum": [
        "bray",
        "jaccard",
        "euclidean",
        "aitchison",
        "chisq",
        "unweighted_unifrac",
        "weighted_unifrac"
      ],
      "type": "string"
    },
    "formula": {
      "minLength": 2,
      "type": "string"
    },
    "imaginary_inertia": {
      "minimum": 0,
      "type": "number"
    },
    "marginal_tests": {
      "$ref": "#/$defs/termTestArray"
    },
    "method": {
      "enum": [
        "rda",
        "cca",
        "cap",
        "dbrda"
      ],
      "type": "string"
    },
    "n_features": {
      "minimum": 0,
      "type": "integer"
    },
    "n_samples": {
      "minimum": 3,
      "type": "integer"
    },
    "omnibus_test": {
      "additionalProperties": false,
      "properties": {
        "df_model": {
          "minimum": 1,
          "type": "integer"
        },
        "df_residual": {
          "minimum": 1,
          "type": "integer"
        },
        "f_statistic": {
          "type": [
            "number",
            "null"
          ]
        },
        "min_p_value": {
          "exclusiveMinimum": 0,
          "maximum": 1,
          "type": "number"
        },
        "p_value": {
          "type": [
            "number",
            "null"
          ]
        },
        "permutations": {
          "maximum": 9999,
          "minimum": 1,
          "type": "integer"
        },
        "text": {
          "type": "string"
        },
        "untestable_reason": {
          "type": [
            "string",
            "null"
          ]
        },
        "variance_model": {
          "type": [
            "number",
            "null"
          ]
        },
        "variance_residual": {
          "type": [
            "number",
            "null"
          ]
        }
      },
      "required": [
        "df_model",
        "df_residual",
        "variance_model",
        "variance_residual",
        "f_statistic",
        "p_value",
        "untestable_reason",
        "permutations",
        "min_p_value",
        "text"
      ],
      "type": "object"
    },
    "provenance": {
      "additionalProperties": true,
      "properties": {
        "beta_normalisation": {
          "type": "string"
        },
        "blocked": {
          "type": "boolean"
        },
        "condition_terms": {
          "items": {
            "type": "string"
          },
          "type": "array"
        },
        "constrained_terms": {
          "items": {
            "type": "string"
          },
          "type": "array"
        },
        "distance": {
          "type": "string"
        },
        "dropped_zero_features": {
          "minimum": 0,
          "type": "integer"
        },
        "formula": {
          "type": "string"
        },
        "method": {
          "enum": [
            "rda",
            "cca",
            "cap",
            "dbrda"
          ],
          "type": "string"
        },
        "multiple_testing_policy": {
          "type": "string"
        },
        "n_features": {
          "minimum": 0,
          "type": "integer"
        },
        "n_samples": {
          "minimum": 3,
          "type": "integer"
        },
        "permutations_performed": {
          "minimum": 1,
          "type": "integer"
        },
        "permutations_requested": {
          "maximum": 9999,
          "minimum": 99,
          "type": "integer"
        },
        "rng_kind": {
          "type": "string"
        },
        "scaling": {
          "enum": [
            1,
            2
          ],
          "type": "integer"
        },
        "scaling_meaning": {
          "enum": [
            "distance",
            "correlation"
          ],
          "type": "string"
        },
        "seed": {
          "type": "integer"
        },
        "software": {
          "additionalProperties": false,
          "properties": {
            "r_package": {
              "const": "vegan",
              "type": "string"
            },
            "vegan_version": {
              "type": "string"
            }
          },
          "required": [
            "r_package",
            "vegan_version"
          ],
          "type": "object"
        },
        "zero_replacement": {
          "type": [
            "object",
            "null"
          ]
        }
      },
      "required": [
        "method",
        "distance",
        "scaling",
        "scaling_meaning",
        "formula",
        "permutations_requested",
        "permutations_performed",
        "seed",
        "multiple_testing_policy",
        "software"
      ],
      "type": "object"
    },
    "r2": {
      "type": [
        "number",
        "null"
      ]
    },
    "runtime_estimate": {
      "additionalProperties": false,
      "properties": {
        "estimated_seconds": {
          "minimum": 0,
          "type": "number"
        },
        "tier": {
          "enum": [
            "fast",
            "moderate",
            "heavy"
          ],
          "type": "string"
        },
        "warn_five_minutes": {
          "type": "boolean"
        }
      },
      "required": [
        "estimated_seconds",
        "tier",
        "warn_five_minutes"
      ],
      "type": "object"
    },
    "scaling": {
      "enum": [
        1,
        2
      ],
      "type": "integer"
    },
    "sites": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "axis1": {
            "type": "number"
          },
          "axis2": {
            "type": "number"
          },
          "sample": {
            "type": "string"
          }
        },
        "required": [
          "sample",
          "axis1",
          "axis2"
        ],
        "type": "object"
      },
      "minItems": 3,
      "type": "array"
    },
    "term_tests": {
      "$ref": "#/$defs/termTestArray"
    },
    "top_feature_scores": {
      "items": {
        "type": "object"
      },
      "type": "array"
    },
    "total_inertia": {
      "minimum": 0,
      "type": "number"
    },
    "unconstrained_eigenvalues": {
      "$ref": "#/$defs/eigenvalueArray"
    },
    "unconstrained_inertia": {
      "minimum": 0,
      "type": "number"
    },
    "unconstrained_proportion": {
      "minimum": 0,
      "type": "number"
    },
    "variance_partitioning": {
      "type": [
        "object",
        "null"
      ]
    }
  },
  "required": [
    "method",
    "distance",
    "scaling",
    "formula",
    "constrained_terms",
    "condition_terms",
    "n_samples",
    "n_features",
    "total_inertia",
    "constrained_inertia",
    "unconstrained_inertia",
    "r2",
    "adj_r2",
    "sites",
    "biplot_arrows",
    "omnibus_test",
    "term_tests",
    "provenance",
    "biplot"
  ],
  "title": "ConstrainedOrdinationResult",
  "type": "object",
  "$defs": {
    "eigenvalueArray": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "axis": {
            "type": "string"
          },
          "eigenvalue": {
            "minimum": 0,
            "type": "number"
          },
          "proportion_constrained": {
            "minimum": 0,
            "type": "number"
          },
          "proportion_total": {
            "minimum": 0,
            "type": "number"
          }
        },
        "required": [
          "axis",
          "eigenvalue",
          "proportion_total"
        ],
        "type": "object"
      },
      "type": "array"
    },
    "termTestArray": {
      "items": {
        "additionalProperties": false,
        "properties": {
          "df": {
            "minimum": 0,
            "type": "integer"
          },
          "f_statistic": {
            "type": [
              "number",
              "null"
            ]
          },
          "p_value": {
            "type": [
              "number",
              "null"
            ]
          },
          "term": {
            "type": "string"
          },
          "untestable_reason": {
            "type": [
              "string",
              "null"
            ]
          },
          "variance": {
            "type": [
              "number",
              "null"
            ]
          }
        },
        "required": [
          "term",
          "df",
          "variance",
          "f_statistic",
          "p_value",
          "untestable_reason"
        ],
        "type": "object"
      },
      "type": "array"
    }
  }
}
SCHEMA_JSON
}

if (( generate )); then
  out_schema="$schema"
  out_fixture="$default_fixture"
  if [[ -n "${ORDINATION_GENERATE_DIR:-}" ]]; then
    out_schema="$ORDINATION_GENERATE_DIR/constrained-ordination.schema.json"
    out_fixture="$ORDINATION_GENERATE_DIR/ordination_reference.json"
  fi
  mkdir -p -- "$(dirname -- "$out_schema")" "$(dirname -- "$out_fixture")"
  env ORD_STAGE=generate ORD_SCHEMA_SRC=<(schema_source) \
    ORD_SCHEMA_OUT="$out_schema" ORD_FIXTURE_OUT="$out_fixture" \
    "$AWK" -f "$awk_prog"
fi

ORD_STAGE=check \
ORD_ORACLE="$oracle" ORD_KYAML="$kyaml" ORD_SCHEMA="$schema" ORD_FIXTURE="$fixture" \
ORD_SCHEMA_LF="$(lf_ok "$schema")" ORD_FIXTURE_LF="$(lf_ok "$fixture")" \
ORD_SCHEMA_NAME="$(basename -- "$schema")" ORD_KYAML_NAME="$(basename -- "$kyaml")" \
  "$AWK" -f "$awk_prog"
