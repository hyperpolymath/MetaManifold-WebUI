<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# JSON/KYAML migration: staged evidence and blockers

## Status and order

This is preparation, not completed adoption. No application parser, persisted
record, configuration file or workflow dialect is migrated by this change.

| Stage | State | Exit evidence required |
| --- | --- | --- |
| 1. Working kyq | **BLOCKED** | Real compiler checks including imports; executable build/tests; native/WASM IO; isolated-prefix installation |
| 2. Conformance corpus | JSON raw-byte characterization harness prepared; initial pinned reference run passed; KYAML/runtime equivalence not verified | Installed-artifact tests, differential Julia/JS tests, pinned KYAML profile, comment-preservation/mutation proof, resource limits |
| 3. Shared adapters and structural gates | Not started | Explicit schemas/error mapping; replace workflow regex decisions with parser queries |
| 4. Application migration | Not started | Boundary-by-boundary tests; precision, data and old-ID compatibility |
| 5. Workflow conversion | Not started | Comment association/idempotence; actionlint, bot compatibility, real hosted execution |

Do not treat a passing preparation workflow as permission to skip stage 1.
Kubernetes lint/schema validation is an optional layer, not a prerequisite for
parsing an ordinary MetaManifold configuration document.

## Reproduced upstream blocker (2026-10-23)

Source identities are recorded in `config/format-tools.toml`:

- kyq `d448abd1f6534abf703db8a89e3d2247e16ee179`.
- AffineScript **0.1.1**, source `26cdb43e141a5fdce5408e00b8baca7df6862cb8`.
- ijson-jcs `3a9a4ee326a968a32b2f152b4faec243a2d00765`.
- Source-probe runner `just 1.56.0`.

On clean kyq source, `just build`, `just wasm`, `just test` and `just install`
each exited **1**, reporting that the work is not implemented. This reproduces
the recipe fencing, **not** the compiler's syntax diagnosis. The available
v0.2.0 AffineScript release has no binary assets. Downloading the v0.1.1 binary
and checksum failed because the sandbox cannot reach GitHub's release-asset
host. OCaml/opam/dune are not installed. Compiler checks and runtime conformance
are **NOT RUN**; no compiler or placeholder artifact was installed.

The source probe intentionally does **not** run installation: an isolated-prefix
contract has not been established. The manually attempted install recipe above
failed without installing anything. Clone/build dependencies outside the
application checkout; do not vendor upstream source or tool binaries here.

Upstream implementation and acceptance criteria are tracked in
[kyq issue #11](https://github.com/metadatastician/kyq/issues/11). Fixing the
AffineScript implementation belongs there; this repository does not silently
replace it with another language or publish another tool under the kyq name.

Reproduce using a clean clone at the pinned commit:

```sh
python3 scripts/formats/probe_kyq.py --source /path/to/kyq --just /path/to/just
```

Probe exit codes: 0 means only the three source recipes returned success;
1 means a recipe failed; 2 means a missing tool, wrong pin, dirty source or
infrastructure failure. Even 0 does not establish parser/CLI/installation
conformance. The tool prints those missing obligations explicitly.

## Repository boundary coverage matrix

Generate locations without printing source lines or study/credential values:

```sh
python3 scripts/formats/inventory.py > /tmp/format-boundaries.tsv
```

The inventory includes tracked and non-ignored new files, hidden workflows and
lockfiles. It does not follow symlinks. Its regex hits are **lexical candidates**,
including possible comments/test strings; aliases and dynamic dispatch need
manual inspection. Routing buckets are not ownership decisions or conformance
verdicts. Do not turn this search into a regex-based YAML gate. Generated,
ignored and external files are outside this census, not automatically compliant.

| Boundary / paths | Classification and current evidence | Migration obligation |
| --- | --- | --- |
| `src/canonical.jl` | First-party strict-input/JCS adapter, its own fixtures; Rust equivalence not established locally | Compare raw-input acceptance and exact bytes against pinned reference; bound depth/size; characterize numeric policy |
| `src/server/server.jl`: `_request_json`, `_read_json_object`, `_request_source` | First-party input; ordinary JSON3 parsing remains, including body inspection outside the route parser | Parse/validate original bytes once; preserve body/empty-body contracts; stable 400/413/422 behavior; do not classify internal faults as client errors |
| `src/server/routes/validated_statistics.jl` | Strict `ijson_read` plus separate exact-count token checks on input; `_statistics_json` still uses ordinary JSON3 output | Preserve integral-count lexical policy and decimal strings; migrate output only after number-field audit |
| Other `src/server/routes/*.jl` | Mixed request parsing, Oxygen responses, persisted documents and imported third-party data | Classify each operation, not only the module; explicit schemas and semantic tests |
| `frontend/src/api/client.ts`, `ijsonJcs.ts` | Canonical first-party request output; responses still use `res.json()` | Validate response text before duplicate keys/numeric tokens are lost; include error/config responses and 204/empty cases |
| `frontend/src/tree/model.ts`, figure/charts and component JSON | Mixed jplace/Plotly, display/cache keys and first-party state | Separate opaque imports, display-only JSON and actual serialization boundaries; preserve array order and external contracts |
| `src/core/doi.jl`, `epistemic.jl`, `provenance.jl` | Legacy identity-sensitive receipts/hashes and YAML provenance | Version encoding changes, retain old verification, never silently recompute old IDs |
| `src/analysis/derived_analyses.jl`, figure/view/report storage | First-party canonicalized storage at selected boundaries | Compare reference bytes; preserve saved-record read compatibility and corruption diagnostics |
| `src/server/jobs.jl`, `src/pipeline/phylogeny*`, QC files | First-party generated JSON/state, some permissive reads | Define schemas, valid numeric/missing-value policy, bounded reads and atomic writes |
| `src/core/config.jl`, `*_library.jl`, `databases.jl`, pipeline YAML calls | Application-owned YAML with config cascades and generated run configs | KYAML emission/validation, legacy YAML import policy, null/type distinctions, deterministic hashing and file discovery |
| `config/**`, sample `data/**`, generated user/study/run configs | First-party configuration plus user-owned legacy material | Review ownership before rewriting; extension support, safe migration/backups, old paths and merge precedence |
| `.github/**`, `codecov.yml` | Workflow/service-consumed YAML; mixed human/bot ownership | Structural readers first; preserve permissions, pin comments, multiline shell and expressions; retain required consumer extensions |
| `scripts/check-governance-contract.sh` and its mutations | Line-oriented workflow assertions; tests assume block YAML | Query parsed structure; block/flow parity, run-body/comment decoys, duplicate-key and missing-parser mutations |
| `bench/**`, `scripts/*.jl`, `docs/occupancy/*.yml` | Benchmarks, baselines, references and tooling YAML/JSON | Preserve independent oracles and measured baselines; errors must name files without silently substituting empty results |
| `test/**` | Positive/negative fixtures and independent reference readers | Preserve invalid raw fixtures; don't canonicalize away the defect a test is meant to exercise |
| `renv.lock`, `renv/settings.json`, `frontend/package.json`, `bun.lock`, `tsconfig.json` | External-tool-owned document contracts | Verify consumer support; do not mass-rewrite or claim arbitrary exact numbers are portable |
| `.gitbot-fleet/**`, K9 reports, CI artifacts | First-party governance evidence with external renderer involvement | Audit actual renderer bytes and schema; no general jq-as-JCS fallback without a constrained, tested equivalence claim |
| Unclassified hits/new files | **Untriaged**, not exempt | Add explicit ownership/schema/compatibility decisions during the relevant implementation stage |

"Throughout the repository" includes the runtime, generated files, installers,
examples and CI—not just checked-in extensions. Third-party data and invalid test
fixtures stay explicit exceptions, never hidden automatic passes.

## Raw-byte JSON characterization

The 34-case corpus is TOML so it can carry invalid JSON tokens and hex-encoded
invalid UTF-8 without a JSON loader normalizing the evidence. It covers decoded
duplicate keys, nested duplicates, UTF-16 sorting, surrogate pairs/noncharacters,
escaped and raw controls, integer boundaries, beyond-uint64 counts, exponent
thresholds, negative zero, array order, trailing input and truncation.

```sh
python3 scripts/formats/conformance.py --tool /path/to/ijson-jcs
python3 -m unittest discover -s scripts/tests -p 'test_format*.py' -v
```

The protocol is the existing ijson-jcs `canon`: original bytes on stdin, exact
canonical bytes with no newline on stdout, exit 0 for valid input, exit 2 and
empty stdout for invalid input. Crashes, arbitrary nonzero exits, timeouts,
missing tools, changed byte order and extra newlines cannot pass. This runner
implements no parser/canonicalizer of its own. A future kyq adapter may implement
this protocol; it is **not** a claim that kyq has a `canon` command today.

The subprocess runner accepts only named installed tools (`ijson-jcs`, a future
`kyq-json-adapter`, `git`, `just`) with closed argument protocols. It rejects
arbitrary commands/flags and symlinks to unrelated interpreters. These are trusted
installed executables, not sandboxed plugins. Corpus paths are repository
constants/test fixtures, never CLI-supplied paths. The runner limits input/output
bytes and wall time, keeps diagnostics
out of logs and kills the process group on completion/failure. It currently
supports POSIX hosts. These harness budgets are **not** parser resource limits
in the application. Fake subprocesses in unit tests test the harness only.

The preparation workflow builds the real pinned Rust CLI with locked dependencies
and an explicit Rust release, then runs the corpus. The initial hosted run
[39999978128](https://github.com/hyperpolymath/MetaManifold-WebUI/actions/runs/39999978128)
built the pinned CLI and passed all 34 cases at `f0a00cc`. Subsequent harness
changes must rerun that job. Local Rust execution is not claimed (Rust/cargo are
absent). Failures remain failures; there is no permissive
parser or sorted-jq fallback. Exit 0 means corpus compatibility at this pin, not
complete RFC coverage, safe installation of kyq or application-wide adoption.

## Still unresolved before stage 3

- Reconcile Julia/JS/reference acceptance of integer-valued binary64 numbers,
  including `1e21`, and representation changes such as `1e20` producing an
  integer-looking canonical token. The initial one-pass corpus is not a proof
  that every reference output can be reparsed under every adapter policy.
- Add installed-artifact Julia/JS differential tests, number-roundtrip/closure
  tests, fuzz/property tests, underflow/boundary cases and large scientific data.
- Pin the exact KYAML profile and distinguish it from merely valid YAML or a
  formatter's dialect. Prove comment association and idempotence with mutants.
- Establish isolated install, actual WASM/native IO, tool capability reporting,
  artifact verification, parser limits and fail-closed dependency handling.
- Only then change application adapters, followed by application files and
  finally workflows. Preserve existing licensing, scientific results and IDs.
