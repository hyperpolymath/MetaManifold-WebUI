<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# DOI publication — test plan and implementation evidence

2026-09-26 · issue #8 · **implementation present; runtime acceptance blocked**.
This is the feature handoff/milestone report, not a claim of successful live minting.

## Executable lanes

From the repository root, with Julia 1.12.5, Bun 1.3.10, `zip`, `jq` and `flock`:

```sh
julia --startup-file=no config/ci/lint_source.jl
julia --project=test/doi -e 'using Pkg; Pkg.instantiate()'
export DOI_CONTRACT_ARTIFACTS="$(mktemp -d)"
julia --project=test/doi test/doi/runtests.jl
bun install --cwd test/doi --frozen-lockfile --ignore-scripts
(cd test/doi && bunx playwright install --with-deps chromium)
bun run --cwd test/doi test
bun run --cwd test/doi test:browser
NICKEL=/path/to/nickel-1.18.0 bash test/doi/check-nickel.sh
```

The isolated Julia environment loads the **actual** Storage, Zenodo, Bundles,
Publications and Web modules, not a reimplementation. A synthetic transport
captures requests and injects failures; it cannot reach Zenodo. Its rendered HTML,
statuses, receipts, CFF and attestation projections feed the schema/browser/Nickel
lanes. A supplied artifact directory must contain outputs; the lanes fail rather
than silently skipping missing artifacts. `PLAYWRIGHT_CHROMIUM_EXECUTABLE` can
select an already-installed Chromium for the browser adapter tests.

For linker/schema/performance-comparator tests only (no Julia artifacts):

```sh
unset DOI_CONTRACT_ARTIFACTS
bun run --cwd test/doi test
```

These pure tests validate synthetic contracts and execute the actual Bash linker
against an isolated fake `gh`. This command alone does **not** validate Julia output.
The browser tests use an explicitly synthetic local HTTP API, even when supplied
with Julia-emitted HTML; server authorization is tested separately by Julia.

With the full scientific/R environment instantiated, run:

```sh
julia --project=. test/runtests.jl
```

That lane includes actual AnalysisConfig/result persistence and bundle generation,
plus Oxygen internal-request tests covering origin/CSRF/body restrictions,
prepare/publish/download, archive bytes, mutation protection and disabled credentials.
The isolated suite additionally exercises the real HTTP.jl streamed response writer
across a local socket. Neither is replaced by successful JavaScript tests.

### Coverage map

| Area | Contracts |
|---|---|
| Metadata & input | explicit creators/licence/date; ORCID checksum; exact config/result binding; mock/empty/failed rejection; allowlisted files; symlink and checksum refusal |
| Credentials | redacted client display/errors; fixed origins; no token in public state/files; redirect/bucket-origin refusal; no browser token or localStorage |
| Retry protocol | 429/Retry-After seconds/date/overflow; bounded retries; reopened upload stream; ambiguous create/publish responses not replayed |
| Durability | write-ahead transitions, immutable ZIP, restarted clients, lock exclusion, interrupted upload resume, creation recovery, accepted-but-pending publication, uncertain publication reconciliation |
| Provenance | exact archive SHA-256/MD5/size; remote metadata/files; separate receipt; corrupted receipt/citation refusal; unchanged scientific bytes; sandbox versus production |
| Browser | Evidence Mode, explicit payload, mock option disabled, narrow viewport, untrusted text rendered as text, cancel/wrong phrase/acknowledgement, one publish request, uncertainty recovery, disabled mode, distinct badges |
| GitHub helper | default offline dry run; valid production only; preserved notes; repeatable assets/item updates; partial failure; incomplete listing/malformed markers refusal; official CFF 1.2.0 validation |
| Formats | draft-2020-12 JSON validation and negative cases; actual-output roundtrips; Nickel contract evaluation/negative cases; reserved JSON/Nickel/DEED vocabulary and projection checks |

The DEED projection is structurally checked against the emitted attestation; there
is no claim of a general CHORA/DEED engine evaluation. The Nickel CLI is pinned by
version **and SHA-256** in `.github/workflows/doi.yml`. The official CFF schema is
vendored with attribution to remove a network dependency from citation tests.

## Performance and the >10% gate

```sh
julia --project=test/doi bench/doi/benchmark.jl > /tmp/doi-current.json
bun bench/doi/compare.js /private/controlled-host-baseline.json /tmp/doi-current.json
```

The new warmed, credential-free microbenchmarks cover metadata, file checksums,
SHA-256 hashing, bounded downloads, prepared replay and published replay. Replays
must issue **zero network requests**, and an 8 MiB streamed download has a 2 MiB
allocation ceiling. Archive downloads use a 1 MiB buffer, not `read(archive)`.
Hash verification is intentionally O(archive size); creation also incurs ZIP,
checksum and durable-write costs. These are publication actions, not timed
scientific estimation. Benchmark numbers do not represent network latency or
scientific-method performance.

The comparator fails on **>10% time or allocation growth**, mismatched runtime/CPU/
OS/architecture/thread/sample/workload identity, missing cases or invalid numbers.
Its tests exercise both passing and failing paths. It never creates a baseline.
Preserve a reviewed first measurement from a controlled host; compare subsequent
changes on that same environment. A reviewed `bench/doi/baseline.json` enables the
comparison in the DOI workflow. Until one exists, CI emits a warning and retains
an **informational** measurement, not a fabricated regression verdict.

**No DOI timing or allocation measurement has been obtained in this session.**
The first Julia benchmark baseline and confirmation of the requested regression
budget remain acceptance work. Existing frontend benchmark checksums pass, but
are not evidence of DOI backend performance. Existing scientific benchmarks remain
in the full CI lane; this feature does not relabel their informational timing as a
new performance guarantee.

## Evidence available in this implementation session

- Frontend typecheck and existing tests: **599 pass, 5 pre-existing TODO, 0 fail**;
  3,368 assertions; seven benchmark checksums passed.
- New offline linker, JSON Schema, official CFF and comparator tests:
  **15 pass, 0 fail**, 121 assertions. The fake gh enforces the distinct `DI_`
  draft-content ID (not the `PVTI_` project-item ID) required by the real CLI.
- Chromium browser adapter checks: **4 pass, 0 fail**, against a local synthetic API and an
  **adapter-only HTML fixture derived from the Julia source template**. Julia was
  not executed to produce that local fixture. CI instead requires the real Julia
  renderer outputs. This proves adapter interaction behaviour, not Julia rendering
  or end-to-end Zenodo compatibility.
- Tree-sitter: **124 tracked Julia sources, 0 syntax findings**. Shell/JavaScript
  syntax, licence, whitespace and blob-hygiene gates pass. These provide static
  evidence only. They do not prove Julia dispatch, package loading or runtime tests.
- Root/test manifests retain pinned versions; project hashes were calculated using
  the Julia 1.12 Pkg algorithm and checked against the original root hash. The
  isolated manifest is the dependency closure of the root. **Pkg instantiate/resolve
  has not been run here.** A Julia-enabled runner must confirm both environments.

### External execution blocker

GitHub Actions run
[36207063201](https://github.com/hyperpolymath/MetaManifold-WebUI/actions/runs/36207063201)
was rejected **before any jobs started** with:

> Actor is not allowed to trigger Actions workflows. Workflow file: '.github/workflows/doi.yml'.

There are no Julia job logs or passing checks from that run. The sandbox has no
Julia runtime, and allowed download attempts failed. Nickel release-binary access
also failed locally. An authorized repository actor must resolve the Actions
policy or run the documented lanes on a provisioned machine. Do not treat this as
a failing application test or work around it by weakening gates.

## Production acceptance checklist

- [ ] Run isolated Julia, real-output schema/Nickel/browser, and full-app/Oxygen tests.
- [ ] Instantiate the pinned root/isolated manifests without unexpected resolution.
- [ ] Record a real controlled-host DOI performance baseline; confirm memory limits
      and the >10% comparator against later measurements.
- [ ] With operator-approved credentials, prepare a **sandbox** fixture, inspect the
      exact ZIP and API response contract, explicitly confirm sandbox publication,
      reconcile/restart, and verify the returned identifier. Confirm licence IDs
      and remote metadata normalization against the current service.
- [ ] Review authentication, secret injection, privacy review and backup/restore.
- [ ] Only then enable production, with separate credentials and explicit human
      confirmation for the intended real record.

No real Zenodo upload/publication, DOI mint, release edit or project-item write was
performed for verification. The issue must not be closed on the strength of static
checks alone.
