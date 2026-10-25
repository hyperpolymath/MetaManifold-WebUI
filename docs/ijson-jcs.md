# I-JSON/JCS migration (D306)

The reference is [hyperpolymath/ijson-jcs](https://github.com/hyperpolymath/ijson-jcs) (reviewed at `3a9a4ee`). I-JSON (RFC 7493) is an **input/value profile**, not a different JSON object schema; JCS (RFC 8785) is its deterministic **byte encoding**. This migration is incremental: do not relabel ordinary JSON as canonical or silently recompute old IDs.

## First-party boundary implemented here

- Julia `MetaManifold.Canonical.ijson_read(raw)` validates UTF-8, repeated object keys (including escaped aliases at every depth), lone surrogates/noncharacters, non-finite numbers and integer tokens outside ±(2^53−1) **on the raw text**. It returns ordinary JSON3 values. `jcs_bytes` validates emitted values (including noncharacters) and sorts keys by UTF-16 code units, formats ECMAScript numbers and emits no newline. The existing `jcs_sha256` hashes those bytes.
- Validated-statistics request bodies use the strict input helper. Error responses, derived-analysis records, figure documents, tree **view-state sidecars**, and report basket indices use the canonical helpers. Successful validated-statistics responses still pass through `_statistics_json`/`JSON3.write`; those outputs are **not yet JCS-migrated**. Stored derived analyses must be canonical on read; existing correctly persisted JCS records are unchanged. Invalid first-party requests get 400 (the exact-count endpoint still rejects floating *count tokens* with 422).
- The frontend's first-party API POST/PATCH/PUT payloads use `ijsonJcsStringify`, which sorts object keys by UTF-16, preserves array order and refuses unsafe JS numbers, non-finite values, lone surrogates, noncharacters and sparse arrays. Undefined optional object properties are omitted as before. Exact large counts remain decimal **strings**. `frontend/public/config.json` is canonical (plus the optional one-file newline).

Use the upstream `ijson-jcs check frontend/public/config.json` to verify the checked-in config if the Rust CLI is installed. The Julia writer has its own JCS fixture tests, but cross-language equivalence with the Rust binary has **not** been independently verified here.

## Boundaries not yet migrated

Other Oxygen `json(...)` route responses, legacy JSON3 inputs/outputs, pipeline job/QC JSON, DOI receipts and epistemic receipt hashes still use their old serialization. The latter two are part of existing checksums/IDs: switching their byte encoding without an explicit versioned migration would make previously stored receipts unverifiable. External JSON (notably jplace, Plotly, renv metadata and imported report `.json` files) must not be rewritten just because its name ends in `.json`; the owning format and compatibility contract take precedence. Existing figure/view/index documents with merely different whitespace or key order still read; they are written canonically on their next save. Documents with duplicate keys or unsafe values need explicit migration.

Follow-up: audit all remaining first-party route JSON with representative large result sets and tests; decide whether oversized legacy numeric fields become strings and how existing persisted records migrate, then replace their serializers and add an upstream CLI interoperability check to CI. Do **not** automatically JCS-encode opaque upstream/third-party formats or change an established content hash without versioning.

## Staged follow-up

See [format-migration.md](format-migration.md) for pinned tool identities, the reproducible kyq blocker, boundary coverage matrix and raw-byte reference harness. No application-wide or kyq runtime conformance is inferred from preparation tests.
