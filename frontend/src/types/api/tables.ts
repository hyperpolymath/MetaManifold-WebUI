// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/api/tables.ts — boundary types for run results tables.
//
// SOURCE: src/server/routes/results.jl
// Tables are DuckDB query result sets serialised with JSON3; a cell is
// therefore a DuckDB scalar — string, numeric or boolean — or SQL NULL,
// which JSON3 encodes as JSON `null`. Nothing else can reach the wire.
export type TableCell = string | number | boolean | null

/** One row of a results table, keyed by column name. */
export type TableRow = Record<string, TableCell>
