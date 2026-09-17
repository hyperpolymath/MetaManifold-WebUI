// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// src/types/domain/index.ts — view-model layer: types the UI reasons about,
// derived from (never a replacement for) the API boundary types.
//
// SOURCE: src/components/annotationShared.ts
// RANK_ORDER is the canonical ordered rank list; its value lives with the
// annotation components — this layer derives the union from it so changing
// the value cannot silently desynchronise the type.
import type { RANK_ORDER } from '../../components/annotationShared'

/** UI label of a taxonomy rank, in RANK_ORDER. */
export type TaxonomyRank = (typeof RANK_ORDER)[number]

/** Contamination-call state of an annotatable sequence. */
export type ContamState = import('../../components/annotationShared').ContamStatus

/**
 * Display model for a run-table row rendered by DataTable: any API table row
 * that additionally guarantees the OTU identifier column.
 *
 * SOURCE: tests/fixtures/run-table-payload.json (committed wire fixture) +
 * src/server/routes/results.jl (rows are DuckDB query results).
 */
export type OtuTableRow = import('../api/tables').TableRow & { OTU: string }
