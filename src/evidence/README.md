# Placement evidence

The study tree viewer can display a query's raw best-placement likelihood weight
ratio (LWR) against an explicit threshold. Open **Placement evidence**, generate
results, then enable **Show evidence markers**. The initial threshold is 0.95.
Markers show query counts: ✓ holds, ✕ fails, ? undecided. Grouped counts do not
constitute a verdict about the clade. The query table includes hidden, unresolved
and unmapped results, reasons, multiplicities and tied best candidates.

The predicate is max(recorded raw candidate LWR) >= threshold. LWR is floating
point and is not the probability that a placement is correct. A valid query below
threshold fails this predicate; it does not establish that its placement is wrong.
Missing weights never become confidence 1. Malformed or incomplete candidate
weights produce undecided results. Required fields and rows must be unambiguous,
weights finite and in [0,1], and their sum within 1e-6 of 1. The checker does not
renormalize or round them. This conservative completeness policy may withhold
results for files containing only a subset of the original candidates.

## Raw and accumulated views

New pipeline publications record the raw file, accumulated file, digests and
available workflow attestation. Evidence is generated from the raw file. On the
accumulated view it is labelled **Raw LWR evidence, mapped here**. gappa can set
accumulated LWR to 1 or drop queries; neither operation changes the stored raw
verdict. For example, raw weights 0.6/0.4 fail a 0.95 threshold even when gappa's
accumulated marker has LWR 1. Absent queries remain in the raw result table.

For an imported file, explicitly confirm that it contains raw placements. An
optional accumulated file must be paired by its exact study-local filename.
Matching requires equal reference tips and rooted topology, and unique matching
query names with the same individual multiplicities. Ambiguous or absent queries
receive no invented mapping. The association records the user's import assertion;
it cannot independently prove that an arbitrary imported file is raw or was
produced by gappa. Run/config/seed/tool provenance is explicitly unavailable for
imports. Existing publications without source metadata can use this import path.
The study's reference-tree copy is context only.

## Storage, freshness and scope

Study sidecars live under trees/.evidence/{raw-file}.json. Source associations
live under trees/.sources/{file}.json. Their schema version is independent of the
saved view version. Sidecars contain the checker version, threshold, tolerance,
source digest, query/candidate identities and reasons, plus the accumulated
mapping and available provenance. These are computed and regression-tested
results; no formal proof certificate is claimed.

The server validates the source digest and recomputes the checker on read.
Replacement, rerun or changed provenance invalidates previous evidence. Managed
uploads and pipeline publications share the evidence publication lock; exact-byte
digests also detect external file changes. The viewer checks freshness on load,
focus and every 15 seconds, and withdraws markers when a check fails or the
loaded tree no longer matches. Reload to display a replaced tree. Re-upload or
republish changed source associations before generating new results.

Rerooting, collapse, rotation, renaming and display filters affect presentation
only. Source files and TreeOps are not modified by evidence generation. Study
evidence never writes into the shared reference library. Raw and mapped evidence
are separate from bootstrap support, differential abundance and exact statistics.

The strict evidence parser preserves the existing split hash and UTF-16 ordering.
It rejects duplicate tip names, ambiguous keys/edges and duplicate JSON keys.
Physical edges retain their jplace edge numbers because multiple edges may have
the same split. Input is limited to 50 MB; sidecars to 10 MB; Newick nesting to
512 and node count to 100,000, with a topology complexity limit of two million
stored tip memberships. Exceeding these limits raises an explicit error.

## API and validation

GET /api/v1/studies/{study}/trees/{file}/evidence returns missing, not_applicable,
invalid, stale or ready. POST on the same path generates raw results; it requires
the loaded source_sha256 and accepts threshold, confirm_raw and an optional
accumulated_file for an unclassified import. The request is limited to 4 KB.
Only plain study-local jplace filenames are accepted. A mapped view must regenerate
through its raw source.

Run focused checks with:

```
julia --project=. test/runtests.jl test_placement_evidence.jl test_tree_evidence.jl
cd frontend
bun test src/tree/evidence.test.ts
bun run build
```

Shared known-answer fixtures compare Julia and TypeScript IDs for ASCII, Unicode,
degree-two roots and unary branches. Regression tests cover threshold boundaries,
malformed evidence, tied candidates, mapping ambiguity, stale/tampered sidecars,
study isolation and immutable query verdicts under display operations.
