<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Issue #300 — two-tree static and runtime evidence

Status: research report, not a security verdict, not a Hypatia verification, and
not a proposal to adopt fork CI/estate policy upstream.

## 1. Question and boundaries

Compare the pinned upstream and fork source trees with Panic Attack and Pons
Asinorum, then separate scanner heuristics from observed behaviour and intentional
fork differences. No live human/patient data, SSH endpoint, DOI publication, or
destructive Panic `attack`/`assault` mode was used. The only network operations
were source/dependency retrieval and encrypted evidence transport.

Measured tips:

| Tree | Revision |
| --- | --- |
| upstream `JoshuaJewell/MetaManifold-WebUI` | `a325589d3d318847c15b21cd34fb7d6e7a6d2f7b` |
| fork `hyperpolymath/MetaManifold-WebUI` | `fb10d66410ac018b41553d2b1c9de143744de2fb` |
| merge base | `257bcdec2db0d4231ed9d5b160b5caa623485681` |

Git reports 49 upstream-only and 128 fork-only commits. The default rename-aware
diff reports 278 changed paths; `--no-renames` reports 279 because the occupancy
test was moved. These are inventory counts, not defect counts.

## 2. Reproducible collection

The reusable harness is configuration-driven:

- `config/evidence/issue-300.json` — pins, runtime versions, selected tests.
- `scripts/evidence/collect-two-tree.sh` — detached-worktree static collection.
- `scripts/evidence/test-two-tree.sh` — targeted Julia/R witnesses and synthetic
  SSH/SCP fault injection.
- `scripts/evidence/compare-two-tree.jl`, `r-structure.R`, `ts-structure.ts` —
  parse-only structural adapters and provenance correlation.
- `.github/workflows/two-tree-evidence.yml` — manual collection workflow.

Both scanners were built from clean detached source at the configured revisions
with Rust 1.90.0 and `cargo install --locked`:

| Tool | Source revision | Reported version |
| --- | --- | --- |
| Panic Attack | `be6ac46716eaf049570ec4966f4ae4699b319689` | `panic-attack 2.5.5` |
| Pons Asinorum | `84f58f910de7020b79450f2c2643599fe7760f73` | `pons 0.1.0`, `source_dirty=false` |

Commands (run from each detached tree, no project suppression configuration):

```sh
panic-attack assail . --headless --fail-on-incomplete -o <report.json>
pons scan . --format json --no-speculative --fail-on-skips
pons scan . --format sarif --no-speculative --fail-on-skips
pons validate-report <report.json>
```

Panic `assail` at this pin writes `AssailReport` JSON; its SARIF renderer belongs
to the separate `assault` command, which was not run. Pons JSON and SARIF were
both archived. JSON/SARIF exit codes were required to match.

## 3. Coverage and scanner output

All four static scans completed with exit 2 because coverage was partial. Exit 2
is preserved as data; it is not a pass and not an operational failure.

| Measure | upstream | fork |
| --- | ---: | ---: |
| Panic candidate files | 264 | 394 |
| Panic analyzed files | 225 | 329 |
| Panic weak points | 38 | 45 |
| Pons analyzed files | 109 | 131 |
| Pons unsupported inventory entries | 151 | 254 |
| Pons parse-error entries | 1 | 2 |
| Pons findings | 8 | 0 |
| Pons DATAFLOW / PROTOCOL findings | 0 / 0 | 0 / 0 |

Pons analyzed TypeScript/TSX (and JavaScript/Python where present). Julia and R
remain explicitly unsupported: 105/9 upstream and 154/12 fork inventory entries.
Pons's Python-only CFG/dataflow at this pin cannot establish Julia/R semantics.
Panic's Julia checks are substring/heuristic checks, not Julia parsing or
dispatch/dataflow proof. Its `complete`/`partial` status describes declared input
scope, not application assurance.

Two TSX files were Pons parse-errors but parsed successfully with the measured
tree's frozen TypeScript compiler in the sibling adapter: upstream
`frontend/src/components/DiversityPanel.tsx`; fork that file plus
`frontend/src/components/ConstrainedOrdinationPanel.tsx`. Treat these as parser
coverage disagreements, not application syntax defects.

## 4. High-severity triage

Every Panic High/Critical occurrence was manually inspected before any proposal.
No non-public vulnerability was confirmed; therefore no public exploit details or
private advisory were created.

| Finding | Provenance | Manual result | Classification |
| --- | --- | --- | --- |
| Critical `HardcodedSecret`, `scripts/tests/test-scanner-boundaries.sh` | fork-added | The file constructs a disposable synthetic credential at runtime and asserts redaction; no committed credential value. | scanner false positive |
| High `DynamicCodeExecution`, `scripts/check-julia-syntax.jl` | fork-added | Uses `Meta.parse` only to reject malformed Julia; does not evaluate parsed code. | scanner false positive |
| High `DynamicCodeExecution`, `src/analysis/analysis.jl`, `differential.jl`, `core/provenance.jl`, `pipeline/dada2/context.jl` | shared/changed paths | Panic matches substrings such as `reval`/`prevalence`/`parse`; selected sites are RCall evaluation or ordinary parsing, not Julia `eval` of request data. RCall strings still require the existing input-validation boundary. | heuristic, not a confirmed injection defect |
| High `DynamicCodeExecution`, `src/core/r_runtime.jl` | upstream-only occurrence at these tips | Shared R runtime uses `RCall.reval` for a fixed package-presence probe. | heuristic / intentional R boundary |
| High `DynamicCodeExecution`, `src/analysis/ordination.jl` | fork-added | Formula text is passed to R through the constrained-ordination path; no Julia `eval`. Formula validation and R-side boundary remain the relevant review surface. | heuristic / unverified hypothesis, not confirmed |
| High `DynamicCodeExecution`, test files | both | Test-only RCall/parse fixtures; Panic's file-level detector does not resolve call context. | test-context heuristic |

Pons's eight upstream findings are all `string-concat-in-loop` WARNs in
`frontend/src/tree/TreeShapes.tsx` and `model.ts`. The loops build SVG path strings
and parse Newick labels; they are performance heuristics, not correctness or
security defects. The fork changed both blobs and no longer emits those exact
occurrences. Do not port a rewrite without a benchmark on representative trees.

Medium Panic findings are dominated by test-only `@test x isa Y` / JSON.parse
count heuristics, local `http://` test origins, and FFI counts. The fork-only
`CommandInjection` warning on `scripts/check-governance-contract.sh` counts shell
expansions; inspection found fixed repository paths and quoted variables in the
selected expansions, not an external-input command boundary. These remain
heuristics unless a concrete failing witness is produced.

## 5. Structural and provenance comparison

The comparison uses stable path + Git blob + normalized AST + syntactic
call/import edges. It does not use line/token similarity as a semantic metric.
Blob identity is strong byte evidence; AST equality is not semantic equivalence;
missing AST coverage is `null`, not equal. Call edges are unresolved syntactic
names, and there is no cross-language taint proof.

Across the 489-path union, base-relative provenance is:

| Provenance | Paths |
| --- | ---: |
| shared unchanged since base | 191 |
| fork-added | 184 |
| both changed to different bytes | 45 |
| fork-changed | 29 |
| both changed to identical bytes | 19 |
| upstream-changed | 18 |
| upstream-added | 3 |

Exact-message finding correlation (91 occurrences, 62 groups) gives 10
both-identical-blob, 13 both-changed-blob, 23 upstream-only, and 22 fork-only
occurrences. Correlation is not a claim that changed semantics are equivalent.

Key shared/changed anchors:

| Path | upstream blob | fork blob | Implication |
| --- | --- | --- | --- |
| `src/pipeline/remote_exec.jl` | `106c5965…` | `106c5965…` | shared transport/lifecycle code; upstream-first fixes are portable |
| `src/server/routes/databases.jl` | `2d22fd0e…` | `2d22fd0e…` | shared validate-before-atomic-write route |
| `src/server/server.jl` | `e38616c8…` | `2a543ec9…` | fork adds JCS responses, body-copy JSON parsing, BadRequest mapping, literal-IP wildcard origin guard, extra routes |
| `src/analysis/differential.jl` | `b3fe3938…` | `b9bec61b…` | fork adds two-part/occupancy/compositional methods; do not wholesale cherry-pick |
| `src/core/provenance.jl` | `b28912d4…` | `637332f5…` | fork adds FastTree stderr probe and R package-name guard |
| `test/unit/test_server_security.jl` | `2bb7086d…` | `d8ba0ab6…` | fork adds negative origin/rebinding/Unicode/JSON-shape tests |

## 6. Risk map

| Area | Origin / propagation | Evidence and impact |
| --- | --- | --- |
| API/server | shared router; fork middleware/route deltas | Fork malformed-JSON and origin guards are intentional hardening with negative tests. Shared trusted-local-service boundary remains; not a public multi-tenant claim. |
| Scientific inference | shared RCall boundary; fork method expansion | Fork differential/ordination additions change statistical surface and dependency requirements. Targeted tests exercise known references and R parity; unsupported Julia/R static semantics remain a gap. |
| SSH/job lifecycle | shared `RemoteExec`, `JobQueue`, remote stage selection | Per-call staging, upload size verification, signal trap, cleanup retry, and `.part` download rename are shared. Synthetic faults confirm upload truncation and remote failure are refused with cleanup; a zero-exit truncated download is currently accepted (see §7). Job tests cover exclusivity, cancellation unwinding, terminal states. |
| Frontend | shared React/TS; fork panels/utilities | bun tests/typecheck pass at both pins. Pons TSX parse disagreements are tool coverage gaps, not build failures. |
| Proof/CI/governance | fork-added estate lanes | Advisory Hypatia/DEED/K9/Scorecard/secret-scanner/format lanes are fork policy, not upstream acceptance criteria. No scanner output was promoted to verified evidence or an automatic issue/rewrite. |
| DOI/exports | fork-added | Disabled-by-default, fixed origins, token/redaction/receipt guards; tests use synthetic disabled configuration and perform no live publication. |

## 7. Runtime witnesses and safe fault injection

Runtimes: Julia 1.12.5, R 4.5.0, bun 1.3.10 (`1.3.10+30e609e08`). Julia
`Project.toml`/`Manifest.toml` are byte-identical at the tips. R locks differ by
fork-added packages; common package versions match. Each tree is restored into
its own renv project library in the final harness.

Frontend witnesses (both pins): frozen install exit 0; `bun test src` and
`bun run typecheck` exit 0. upstream: 47 pass / 0 fail / 119 expects / 8 files.
fork: 81 pass / 0 fail / 249 expects / 12 files.

R witness: `test/unit/test_dada2_tables.R` exit 0 at both pins (base-R join and
five exact CSV fixtures; no DADA2/dplyr load).

The first full targeted Julia run was not green: upstream selected a fork-only
`canonical` test (harness configuration error, corrected); fork had 1958 pass /
7 fail / 1 error / 21 broken. The failures were environment/selection witnesses:
absent external bioinformatics binaries under `CI=true`, and glmGamPoi not visible
to embedded R because the first harness restored a shared system library instead
of the project renv library. The final harness uses `CI=false` loud-skip semantics
for absent external binaries, per-tree renv libraries, and fork-only test
selection. It does not claim the repository's full CI suite passed.

Synthetic SSH/SCP fault injection (`scripts/evidence/fault-injection.jl`) uses
fake executables confined to a temporary directory and never opens a socket.
Observed shared `RemoteExec` behaviour:

| Fault | Observed result |
| --- | --- |
| success | output returned; staging cleanup observed |
| upload truncated | error names truncation; no remote command output; cleanup observed |
| remote command exit 23 | failure propagated; cleanup observed |
| download truncated but scp exits 0 | **accepted**; local `.part` renamed to final output |

The last row is an observed integrity gap in the shared transport wrapper, not a
scanner heuristic. It does not require a live SSH exploit: a buggy/malicious
transport that exits zero after a short write can leave a short checkpoint that
looks current. A narrow upstream-ready proposal is to verify downloaded byte
count (or content hash) against the remote file before renaming `.part` to final.
This is a data-integrity proposal, not a confirmed remote-code-execution finding.

## 8. Proposals and upstream fit

| Proposal | Benefit | Friction / cost | Regression risk | Licence/dependency fit | Reversal |
| --- | --- | --- | --- | --- | --- |
| Verify remote download size/hash before final rename | closes observed short-download acceptance; protects checkpoint integrity | one extra remote stat/hash per output; small CI fault test | low if optional outputs and error messages preserved; must not break legitimate zero-byte outputs | AGPL-compatible Julia; no new dependency | revert the verification commit; `.part` rename remains |
| Port fork R package-name guard to shared provenance | rejects injection/path/whitespace/NUL before R interpolation | tiny; existing synthetic tests | low; valid package names unchanged | AGPL-compatible; no new dependency | revert guard and tests together |
| Port selected fork malformed-JSON/origin negative tests | strengthens shared trusted-local boundary | small test-only PR; no new runtime dependency | low; may expose existing 500s that should become 400s | AGPL-compatible tests | revert test commit |
| Benchmark Pons string-concat hot spots before rewrite | avoids heuristic-driven performance churn | requires representative tree/Newick fixtures | medium if SVG path semantics change | no new dependency | keep original if no measured win |
| Fork DOI/ordination/governance lanes | fork-specific research/policy value | high review and maintenance cost upstream | not upstream-ready as a bundle | mixed AGPL/MPL/CC BY-SA; estate pins not upstream policy | keep fork-only; do not cherry-pick wholesale |

Per upstream `CONTRIBUTING.md`, any upstream PR must branch from current upstream
main, contain one logical change, pass upstream CI, state versions/tests/limits,
and avoid generated/vendored files or fork governance imposition. No upstream PR
was opened from this research branch.

## 9. Evidence archive and limitations

The manual workflow seals the raw output directory with SHA-256, encrypts it with
CMS AES-256-CBC to an ephemeral operator certificate, uploads a 14-day ciphertext
artifact, and publishes the ciphertext as an immutable Git blob. The private key
never leaves the operator workspace. Raw reports are not published untriaged.

First successful static/runtime archive (run `41364756791`, harness
`8416691d156ccf74ffd503cd5fff1fee5091162a`):

- Git blob: `9e37217895ac17c993050d63ffa8972f2d1ac64c`
- CMS SHA-256: `c9d653302961c7cb010335471a5b945cbac9b09260df269962e631990f0ec9de`
- plaintext tar SHA-256 before encryption: `55e754488a253c40b84d31469293dad6f9537fa1272091688ad386989d8e6622`
- Panic binary SHA-256: `05b4eef20024a521de36887523d0ba66cabef5c344b13aff1916828324aebcef`
- Pons binary SHA-256: `93aeb2655507f6c98508183795025a9c07cb4cc2da0293a4e7fb719129effa7a`

Limitations that remain first-class:

1. Julia/R have no Pons semantic/dataflow coverage; Panic Julia checks are heuristic.
2. Pons source-derived typestate is still pending; trace checks do not substitute.
3. Syntactic call/import edges do not resolve Julia dispatch, R evaluation, or TS types.
4. No cross-language taint proof or live SSH/DOI/patient-data exercise was performed.
5. Partial coverage and parser disagreements are not passes.
6. The first archive records a harness configuration/environment failure; the final
   harness corrects selection and R isolation and adds the synthetic fault witness.
7. A green workflow or zero findings in a supported subset is not whole-application
   assurance and is not Hypatia verified evidence.
