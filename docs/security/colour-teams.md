<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# CyBOK-referenced colour-team exercise

Companion to [`recon-report.md`](recon-report.md) and
[`ultraplan-secure-private.md`](ultraplan-secure-private.md). Finding IDs (`SEC-nn`) refer to the recon
report.

## 0. What this is, and what it is not

CyBOK is a **body of knowledge** (21 knowledge areas, v1.1 July 2021; v1.2
September 2026 revised *Secure Software Lifecycle* and *Software Security*). It
is not an assessment methodology and it issues no certificates. The **colour-team
structure used here is an analytic device I am imposing** on the CyBOK material,
because it forces each knowledge area to produce a different kind of claim:

| Team | Colour convention | Question it must answer | CyBOK KAs exercised |
| --- | --- | --- | --- |
| White | Referee / governance | *Is this lawful, documented, and accreditable?* | RMG, LR, POR |
| Red | Adversary | *Can I make it do something it should not?* | AB, WAM, SS, MAT, NS |
| Blue | Defender | *Would I know? Could I reconstruct it?* | SOIM, F |
| Purple | Validator | *Does the defence actually detect the attack?* | AB + SOIM |
| Green | Builder | *Is the thing we ship and run trustworthy?* | SSL, SS, C, AC, OSV, DSS |
| Gold | Human / insider | *What will real people actually do?* | HF, AAA |

KA acronyms: RMG Risk Management & Governance · LR Law & Regulation · POR Privacy
& Online Rights · AB Adversarial Behaviours · WAM Web & Mobile Security · SS
Software Security · MAT Malware & Attack Technologies · NS Network Security ·
SOIM Security Operations & Incident Management · F Forensics · SSL Secure
Software Lifecycle · C Cryptography · AC Applied Cryptography · OSV Operating
Systems & Virtualisation · DSS Distributed Systems Security · HF Human Factors ·
AAA Authentication, Authorisation & Accountability.

Scoring: **C**ritical / **H**igh / **M**edium / **L**ow / **P**ass.
"Evidence" means a resolvable location in the repository at `d6e8671`.

Rules of engagement for this simulation: no exploitation, no live system, no
data. Every red-team result is a source-level reasoning step that a future test
must confirm (see `ultraplan-secure-private.md` W7).

---

## 1. White team — governance, law, risk (RMG, LR, POR)

**Charter.** Decide whether the system can *lawfully and documentedly* hold the
data the brief proposes, before anyone writes code.

### 1.1 Findings

| ID | Finding | Sev | Evidence |
| --- | --- | --- | --- |
| W-01 | No threat model, no data-flow map, no asset inventory anywhere in the repo. `SECURITY.md` is a *policy* document (how to report a vulnerability), not a model of what is being protected. | H | `SECURITY.md`; `grep -rn 'threat model' SECURITY.md README.md docs/` → none before this change (only this dossier matches afterwards) |
| W-02 | No DPIA and no screening decision. The system processes microbiome data; host-associated studies routinely carry participant/site codes in sample names and metadata columns, which is at least pseudonymised personal data and may be Art. 9 health data. | H | `config/composition.yml` accepts arbitrary metadata keys; no purpose/basis field exists |
| W-03 | Controller/processor position undocumented. Today the operator is the controller; if the tool is ever hosted for others, the author becomes a processor and needs Art. 28 terms. | M | No terms, no hosting model in `README.md` |
| W-04 | No record of processing (Art. 30) and no retention schedule. Deletion is manual `rm`, so retention is "whatever the operator remembers". | H | `studies.jl:233`, `runs.jl:465` |
| W-05 | No incident-response procedure and no breach-assessment path, while the app has a one-request public-disclosure route. | H | `doi.jl:58-88` |
| W-06 | No classification policy, so no way for a user to know what a study *is* in handling terms. | C for target | `grep -rniE 'classification\|top secret' src/ config/` → none |
| W-07 | No vulnerability-disclosure SLA or response-time commitment. `SECURITY.md` says only that fixes target `main` and implies no commitment — honest, but an assessor will note it. | L | `SECURITY.md` §"Supported versions" |
| W-08 | Accreditation artefacts absent: no security target, no controls matrix, no evidence index, no residual-risk statement, no independent review record. | C for target | `docs/` has no `security/` before this change |

### 1.2 The determination the white team must make first

**Can MetaManifold-WebUI be accredited at TOP SECRET?** Not as a general-purpose
application, and not by adding features. Three independent reasons:

1. **Assurance, not features.** TOP SECRET requires extremely high assurance of
   protection against extremely capable actors. Assurance is bought with
   evaluated components, reproducible and attributable builds, independent
   assessment, and configuration control at a level a research codebase with a
   dynamic dependency graph cannot demonstrate. Nothing in the ultraplan changes
   that; it makes the code *not the blocker*.
2. **The stack is inherited whole.** The trust boundary is the host
   (`recon-report.md` §2.2). TOP SECRET would inherit the OS, the browser, the R
   and Julia runtimes, CRAN and the Julia registry; each is a supply-chain
   surface with its own assurance story.
3. **The behaviours are environmental.** Sixteen of the thirty-three Tier 3
   behaviours have no software expression at all
   (`recon-report.md` §5.3): rooms, TSCM, couriers, DV escorts, secure
   destruction products, the protected registry book.

The achievable ladder — and the one the ultraplan is built on — is:

| Rung | What it means | What it requires that does not exist today |
| --- | --- | --- |
| **R0 — as-is** | Trusted local tool | nothing |
| **R1 — OFFICIAL-ready** | May hold OFFICIAL data on a managed workstation | headers (SEC-10), audit (SEC-02), restrictive modes (SEC-03a), two-phase delete (SEC-08), publication gate (SEC-05) |
| **R2 — OFFICIAL-SENSITIVE-ready** | May hold sensitive personal data | identity (SEC-01), FDE attested (SEC-03), retention + DSAR (SEC-14), export scrubber (SEC-13), incident procedure (SEC-17) |
| **R3 — SECRET-candidate** | Deployable inside an accredited SECRET environment | everything in R2 + marking/copy numbers/registry (SEC-04) + egress allowlist (SEC-30/TS-30) + signed reproducible builds + an independent assessment |
| **R4 — TOP SECRET** | Inside an accredited Tier 3 SIN, single-classification instance, no remote access, hardware-attested | R3 + platform accreditation, personnel controls, formal assurance evidence, cryptographic approval of the at-rest scheme |

**White-team verdict:** the honest target statement for the author is *"R2 in
this release, R3 in the next, R4 only as a certified component inside an
accredited environment"*. Any communication that says "TOP SECRET compliant"
would be false, and would be the first thing an assessor dismantles.

---

## 2. Red team — adversarial behaviours (AB, WAM, SS, MAT, NS)

**Charter.** Break it. Preconditions are stated because the severity depends
entirely on them.

| ID | Scenario | Precondition | Result | Sev | CyBOK |
| --- | --- | --- | --- | --- | --- |
| R-01 | **Delete a study** with `DELETE /api/v1/studies/{study}` | reach the port; no active job | **Succeeds.** No auth, no confirmation, no record. Raw FASTQ and all results gone. | C | WAM, AB |
| R-02 | **Clickjack** the operator into R-01 or a pipeline run | operator visits any attacker page | **Succeeds.** SPA sets no `frame-ancestors`/`X-Frame-Options`; the click is same-origin so the allowlist (G3) is irrelevant. | H | WAM, HF |
| R-03 | **Rewrite reference databases** then run the pipeline | reach the port | **Succeeds.** `PUT /api/v1/databases` accepts a new `uri` with no `sha256`; `_database_warnings` only advises; download then fetches attacker content. Scientific conclusions become attacker-controlled. | H | SS, DSS |
| R-04 | **Publish to the world** | `DOI_ENABLED=true` + token (the documented configuration) | **Succeeds.** `confirm:true` is the only gate. Irreversible. | H | AB, LR |
| R-05 | **Read another study / another user's data from the host** | a login on the same machine | **Succeeds.** No auth, default umask, no at-rest encryption. | H | OSV, AAA |
| R-06 | **Deny service** with a large body or a burst of job submissions | reach the port | **Succeeds.** No global body cap (`server.jl:96-118`); no running-job cap; one embedded R interpreter. | H | MAT, NS |
| R-07 | **Path traversal to read `/etc/passwd`** via `/files/…`, `{file}`, `{study}`, or a report file name | reach the port | **Fails.** `_unsafe_path_segment` (`server.jl:190`), `SAFE_NAME_RE` (`validate.jl:21`), `realpath` containment (`server.jl:404-410`, `doi.jl:31-45`), extension allowlist (`trees.jl`). | P | WAM |
| R-08 | **SQL injection** through `{table}`/`{column}`/`sort`/filters | reach the port | **Fails today** — but by consequence, not by validation: a bogus table yields no columns and the route 404s before the interpolated statement (`duckdb_helpers.jl:261-270,313-315`). A refactor re-opens it. | M (latent) | SS, DSS |
| R-09 | **Shell / R code execution** via config values or a formula | config write (which is unauthenticated but shape-checked) | **Fails.** `_SAFE_ARGS_RE` (`tools.jl:86`), `_sq` (`tools.jl:19`), `is_shell_safe`/`is_shell_safe_arg` (`validate.jl:50-68`), remote target validation (`remote_exec.jl:19-48`), strict formula AST (`ordination.jl:216-260`). This is well done. | P | SS |
| R-10 | **XSS** into the operator's browser via a study name, tree file, figure title, or error message | plant content, get it viewed | **Fails.** React escapes; no `dangerouslySetInnerHTML`/`innerHTML`/`eval` in `frontend/src`; errors go through JCS (`server.jl:73-91`); uploaded bytes are served with a sandboxing CSP (`report.jl:140`). Residual: no CSP on the app shell, so *if* a sink ever appears there is no second line of defence (SEC-10). | L | WAM |
| R-11 | **Secret extraction** from the browser or the repo | — | **Fails.** Token is env-only and redacted (`core/doi.jl:112-120`); gitleaks runs full history in CI with an estate baseline that fails closed; commits must be signed. | P | SS, SSL |
| R-12 | **Supply-chain substitution** of a GitHub Action or installer download | CI or install | **Fails.** Actions are SHA-pinned with version comments; `install.sh` uses `--proto '=https'` plus recorded sha256; Julia `Manifest.toml` and `bun.lock` pin trees. Remaining gap: no SBOM and no reproducible build, so an *artifact* substitution at release time is not detectable. | M | SSL |

**Red-team summary.** Ten of twelve attack paths against the *code surface* are
closed and were closed deliberately — this is a well-built application. Every one
of the successful paths is an **architecture** failure, not a coding failure:
there is no identity, so the attacker does not need to defeat anything.

---

## 3. Blue team — operations and forensics (SOIM, F)

**Charter.** If red wins, what does the defender see, and what can they
reconstruct afterwards?

### 3.1 Telemetry inventory (what actually exists)

| Source | Contains | Actor attribution | Tamper-evident | Retention |
| --- | --- | --- | --- | --- |
| HTTP access log | **does not exist** (`access_log=nothing`, `server.jl:498`) | — | — | — |
| `pipeline.log` | narrative, tool-log dumps, resolved command lines (`log.jl:27-33,68`, `tools.jl:45-52`) | **no** | no (append-only file, no hash chain) | unbounded |
| `attestation.yml` | host, versions, config sha256, run identity (`provenance.jl:520-545,790-830`) | **no** (host only) | config hash yes | with the run |
| config hashes | per-stage invalidation (`config.jl:_STAGE_SECTIONS`) | no | yes (sha256) | with the run |
| `derived/` records | content-addressed, refuse tampering (`derived_analyses.jl:69`) | no | **yes** | with the run |
| Julia `@info`/`@warn` to the console | operational noise | no | no | console only |
| CI: gitleaks, Scorecard, Hypatia | repository-level | per-commit | yes (GitHub) | GitHub |

### 3.2 Findings

| ID | Finding | Sev |
| --- | --- | --- |
| B-01 | **No request telemetry.** Nothing records method, path, status, size, time or source for any request. Every red scenario R-01 to R-06 is invisible. | C |
| B-02 | **No authentication events** because there is no authentication. No failed-access signal exists, so there is nothing to alert on. | C |
| B-03 | **Destruction leaves no trace.** Delete → gone, with no ledger entry, no hash of what was removed, no count. | C |
| B-04 | **No integrity baseline for `data/` or `config/`.** Results have hashes; inputs do not. An out-of-band edit of a FASTQ or `pipeline.yml` between runs is undetectable. | H |
| B-05 | **No log egress/retention policy.** Nothing ships logs anywhere; nothing rotates them; `pipeline.log` grows unbounded (`log.jl` appends, `finalise_log` strips only its own section). | M |
| B-06 | **Forensic readiness is better than detection.** Unusually, provenance is genuinely useful *after* an incident: `log_written` hashes every artefact (`log.jl:27-33`), config hashes pin the inputs per stage, and `derived/` refuses a mismatched record. A post-hoc "what changed" question is answerable *if* the attacker did not delete the run directory. | strength |
| B-07 | **Blast radius is the host.** No process isolation between studies, no per-study filesystem boundary, no seccomp/container guidance in the docs. | M |

### 3.3 What blue needs, in order

1. Structured request log to a file (`access_log=DevNull`-style replacement is a
   one-line change; a structured writer is a small one) — enables everything
   else.
2. Hash-chained audit ledger with a fixed event vocabulary (the same records
   satisfy GDPR accountability, HIPAA audit controls, and the TOP SECRET
   registry analogue — one control, three standards).
3. Input integrity baseline: record sha256 of every input file at run start and
   re-verify at run start of the next run.
4. Alert surface: a single “unexpected” channel (startup warnings, failed
   authorisation, classification breach attempt) written to both the ledger and
   stderr so an operator sees it without a dashboard.

---

## 4. Purple team — does the defence detect the attack? (AB + SOIM)

For each red scenario: what would we see today, and what does the proposed
control add? This is the check that stops the ultraplan from shipping controls
that look good and detect nothing.

| Red | Detected today? | Proposed control | Event it emits |
| --- | --- | --- | --- |
| R-01 delete | **No** | two-phase delete (SEC-08) | `delete.requested` (actor, study, item, hash of manifest), `purge.committed` |
| R-02 clickjack | **No** | `frame-ancestors 'none'` (SEC-10) | attack is eliminated; no event needed |
| R-03 database swap | **No** | require https+sha256 (SEC-06) | `config.write databases` with old/new sha256 and diff summary |
| R-04 publish | **No** | classification gate (SEC-05) | `publish.requested`, `publish.refused`, `publish.completed` (with DOI and file hashes) |
| R-05 peer read | **No** | identity + modes + FDE (SEC-01/03) | `authz.denied`; filesystem access is out of scope for the app and must be OS-audited |
| R-06 DoS | **No** (only a console error) | caps (SEC-07, SEC-15) | `limit.exceeded` (route, principal, limit) |
| R-08 SQLi attempt | **No** | identifier validation (SEC-12) | `bad_request` with the rejected identifier (ledger, sanitised) |
| R-09 shell injection attempt | **No** | already blocked; emit on refusal | `config.write refused` with the offending value |
| R-10 XSS | **No** | CSP (SEC-10) | `csp.violation` if a report-uri is added later |
| R-12 supply chain | **Partly** (CI-level) | SBOM + reproducible build + signed release | release attestation stored in-repo |

**Purple verdict:** 8 of 10 red scenarios are undetected today. Every proposed
control in the ultraplan names the event it emits, and the ledger schema is
designed once (fixed vocabulary) so that later controls do not invent new
telemetry.

---

## 5. Green team — build, crypto, platform (SSL, SS, C, AC, OSV, DSS)

| ID | Finding | Sev | Evidence |
| --- | --- | --- | --- |
| G-01 | **Crypto is absent, not weak.** No at-rest encryption, no in-transit encryption in the server, no key management, no signing of artefacts. | C for target | `grep -rniE 'encrypt\|cipher' src/` → none; `grep -rniE '\bTLS\b\|certfile' src/` → none |
| G-02 | **No SBOM and no reproducible build.** Julia `Manifest.toml` and `renv.lock` pin trees with hashes, `bun.lock` pins the frontend, but nothing emits a machine-readable inventory per release, and two builds of the same commit are not shown to be identical. | H | absence |
| G-03 | **No signed release artefact.** Commits must be Verified (good, `notes/commit-signing.md`), but no release bundle is signed and there is no provenance attestation (SLSA-style) for the built frontend. | H | `.github/workflows/` |
| G-04 | **No security test lane** beyond `test/unit/test_server_security.jl` (Origin/Host/headers). No property tests over the HTTP surface, no fuzzing of the JSON/YAML/NEWICK parsers, no ZAP-style baseline. | M | `test/unit/` |
| G-05 | **Runtime privilege is the operator's.** Documentation does not recommend a dedicated low-privilege service account, a container, or a systemd sandbox. | M | `start.sh`, `README.md` |
| G-06 | **Third-party code executes with full privilege**: `bash -lc` (`tools.jl:50`), RCall in-process (`r_runtime.jl`), DuckDB extensions implied by `read_csv_auto`. A compromise of any tool is a compromise of everything, including the data. | M | code |
| G-07 | **No dependency advisory gate in CI.** Dependabot is configured and Scorecard runs; no `osv-scanner`/`cargo-audit`-equivalent step fails the build on a known-vulnerable package. | M | `.github/workflows/ci.yml` |
| G-08 | **Build hygiene is genuinely strong.** SHA-pinned actions with version comments, `permissions: contents: read`, no `pull_request_target`, `persist-credentials: false`, hashed lockfiles, sha256-verified installer, full-history secret scanning with a fail-closed baseline, signed-commit policy. | strength | see `recon-report.md` G12 |

---

## 6. Gold team — human factors, insider, trust (HF, AAA)

**Charter.** The plan is only real if people follow it without being asked to do
anything extra. Gold's job is to veto controls that tax the user and to find the
insider paths.

### 6.1 Findings

| ID | Finding | Sev | Note |
| --- | --- | --- | --- |
| Y-01 | **The single-user assumption is invisible and routinely false.** Two analysts on one workstation, or a shared postdoc machine, is the normal lab case. Nothing tells either of them that they share full destructive authority. | H | `jobs.jl:7` |
| Y-02 | **Copy-and-send is the real dissemination path.** A publication table exported as XLSX and emailed is the TOP SECRET "verbal/hard-copy" failure in modern dress, and the export carries no marking, no copy number, no handling instruction. Marking is the single highest-leverage *human* control available, and it is free. | C for target | export routes |
| Y-03 | **No "who am I" affordance.** With no identity, an operator cannot tell whether an action will be attributed later. Attribution pressure is itself a control (AAA). | M | — |
| Y-04 | **Insider with legitimate access is indistinguishable from an attacker** — same routes, same authority, no anomaly baseline. | H | — |
| Y-05 | **Friction risk in the obvious fixes.** The instinctive responses (a confirm dialog on delete, a password per session, a classification dropdown on every export) all add recurring friction and would be ignored within a week — click-through blindness is a documented HF failure mode. | — | vetoed in `ultraplan-secure-private.md` §2 |
| Y-06 | **The TOP SECRET "chair declares the classification at the start" behaviour has a software analogue that costs nothing**: a persistent classification banner in the UI and on every artefact. It does the chair's job without a prompt. | — | mapping to TS-01/TS-32 |

### 6.2 Gold's veto list (do not build)

- A confirmation dialog before deletion. (Substitute: two-phase delete with a
  visible "recently deleted" list — costs zero clicks in the happy path, and the
  recovery is *there* when it is needed.)
- A password or MFA prompt per session on a single-user localhost tool. (Substitute:
  identity from the OS account or a proxy-asserted principal.)
- A classification dropdown on every export. (Substitute: inherit from the
  study; the user sets it once.)
- A warning banner on every page. (Substitute: one banner, showing the truth.)
- Periodic re-authentication for a tool that is used in multi-hour sessions.

### 6.3 Friction accounting for the whole ultraplan

| Workstream | Added user actions | Added user decisions |
| --- | --- | --- |
| W1 hardening | 0 | 0 |
| W2 audit ledger | 0 | 0 |
| W3 identity | 0 (proxy/OS) | 0 |
| W4 classification | 0 | 1 per study, at creation (defaults to OFFICIAL) |
| W5 privacy | 0 | 1 per study, only if it declares personal data |
| W6 assurance | 0 | 0 |
| W7 testing | 0 | 0 |
| **Total** | **0** | **≤2, both once per study** |

---

## 7. Where the teams disagree, and how the conflict resolves

This section is the point of running the exercise. Four conflicts surfaced; each
one is resolved by the eliminate/substitute/notify rule rather than by
compromise.

| Conflict | Red says | Blue says | Gold says | Resolution |
| --- | --- | --- | --- | --- |
| Deletion | "one request destroys a study" | "we would never know" | "no confirm dialogs" | **Two-phase delete** (SEC-08): attack needs two recorded requests; the ledger gives blue the event; the honest user sees the item vanish immediately, with a recovery window they never have to think about. |
| Sign-in | "no identity = no defence" | "no auth events = nothing to alert on" | "no passwords, no MFA prompts" | **Identity asserted by the local proxy or the OS account** (SEC-01): red gets an attributable principal, blue gets an event, gold gets zero prompts. A password database is explicitly rejected. |
| Classification | "unmarked exports are the leak" | "we cannot tell what left" | "no dropdowns" | **Inherited attribute + banner + manifest** (SEC-04): set once at study creation (default OFFICIAL), rendered by the server, never asked again. |
| Publication | "irreversible egress in one request" | "no record of disclosure" | "don't block my DOI workflow" | **Gate on the existing classification + record the approval** (SEC-05). Publication is already exceptional; adding a recorded approval costs nothing in routine use, and the route already refuses unless `DOI_ENABLED=true`. |

---

## 8. Heat map

| Area | Red | Blue | Green | Gold | White | Overall |
| --- | --- | --- | --- | --- | --- | --- |
| Identity & authorisation | C | C | M | H | C | **C** |
| Audit & forensics | — | C | — | — | H | **C** |
| Data at rest / in transit | H | M | C | M | C | **C** |
| Classification & dissemination | H | C | — | C | C | **C** |
| Input validation (paths, SQL, shell, R, XSS) | P | — | M | — | — | **P** |
| Integrity & provenance | M | strength | M | — | H | **M** |
| Availability & resource control | H | M | M | M | M | **H** |
| Build & supply chain | M | — | H | — | M | **H** |
| Governance & documentation | — | — | — | M | C | **C** |

The shape of this map is the argument for the ultraplan's ordering: the code
surface is strong (one green row out of nine), and every red row is
architectural. That is a good problem to have — architectural controls are
additive and do not risk the scientific correctness that the rest of this
repository is built to protect.
