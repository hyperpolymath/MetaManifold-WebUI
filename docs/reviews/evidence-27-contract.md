# Issue 27: evidence contract review and implementation handover

Reviewed 2026-10-18 against upstream 029fa610b67c987b996627bf4d74e1a264dcc274.
Fork-only design checkpoint; no production implementation or upstream submission.
Recheck current upstream main before implementation.

## Maintainer decisions

[Joshua's answers](https://github.com/JoshuaJewell/MetaManifold-WebUI/issues/27#issuecomment-6236033195)
require stable version-1 tip/split IDs, tested cross-tree identity, raw placement.jplace
as the evidence source, recorded mapping to the accumulated view, study reference
copies as context only, and sidecars. Placement confidence is the natural first
predicate; synthetic fixtures are accepted. A parallel fork UI is permitted, but
upstream CONTRIBUTING requires React. Use the existing React viewer.

## Findings verified in source and probes

Inspected frontend model.ts, model.test.ts, layout.ts, viewDoc.ts, TreeView.tsx,
server/routes/trees.jl, server/routes/phylogeny.jl and pipeline/phylogeny.jl.

1. parseJplace defaults missing LWR to 1. The evidence reader must validate the
   original document before this display fallback can manufacture confidence.
2. Degree-two roots and unary chains can share split IDs across physical edges.
   Keep source edge number and candidate ordinal alongside split ID. Do not use
   splitEdge's first match as a unique physical-edge identity.
3. Duplicate names get suffixes in right-to-left depth-first traversal order.
   Literal suffixes collide: (A,A,A#2); yields effective keys A#2,A,A#2.
   Preserve existing view IDs; reject ambiguous evidence identity.
4. Duplicate edge numbers overwrite edgeByNum entries. Validate unique integer
   edge numbers and every candidate reference, including unsupported root edges.
5. JavaScript uses UTF-16 both for hashing and reference-tip lexical ordering.
   A Julia port must match both, unsigned 32-bit wrapping, logical shifts,
   traversal/suffix order and fixed-width hex. Non-BMP ordering is a trap.
6. Cross-tree matching requires the same unambiguous tip universe and actual
   canonical bipartition. A matching noncryptographic 64-bit hash is not proof.
   Compare tip sets and detect collisions without changing saved-view IDs.
7. Publication uses name-derived slugs and can replace files. Filename suffixes
   cannot establish raw/accumulated pairing, provenance or freshness.
8. Saved views may retain matching operations after a source change; evidence
   must instead withdraw stale results.

The pinned [gappa v0.9.0 source](https://github.com/lczech/gappa/blob/v0.9.0/src/commands/edit/accumulate.cpp)
normalizes per-query weights, sets a surviving accumulated placement's LWR to 1,
and can remove queries that cannot accumulate. This was source inspection, not
execution of gappa. Accumulated LWR must never be read as original confidence.

## Scientific predicate

First implement: "The largest recorded raw candidate LWR for this pquery is at
least the selected threshold." UI label: "Raw best-placement LWR meets threshold".
This is not a posterior probability, significance test, clade truth or a proof
that the placement is correct.

Use an explicit threshold (initial default 0.95), finite and in (0,1], stored with
the result. Keep it distinct from the accumulation threshold. Require an explicit
unique LWR field, nonempty candidates, finite numeric weights in [0,1], valid
edge references and total weight within 1e-6 of 1. Version and record this input
tolerance. Never renormalize input, round before comparison or apply tolerance
to the predicate. This conservative completeness policy must be documented.

Valid input: holds iff max LWR >= threshold; otherwise fails.
Incomplete/invalid query evidence: undecided with reason. Malformed top-level
documents: explicit error, not an empty successful analysis.
Keep tied best candidates as a set; do not invent a unique winning location.

Preserve original pquery/candidate ordinals before display sorting, aliases,
and individual nm multiplicities. Internal keys use source digest plus ordinal;
names alone are not unique keys. Reject contradictory n/nm and malformed counts.
Query results do not automatically become branch or clade verdicts.

LWR remains floating point. Do not invent exact fractions, p/q-values or formal
proof badges. Assurance is "computed; regression-tested" until an actual checked
certificate exists. Test links describe validation, not scientific proof.

## Sidecar and lifecycle contract

Use projects/{study}/trees/.evidence/{raw-file}.json with an independent schema
version. Store study/placement identity; raw filename and exact-byte SHA-256;
reference digest where known; predicate, threshold, tolerance and checker version;
per-query verdict/reason/value/aliases/multiplicities and candidate edge/split/
ordinal references; optional accumulated target digest and mapping; actual run,
tool/config/seed provenance, explicitly unavailable where absent.

Do not invent missing run provenance. Bind all evidence to the exact raw bytes.
On read, validate schema, study/run, digest, checker/predicate settings and, for
mapped rendering, target digest and transformation config. Distinguish missing,
invalid, stale and valid-undecided states. Invalid mapping need not invalidate
current raw results. A stale source withdraws the overlay.

Enforce size limits and study-local validated paths; no arbitrary URL fetching
or paths supplied by a sidecar. Render labels as text. A reference-library route
must never write or serve study evidence.

Generate against a consistent snapshot, then recheck digests before atomic
publication. Coordinate upload/overwrite/delete/pipeline publication: the existing
write lock does not cover every writer. Recheck freshness on every read regardless.
Remove associated sidecars on deletion; invalidate on replacement. Test two-study
isolation, concurrent writes and stale reads.

## Accumulated mapping and display

Record actual pipeline pairing, both digests, rooted source identity, gappa version
and accumulation settings. Imports need explicit pairing and validation; no
inference from "-accumulated". Match aliases/multiplicities only when unique.
Ambiguous names, merged queries, changed multiplicity and missing records remain
unresolved unless producer provenance establishes the mapping.

Map each raw query and its full candidate set to an observed target placement.
Do not assert that each raw edge becomes that edge. Retain absent raw queries in
the evidence listing; absence is neither a failed predicate nor proof of why the
query disappeared.

Label mapped results "Raw LWR evidence, mapped here". Never recompute from target
LWR=1. Example: raw weights 0.6/0.4 and threshold 0.95 yield fails, even if the
accumulated marker's LWR is 1. Dropped queries retain raw results without a target.

Reroot/rename/rotation/collapse/filtering affect presentation only. Use existing
byEdge/pointOnBranch geometry for root halves and unary splicing. Grouped markers
show counts of holds/fails/undecided, not an invented clade verdict; avoid counting
a query twice. Hidden or unmapped evidence remains discoverable in details.

## Sol Medium implementation sequence

1. Strict evidence reader, identity fixtures, ambiguity checks and cross-language
   known-answer vectors if Julia computes IDs. Keep existing IDs unchanged.
2. Raw checker, versioned sidecar, explicit study generation/read endpoints,
   provenance/freshness/atomic publication and negative-path tests.
3. Pipeline pairing and raw-to-accumulated mapping, including dropped and ambiguous
   queries. Incomplete mappings must remain visibly unresolved.
4. Optional React overlay, query details, grouped counts, accessible text/icons and
   explicit missing/stale/error states. Keep evidence separate from TreeOps.
5. Focused tests then relevant full CI; check source immutability and isolation.
   Submit one logical feature from current main with Verified commits. Keep this
   fork audit out of the product PR unless deliberately adapted as documentation.

Commit/push coherent increments. No new statistics or proof dependencies are
needed. Do not close issue 27 for this audit; the feature remains unimplemented.
Return to Astra if identity/mapping semantics or the scientific predicate changes.
Routine implementation/testing can proceed on Sol Medium.

## Acceptance cases

- IDs: ASCII/BMP/non-BMP, UTF-16 ordering, duplicate/literal-suffix names, sibling
  reorder, reroot, degree-two root, unary chain, changed tip sets, hash collisions.
- Input: reordered fields, missing/duplicate LWR, null/string/nonfinite weights,
  invalid ranges/sums, empty candidates, duplicate/missing/root edges, ties, n/nm.
- Predicate: below/equal/above threshold, hand-calculated references, no implicit
  rounding or normalization.
- Mapping: reordered queries/candidates, aliases, ambiguous names/multiplicities,
  dropped queries, changed root/topology, stale source/target, 0.6/0.4-to-1 example.
- Presentation: unchanged evidence under view operations, mixed grouped counts,
  no root-half double counting, accessible hidden/unmapped results.
- Lifecycle: concurrent overwrite/delete/rerun, malformed/oversized sidecars,
  path validation, two-study isolation and no shared reference writes.

## Validation already performed

Eight audit probes passed on bun 1.3.10 against the reviewed model.ts. These
reproduce hazards, not conformance of a future feature. Existing model.test.ts:
17 tests passed, 32 assertions. No production files changed.

Run the audit probes with: bun docs/reviews/evidence-27-probe.ts
Run existing tests with: bun test frontend/src/tree/model.test.ts
