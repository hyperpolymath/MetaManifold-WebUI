#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Independent Python stdlib reference oracle for Issue #19 constrained ordinations
(RDA, partial RDA with Condition(...), CLR/Aitchison and Hellinger geometries,
Ezekiel adjusted-R2, Jacobi eigenvalues, and Peres-Neto two-way variance
partitioning), plus RFC 7493 I-JSON / RFC 8785 JCS canonical verification for
the constrained-ordination schema and reference fixture.

Zero third-party dependencies: uses only Python 3 standard library modules.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sys
from typing import Any

SAFE_INT_MAX = (1 << 53) - 1
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = REPO_ROOT / "test" / "fixtures" / "ordination_reference.json"
DEFAULT_SCHEMA = REPO_ROOT / "docs" / "schemas" / "constrained-ordination.schema.json"
DEFAULT_KYAML = REPO_ROOT / "config" / "defaults" / "ordination.kyaml"


def _utf16_units(s: str) -> tuple[int, ...]:
    raw = s.encode("utf-16-be")
    return tuple((raw[i] << 8) | raw[i + 1] for i in range(0, len(raw), 2))


def _check_ijson_str(s: str) -> None:
    for ch in s:
        cp = ord(ch)
        if 0xD800 <= cp <= 0xDFFF:
            raise ValueError(f"Lone surrogate U+{cp:04X} forbidden in I-JSON")
        if 0xFDD0 <= cp <= 0xFDEF or (cp & 0xFFFE) == 0xFFFE:
            raise ValueError(f"Unicode noncharacter U+{cp:04X} forbidden in I-JSON")


def _jcs_escape_str(s: str) -> str:
    _check_ijson_str(s)
    out = ['"']
    for ch in s:
        cp = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif cp == 0x08:
            out.append("\\b")
        elif cp == 0x09:
            out.append("\\t")
        elif cp == 0x0A:
            out.append("\\n")
        elif cp == 0x0C:
            out.append("\\f")
        elif cp == 0x0D:
            out.append("\\r")
        elif cp < 0x20:
            out.append(f"\\u{cp:04x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _jcs_format_float(x: float) -> str:
    if not math.isfinite(x):
        raise ValueError("Non-finite float forbidden in I-JSON/JCS")
    if x == 0.0:
        return "0"
    neg = x < 0.0
    ax = -x if neg else x
    # Python's repr(float) uses David Gay / Ryū shortest round-trip digits
    s = repr(ax)
    if "e" in s or "E" in s:
        mant, exp_s = s.lower().split("e")
        digits = mant.replace(".", "")
        exp10 = int(exp_s)
    else:
        if "." in s:
            int_p, frac_p = s.split(".")
            if int_p == "0":
                stripped = frac_p.lstrip("0")
                zeros = len(frac_p) - len(stripped)
                digits = stripped.rstrip("0")
                exp10 = -(zeros + 1)
            else:
                digits = (int_p + frac_p).rstrip("0")
                exp10 = len(int_p) - 1
        else:
            digits = s.rstrip("0")
            exp10 = len(s) - 1

    k = len(digits)
    n = exp10 + 1  # ECMAScript Number::toString n (10^(n-1) <= ax < 10^n)
    if k <= n <= 21:
        body = digits + ("0" * (n - k))
    elif 0 < n <= 21:
        body = digits[:n] + "." + digits[n:]
    elif -5 <= n <= 0:
        body = "0." + ("0" * (-n)) + digits
    else:
        sign_e = "+" if (n - 1) >= 0 else "-"
        mant_e = digits if k == 1 else (digits[0] + "." + digits[1:])
        body = f"{mant_e}e{sign_e}{abs(n - 1)}"
    return ("-" + body) if neg else body


def jcs_dumps(val: Any) -> str:
    if val is None:
        return "null"
    if val is True:
        return "true"
    if val is False:
        return "false"
    if isinstance(val, int):
        if not (-SAFE_INT_MAX <= val <= SAFE_INT_MAX):
            raise ValueError(f"Integer {val} outside I-JSON safe range")
        return str(val)
    if isinstance(val, float):
        return _jcs_format_float(val)
    if isinstance(val, str):
        return _jcs_escape_str(val)
    if isinstance(val, (list, tuple)):
        return "[" + ",".join(jcs_dumps(item) for item in val) + "]"
    if isinstance(val, dict):
        items: list[tuple[tuple[int, ...], str, Any]] = []
        for k, v in val.items():
            if not isinstance(k, str):
                raise ValueError("JSON object keys must be strings")
            items.append((_utf16_units(k), k, v))
        items.sort(key=lambda t: t[0])
        return "{" + ",".join(f"{_jcs_escape_str(k)}:{jcs_dumps(v)}" for _, k, v in items) + "}"
    raise TypeError(f"Unsupported type for JCS: {type(val)!r}")


# --- Pure-Python statistical reference engine ---

def _centre_cols(mat: list[list[float]]) -> list[list[float]]:
    n = len(mat)
    p = len(mat[0])
    means = [sum(mat[i][j] for i in range(n)) / n for j in range(p)]
    return [[mat[i][j] - means[j] for j in range(p)] for i in range(n)]


def _mgs_orthonormal(mat: list[list[float]], tol: float = 1e-11) -> list[list[float]]:
    """Return orthonormal basis columns (as list of column vectors of length n)."""
    n = len(mat)
    m = len(mat[0])
    basis: list[list[float]] = []
    for j in range(m):
        v = [mat[i][j] for i in range(n)]
        for _ in range(2):
            for q in basis:
                proj = sum(q[i] * v[i] for i in range(n))
                for i in range(n):
                    v[i] -= proj * q[i]
        norm = math.sqrt(sum(x * x for x in v))
        if norm > tol:
            basis.append([x / norm for x in v])
    return basis


def _project(basis: list[list[float]], mat: list[list[float]]) -> list[list[float]]:
    n = len(mat)
    p = len(mat[0])
    out = [[0.0] * p for _ in range(n)]
    for q in basis:
        for j in range(p):
            dot = sum(q[i] * mat[i][j] for i in range(n))
            for i in range(n):
                out[i][j] += q[i] * dot
    return out


def _sub_mat(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [[a[i][j] - b[i][j] for j in range(len(a[0]))] for i in range(len(a))]


def _frob_sq(mat: list[list[float]]) -> float:
    return sum(x * x for row in mat for x in row)


def _jacobi_sym_eigenvalues(sym: list[list[float]], tol: float = 1e-13) -> list[float]:
    m = len(sym)
    if m == 0:
        return []
    if m == 1:
        return [sym[0][0]] if sym[0][0] > tol else []
    a = [[0.5 * (sym[i][j] + sym[j][i]) for j in range(m)] for i in range(m)]
    for _ in range(90):
        max_off = 0.0
        for p in range(m - 1):
            for q in range(p + 1, m):
                if abs(a[p][q]) > max_off:
                    max_off = abs(a[p][q])
        if max_off <= tol:
            break
        for p in range(m - 1):
            for q in range(p + 1, m):
                apq = a[p][q]
                if abs(apq) <= tol:
                    continue
                tau = (a[q][q] - a[p][p]) / (2.0 * apq)
                t = (1.0 / (tau + math.sqrt(1.0 + tau * tau))) if tau >= 0.0 else (-1.0 / (-tau + math.sqrt(1.0 + tau * tau)))
                c = 1.0 / math.sqrt(1.0 + t * t)
                s = t * c
                app = a[p][p]
                aqq = a[q][q]
                a[p][p] = app - t * apq
                a[q][q] = aqq + t * apq
                a[p][q] = 0.0
                a[q][p] = 0.0
                for r in range(m):
                    if r == p or r == q:
                        continue
                    arp = a[r][p]
                    arq = a[r][q]
                    a[r][p] = c * arp - s * arq
                    a[p][r] = a[r][p]
                    a[r][q] = s * arp + c * arq
                    a[q][r] = a[r][q]
    vals = sorted((a[i][i] for i in range(m)), reverse=True)
    cutoff = max(tol, 1e-12 * max(1.0, vals[0])) if vals else tol
    return [v for v in vals if v > cutoff]


def _gram_eigenvalues(mat: list[list[float]], dof: float) -> list[float]:
    n = len(mat)
    p = len(mat[0])
    if n <= p:
        g = [[sum(mat[i][k] * mat[j][k] for k in range(p)) / dof for j in range(n)] for i in range(n)]
    else:
        g = [[sum(mat[k][i] * mat[k][j] for k in range(n)) / dof for j in range(p)] for i in range(p)]
    return _jacobi_sym_eigenvalues(g)


def ezekiel_adj_r2(r2: float, n: int, m: int) -> float:
    return 1.0 - (1.0 - r2) * (n - 1) / (n - 1 - m)


def clr_transform(counts: list[list[float]]) -> list[list[float]]:
    out: list[list[float]] = []
    for row in counts:
        logs = [math.log(v) for v in row]
        mean_log = sum(logs) / len(logs)
        out.append([lv - mean_log for lv in logs])
    return out


def hellinger_transform(counts: list[list[float]]) -> list[list[float]]:
    out: list[list[float]] = []
    for row in counts:
        tot = sum(row)
        out.append([math.sqrt(v / tot) for v in row])
    return out


def reference_linear_rda(
    y: list[list[float]],
    x: list[list[float]],
    z: list[list[float]] | None = None,
) -> dict[str, Any]:
    n = len(y)
    dof = float(n - 1)
    yc = _centre_cols(y)
    xc = _centre_cols(x)
    tot_inertia = _frob_sq(yc) / dof

    cond_inertia = 0.0
    q_rank = 0
    y_work = [row[:] for row in yc]
    x_work = [row[:] for row in xc]
    if z is not None:
        zc = _centre_cols(z)
        qz = _mgs_orthonormal(zc)
        q_rank = len(qz)
        if q_rank > 0:
            yz = _project(qz, y_work)
            cond_inertia = _frob_sq(yz) / dof
            y_work = _sub_mat(y_work, yz)
            xz = _project(qz, x_work)
            x_work = _sub_mat(x_work, xz)

    qx = _mgs_orthonormal(x_work)
    k_rank = len(qx)
    df_res = n - 1 - q_rank - k_rank
    y_hat = _project(qx, y_work)
    y_res = _sub_mat(y_work, y_hat)
    con_inertia = _frob_sq(y_hat) / dof
    unc_inertia = _frob_sq(y_res) / dof
    r2 = con_inertia / tot_inertia
    if q_rank == 0:
        adj_r2 = ezekiel_adj_r2(r2, n, k_rank)
    else:
        r2_xz = (con_inertia + cond_inertia) / tot_inertia
        r2_z = cond_inertia / tot_inertia
        adj_r2 = ezekiel_adj_r2(r2_xz, n, k_rank + q_rank) - ezekiel_adj_r2(r2_z, n, q_rank)
    f_stat = (con_inertia / k_rank) / (unc_inertia / df_res)
    con_eigs = [round(v, 12) for v in _gram_eigenvalues(y_hat, dof)]
    unc_eigs = [round(v, 12) for v in _gram_eigenvalues(y_res, dof)]

    return {
        "adj_r2": round(adj_r2, 12),
        "conditioned_inertia": round(cond_inertia, 12),
        "constrained_eigenvalues": con_eigs,
        "constrained_inertia": round(con_inertia, 12),
        "df_conditioned": q_rank,
        "df_model": k_rank,
        "df_residual": df_res,
        "f_statistic": round(f_stat, 12),
        "r2": round(r2, 12),
        "total_inertia": round(tot_inertia, 12),
        "unconstrained_eigenvalues": unc_eigs,
        "unconstrained_inertia": round(unc_inertia, 12),
    }


def reference_varpart_twoway(
    y: list[list[float]],
    x1: list[list[float]],
    x2: list[list[float]],
) -> dict[str, float]:
    r_a = reference_linear_rda(y, x1)["adj_r2"]
    r_b = reference_linear_rda(y, x2)["adj_r2"]
    x12 = [r1 + r2 for r1, r2 in zip(x1, x2)]
    r_ab = reference_linear_rda(y, x12)["adj_r2"]
    uniq_x1 = r_ab - r_b
    uniq_x2 = r_ab - r_a
    shared = r_a + r_b - r_ab
    resid = 1.0 - r_ab
    return {
        "gross_x1_adj_r2": round(r_a, 12),
        "gross_x12_adj_r2": round(r_ab, 12),
        "gross_x2_adj_r2": round(r_b, 12),
        "residual": round(resid, 12),
        "shared": round(shared, 12),
        "unique_x1": round(uniq_x1, 12),
        "unique_x2": round(uniq_x2, 12),
    }


def build_reference_document() -> dict[str, Any]:
    # 1. Ecological benchmark: first 10 sites x 8 species of vegan's dune meadow dataset
    dune_y = [
        [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        [3.0, 0.0, 0.0, 2.0, 0.0, 3.0, 4.0, 0.0],
        [0.0, 4.0, 0.0, 7.0, 0.0, 2.0, 0.0, 0.0],
        [0.0, 8.0, 0.0, 2.0, 0.0, 2.0, 3.0, 0.0],
        [2.0, 0.0, 0.0, 0.0, 4.0, 2.0, 2.0, 0.0],
        [2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0],
        [2.0, 0.0, 0.0, 0.0, 2.0, 0.0, 2.0, 0.0],
        [0.0, 4.0, 0.0, 5.0, 0.0, 0.0, 0.0, 0.0],
        [0.0, 3.0, 0.0, 3.0, 0.0, 0.0, 0.0, 1.0],
        [4.0, 0.0, 0.0, 0.0, 4.0, 2.0, 4.0, 0.0],
    ]
    dune_a1 = [[2.8], [3.5], [4.3], [4.2], [6.3], [4.3], [2.8], [4.2], [3.7], [3.3]]
    dune_moist = [[1.0], [1.0], [2.0], [2.0], [1.0], [1.0], [1.0], [5.0], [4.0], [2.0]]
    dune_x = [[a[0], m[0]] for a, m in zip(dune_a1, dune_moist)]

    # 2. Microbiome dataset 1: Gut amplicon counts -> CLR (Aitchison geometry)
    gut_counts = [
        [420.0, 310.0, 120.0, 85.0, 45.0, 20.0],
        [395.0, 330.0, 115.0, 90.0, 48.0, 22.0],
        [450.0, 290.0, 110.0, 80.0, 50.0, 20.0],
        [410.0, 305.0, 130.0, 82.0, 49.0, 24.0],
        [140.0, 160.0, 290.0, 210.0, 130.0, 70.0],
        [125.0, 175.0, 310.0, 195.0, 125.0, 70.0],
        [155.0, 150.0, 280.0, 215.0, 135.0, 65.0],
        [135.0, 165.0, 305.0, 205.0, 120.0, 70.0],
        [75.0, 95.0, 220.0, 270.0, 210.0, 130.0],
        [80.0, 90.0, 210.0, 280.0, 215.0, 125.0],
        [70.0, 100.0, 230.0, 265.0, 205.0, 130.0],
        [85.0, 88.0, 215.0, 275.0, 212.0, 125.0],
    ]
    gut_y = clr_transform(gut_counts)
    gut_abx = [[0.0], [0.0], [0.0], [0.0], [1.0], [1.0], [1.0], [1.0], [1.0], [1.0], [1.0], [1.0]]
    gut_fibre = [[28.0], [26.0], [31.0], [29.0], [18.0], [19.0], [17.0], [20.0], [9.0], [8.0], [10.0], [9.5]]
    gut_x = [[a[0], f[0]] for a, f in zip(gut_abx, gut_fibre)]

    # 3. Microbiome dataset 2: Oral microbiome CLR with Condition(batch) partial RDA
    oral_counts = [
        [500.0, 250.0, 120.0, 70.0, 40.0, 20.0],
        [480.0, 270.0, 115.0, 72.0, 42.0, 21.0],
        [520.0, 240.0, 110.0, 68.0, 41.0, 21.0],
        [190.0, 180.0, 260.0, 190.0, 110.0, 70.0],
        [205.0, 175.0, 250.0, 195.0, 108.0, 67.0],
        [185.0, 185.0, 268.0, 188.0, 106.0, 68.0],
        [310.0, 380.0, 150.0, 85.0, 50.0, 25.0],
        [295.0, 395.0, 155.0, 80.0, 52.0, 23.0],
        [320.0, 370.0, 148.0, 86.0, 49.0, 27.0],
        [110.0, 240.0, 310.0, 185.0, 95.0, 60.0],
        [118.0, 232.0, 305.0, 190.0, 97.0, 58.0],
        [105.0, 248.0, 315.0, 180.0, 92.0, 60.0],
    ]
    oral_y = clr_transform(oral_counts)
    oral_status = [[0.0], [0.0], [0.0], [1.0], [1.0], [1.0], [0.0], [0.0], [0.0], [1.0], [1.0], [1.0]]
    oral_batch = [[0.0], [0.0], [0.0], [0.0], [0.0], [0.0], [1.0], [1.0], [1.0], [1.0], [1.0], [1.0]]

    # 4. Microbiome dataset 3: Marine Hellinger-transformed community across salinity, depth & interaction
    marine_counts = [
        [610.0, 220.0, 90.0, 40.0, 20.0, 12.0, 8.0],
        [580.0, 245.0, 95.0, 38.0, 22.0, 11.0, 9.0],
        [430.0, 310.0, 140.0, 65.0, 30.0, 15.0, 10.0],
        [390.0, 330.0, 155.0, 70.0, 28.0, 16.0, 11.0],
        [240.0, 290.0, 230.0, 125.0, 65.0, 30.0, 20.0],
        [210.0, 275.0, 250.0, 140.0, 70.0, 33.0, 22.0],
        [130.0, 195.0, 270.0, 195.0, 115.0, 58.0, 37.0],
        [115.0, 180.0, 280.0, 205.0, 120.0, 62.0, 38.0],
        [65.0, 110.0, 240.0, 255.0, 175.0, 95.0, 60.0],
        [55.0, 102.0, 232.0, 265.0, 182.0, 100.0, 64.0],
    ]
    marine_y = hellinger_transform(marine_counts)
    marine_sal = [[30.1], [30.4], [31.8], [32.1], [33.5], [33.9], [34.8], [35.0], [35.7], [36.0]]
    marine_dep = [[5.0], [8.0], [15.0], [18.0], [35.0], [42.0], [75.0], [85.0], [140.0], [160.0]]
    marine_x = [[s[0], d[0], s[0] * d[0]] for s, d in zip(marine_sal, marine_dep)]

    return {
        "datasets": [
            {
                "description": "vegan dune meadow 10-site x 8-species benchmark with A1 and Moisture",
                "expected_rda": reference_linear_rda(dune_y, dune_x),
                "expected_varpart": reference_varpart_twoway(dune_y, dune_a1, dune_moist),
                "id": "dune_meadow_subset",
                "x": [[round(v, 10) for v in row] for row in dune_x],
                "x1": dune_a1,
                "x2": dune_moist,
                "y": dune_y,
                "z": None,
            },
            {
                "description": "Gut microbiome 12-sample x 6-taxon CLR (Aitchison) ordination across antibiotic exposure and fibre",
                "expected_rda": reference_linear_rda(gut_y, gut_x),
                "expected_varpart": reference_varpart_twoway(gut_y, gut_abx, gut_fibre),
                "id": "microbiome_gut_clr_antibiotic",
                "raw_counts": gut_counts,
                "transform": "clr",
                "x": gut_x,
                "x1": gut_abx,
                "x2": gut_fibre,
                "y": [[round(v, 12) for v in row] for row in gut_y],
                "z": None,
            },
            {
                "description": "Oral microbiome 12-sample x 6-taxon partial CLR RDA with Condition(batch)",
                "expected_rda": reference_linear_rda(oral_y, oral_status, oral_batch),
                "expected_varpart": None,
                "id": "microbiome_oral_partial_batch",
                "raw_counts": oral_counts,
                "transform": "clr",
                "x": oral_status,
                "y": [[round(v, 12) for v in row] for row in oral_y],
                "z": oral_batch,
            },
            {
                "description": "Marine microbiome 10-sample x 7-taxon Hellinger RDA with salinity, depth, and interaction",
                "expected_rda": reference_linear_rda(marine_y, marine_x),
                "expected_varpart": reference_varpart_twoway(marine_y, marine_sal, marine_dep),
                "id": "microbiome_marine_salinity_depth",
                "raw_counts": marine_counts,
                "transform": "hellinger",
                "x": [[round(v, 10) for v in row] for row in marine_x],
                "x1": marine_sal,
                "x2": marine_dep,
                "y": [[round(v, 12) for v in row] for row in marine_y],
                "z": None,
            },
        ],
        "schema_version": "1.0.0",
        "tolerance": 0.000001,
    }


def build_schema_document() -> dict[str, Any]:
    return {
        "$id": "https://github.com/hyperpolymath/MetaManifold-WebUI/blob/main/docs/schemas/constrained-ordination.schema.json",
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "additionalProperties": False,
        "description": "Canonical RFC 7493 I-JSON / RFC 8785 JCS response schema for MetaManifold constrained ordinations (RDA, CCA, CAP, dbRDA).",
        "properties": {
            "adj_r2": {"type": ["number", "null"]},
            "artifact": {
                "additionalProperties": False,
                "properties": {
                    "analysis_id": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
                    "created": {"type": "boolean"},
                },
                "required": ["analysis_id", "created"],
                "type": "object",
            },
            "available_covariates": {"items": {"type": "string"}, "type": "array"},
            "axis_labels": {"items": {"type": "string"}, "maxItems": 2, "minItems": 2, "type": "array"},
            "axis_names": {"items": {"type": "string"}, "maxItems": 2, "minItems": 2, "type": "array"},
            "axis_tests": {"$ref": "#/$defs/termTestArray"},
            "biplot": {
                "additionalProperties": False,
                "properties": {
                    "data": {"items": {"type": "object"}, "type": "array"},
                    "layout": {"type": "object"},
                },
                "required": ["data", "layout"],
                "type": "object",
            },
            "biplot_arrows": {
                "items": {
                    "additionalProperties": False,
                    "properties": {
                        "axis1": {"type": "number"},
                        "axis2": {"type": "number"},
                        "label": {"type": "string"},
                        "length": {"minimum": 0, "type": "number"},
                    },
                    "required": ["label", "axis1", "axis2", "length"],
                    "type": "object",
                },
                "type": "array",
            },
            "cautions": {"items": {"type": "string"}, "type": "array"},
            "centroids": {
                "items": {
                    "additionalProperties": False,
                    "properties": {
                        "axis1": {"type": "number"},
                        "axis2": {"type": "number"},
                        "label": {"type": "string"},
                    },
                    "required": ["label", "axis1", "axis2"],
                    "type": "object",
                },
                "type": "array",
            },
            "condition_terms": {"items": {"type": "string"}, "type": "array"},
            "conditioned_inertia": {"minimum": 0, "type": "number"},
            "conditioned_proportion": {"minimum": 0, "type": "number"},
            "constrained_eigenvalues": {"$ref": "#/$defs/eigenvalueArray"},
            "constrained_inertia": {"minimum": 0, "type": "number"},
            "constrained_proportion": {"minimum": 0, "type": "number"},
            "constrained_terms": {"items": {"type": "string"}, "minItems": 1, "type": "array"},
            "distance": {
                "enum": [
                    "bray",
                    "jaccard",
                    "euclidean",
                    "aitchison",
                    "chisq",
                    "unweighted_unifrac",
                    "weighted_unifrac",
                ],
                "type": "string",
            },
            "formula": {"minLength": 2, "type": "string"},
            "imaginary_inertia": {"minimum": 0, "type": "number"},
            "marginal_tests": {"$ref": "#/$defs/termTestArray"},
            "method": {"enum": ["rda", "cca", "cap", "dbrda"], "type": "string"},
            "n_features": {"minimum": 0, "type": "integer"},
            "n_samples": {"minimum": 3, "type": "integer"},
            "omnibus_test": {
                "additionalProperties": False,
                "properties": {
                    "df_model": {"minimum": 1, "type": "integer"},
                    "df_residual": {"minimum": 1, "type": "integer"},
                    "f_statistic": {"type": ["number", "null"]},
                    "min_p_value": {"exclusiveMinimum": 0, "maximum": 1, "type": "number"},
                    "p_value": {"type": ["number", "null"]},
                    "permutations": {"maximum": 9999, "minimum": 1, "type": "integer"},
                    "text": {"type": "string"},
                    "untestable_reason": {"type": ["string", "null"]},
                    "variance_model": {"type": ["number", "null"]},
                    "variance_residual": {"type": ["number", "null"]},
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
                    "text",
                ],
                "type": "object",
            },
            "provenance": {
                "additionalProperties": True,
                "properties": {
                    "beta_normalisation": {"type": "string"},
                    "blocked": {"type": "boolean"},
                    "condition_terms": {"items": {"type": "string"}, "type": "array"},
                    "constrained_terms": {"items": {"type": "string"}, "type": "array"},
                    "distance": {"type": "string"},
                    "dropped_zero_features": {"minimum": 0, "type": "integer"},
                    "formula": {"type": "string"},
                    "method": {"enum": ["rda", "cca", "cap", "dbrda"], "type": "string"},
                    "multiple_testing_policy": {"type": "string"},
                    "n_features": {"minimum": 0, "type": "integer"},
                    "n_samples": {"minimum": 3, "type": "integer"},
                    "permutations_performed": {"minimum": 1, "type": "integer"},
                    "permutations_requested": {"maximum": 9999, "minimum": 99, "type": "integer"},
                    "rng_kind": {"type": "string"},
                    "scaling": {"enum": [1, 2], "type": "integer"},
                    "scaling_meaning": {"enum": ["distance", "correlation"], "type": "string"},
                    "seed": {"type": "integer"},
                    "software": {
                        "additionalProperties": False,
                        "properties": {
                            "r_package": {"const": "vegan", "type": "string"},
                            "vegan_version": {"type": "string"},
                        },
                        "required": ["r_package", "vegan_version"],
                        "type": "object",
                    },
                    "zero_replacement": {"type": ["object", "null"]},
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
                    "software",
                ],
                "type": "object",
            },
            "r2": {"type": ["number", "null"]},
            "runtime_estimate": {
                "additionalProperties": False,
                "properties": {
                    "estimated_seconds": {"minimum": 0, "type": "number"},
                    "tier": {"enum": ["fast", "moderate", "heavy"], "type": "string"},
                    "warn_five_minutes": {"type": "boolean"},
                },
                "required": ["estimated_seconds", "tier", "warn_five_minutes"],
                "type": "object",
            },
            "scaling": {"enum": [1, 2], "type": "integer"},
            "sites": {
                "items": {
                    "additionalProperties": False,
                    "properties": {
                        "axis1": {"type": "number"},
                        "axis2": {"type": "number"},
                        "sample": {"type": "string"},
                    },
                    "required": ["sample", "axis1", "axis2"],
                    "type": "object",
                },
                "minItems": 3,
                "type": "array",
            },
            "term_tests": {"$ref": "#/$defs/termTestArray"},
            "top_feature_scores": {"items": {"type": "object"}, "type": "array"},
            "total_inertia": {"minimum": 0, "type": "number"},
            "unconstrained_eigenvalues": {"$ref": "#/$defs/eigenvalueArray"},
            "unconstrained_inertia": {"minimum": 0, "type": "number"},
            "unconstrained_proportion": {"minimum": 0, "type": "number"},
            "variance_partitioning": {"type": ["object", "null"]},
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
            "biplot",
        ],
        "title": "ConstrainedOrdinationResult",
        "type": "object",
        "$defs": {
            "eigenvalueArray": {
                "items": {
                    "additionalProperties": False,
                    "properties": {
                        "axis": {"type": "string"},
                        "eigenvalue": {"minimum": 0, "type": "number"},
                        "proportion_constrained": {"minimum": 0, "type": "number"},
                        "proportion_total": {"minimum": 0, "type": "number"},
                    },
                    "required": ["axis", "eigenvalue", "proportion_total"],
                    "type": "object",
                },
                "type": "array",
            },
            "termTestArray": {
                "items": {
                    "additionalProperties": False,
                    "properties": {
                        "df": {"minimum": 0, "type": "integer"},
                        "f_statistic": {"type": ["number", "null"]},
                        "p_value": {"type": ["number", "null"]},
                        "term": {"type": "string"},
                        "untestable_reason": {"type": ["string", "null"]},
                        "variance": {"type": ["number", "null"]},
                    },
                    "required": ["term", "df", "variance", "f_statistic", "p_value", "untestable_reason"],
                    "type": "object",
                },
                "type": "array",
            },
        },
    }


def verify_jcs_file(path: pathlib.Path) -> Any:
    raw = path.read_bytes()
    if not raw.endswith(b"\n") or raw.endswith(b"\n\n"):
        raise AssertionError(f"{path}: must end with exactly one trailing LF")
    text = raw[:-1].decode("utf-8")
    parsed = json.loads(text)
    canonical = jcs_dumps(parsed)
    if text != canonical:
        raise AssertionError(f"{path}: content is not byte-for-byte RFC 8785 JCS")
    return parsed


def verify_kyaml_contract(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    body = [ln for ln in lines if ln.strip() and not ln.strip().startswith("#")]
    if not body or body[0].strip() != "---":
        raise AssertionError(f"{path}: KYAML must open with explicit '---' after SPDX comments")
    if body[1].strip() != "{":
        raise AssertionError(f"{path}: KYAML top-level mapping must use explicit '{{' flow syntax")
    if body[-1].strip() != "}":
        raise AssertionError(f"{path}: KYAML top-level mapping must close with '}}'")
    for req_token in ("rda:", "cca:", "cap:", "dbrda:", '"capscale"', '"aitchison"', '"chisq"', "99", "9999"):
        if req_token not in text:
            raise AssertionError(f"{path}: missing expected contract token {req_token}")
    # Check there are no bare unquoted string values after ':'
    for idx, ln in enumerate(lines, start=1):
        stripped = ln.strip()
        if not stripped or stripped.startswith("#") or stripped in ("---", "{", "}", "},", "],"):
            continue
        m = re.match(r"^[A-Za-z0-9_\"']+:\s*(.+?)\s*,?$", stripped)
        if m:
            val = m.group(1).rstrip(",").strip()
            if val in ("{", "[") or val.startswith('"') or val in ("true", "false", "null"):
                continue
            if re.fullmatch(r"-?[0-9]+(\.[0-9]+)?", val):
                continue
            raise AssertionError(f"{path}:{idx}: unquoted scalar value {val!r} violates KYAML")


def verify_fixture_math(doc: dict[str, Any], tol: float = 1e-9) -> None:
    datasets = doc.get("datasets", [])
    if len(datasets) < 4:
        raise AssertionError(f"Expected >= 4 reference datasets, found {len(datasets)}")
    for ds in datasets:
        ds_id = ds["id"]
        y = ds["y"]
        if ds.get("transform") == "clr":
            y_recomp = clr_transform(ds["raw_counts"])
        elif ds.get("transform") == "hellinger":
            y_recomp = hellinger_transform(ds["raw_counts"])
        else:
            y_recomp = y
        for r1, r2 in zip(y, y_recomp):
            for a, b in zip(r1, r2):
                if abs(a - b) > 1e-10:
                    raise AssertionError(f"{ds_id}: stored transformed matrix drifted from raw_counts")

        actual_rda = reference_linear_rda(y_recomp, ds["x"], ds["z"])
        exp_rda = ds["expected_rda"]
        for key in (
            "total_inertia",
            "conditioned_inertia",
            "constrained_inertia",
            "unconstrained_inertia",
            "r2",
            "adj_r2",
            "f_statistic",
        ):
            if abs(actual_rda[key] - exp_rda[key]) > tol:
                raise AssertionError(
                    f"{ds_id}.{key}: expected {exp_rda[key]}, recomputed {actual_rda[key]}"
                )
        for eig_key in ("constrained_eigenvalues", "unconstrained_eigenvalues"):
            if len(actual_rda[eig_key]) != len(exp_rda[eig_key]):
                raise AssertionError(f"{ds_id}.{eig_key}: length mismatch")
            for a, b in zip(actual_rda[eig_key], exp_rda[eig_key]):
                if abs(a - b) > tol:
                    raise AssertionError(f"{ds_id}.{eig_key}: {a} != {b}")

        # Verify inertia conservation: total == conditioned + constrained + unconstrained
        inertia_sum = (
            actual_rda["conditioned_inertia"]
            + actual_rda["constrained_inertia"]
            + actual_rda["unconstrained_inertia"]
        )
        if abs(actual_rda["total_inertia"] - inertia_sum) > 1e-10:
            raise AssertionError(f"{ds_id}: inertia partition does not sum to total_inertia")

        if ds["expected_varpart"] is not None:
            actual_vp = reference_varpart_twoway(y_recomp, ds["x1"], ds["x2"])
            exp_vp = ds["expected_varpart"]
            for k, v in exp_vp.items():
                if abs(actual_vp[k] - v) > tol:
                    raise AssertionError(f"{ds_id}.varpart.{k}: expected {v}, got {actual_vp[k]}")
            # Verify Peres-Neto identity: [a] + [b] + [c] + [d] == 1
            part_sum = (
                actual_vp["unique_x1"]
                + actual_vp["unique_x2"]
                + actual_vp["shared"]
                + actual_vp["residual"]
            )
            if abs(part_sum - 1.0) > 1e-10:
                raise AssertionError(f"{ds_id}: varpart fractions sum to {part_sum}, expected 1.0")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--generate", action="store_true", help="Write canonical JCS schema and reference fixture")
    ap.add_argument("--check", type=pathlib.Path, default=DEFAULT_FIXTURE, help="Fixture path to verify")
    args = ap.parse_args()

    if args.generate:
        DEFAULT_SCHEMA.parent.mkdir(parents=True, exist_ok=True)
        DEFAULT_FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        DEFAULT_SCHEMA.write_bytes((jcs_dumps(build_schema_document()) + "\n").encode("utf-8"))
        DEFAULT_FIXTURE.write_bytes((jcs_dumps(build_reference_document()) + "\n").encode("utf-8"))

    # Cross-check our JCS serializer against the repo's jcs_oracle.jsonl first
    oracle_path = REPO_ROOT / "test" / "fixtures" / "jcs_oracle.jsonl"
    if oracle_path.exists():
        for idx, line in enumerate(oracle_path.read_text(encoding="utf-8").splitlines(), start=1):
            if not line.strip():
                continue
            parsed = json.loads(line)
            if jcs_dumps(parsed["input"]) != parsed["expected"]:
                raise AssertionError(f"jcs_oracle.jsonl line {idx} mismatch")

    verify_kyaml_contract(DEFAULT_KYAML)
    verify_jcs_file(DEFAULT_SCHEMA)
    fixture_doc = verify_jcs_file(args.check)
    verify_fixture_math(fixture_doc)
    print(
        f"OK: verified {len(fixture_doc['datasets'])} ordination reference datasets, "
        f"JCS schema ({DEFAULT_SCHEMA.name}), and KYAML contract ({DEFAULT_KYAML.name})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
