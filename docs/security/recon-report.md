<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Security recon: GDPR / HIPAA baseline, TOP SECRET target

Status: static review of `main` at `d6e8671` (`fix(governance): follow the
standards transfer …`). This is an evidence document and a gap analysis. It is
not a certification, an accreditation, or a penetration test, and nothing below
claims a control is "met" unless the evidence for it is on disk and cited.

Companion documents:

- [`ultraplan-secure-private.md`](ultraplan-secure-private.md) — the plan to close what this report finds.
- [`colour-teams.md`](colour-teams.md) — the CyBOK-referenced colour-team
  exercise (white, red, blue, purple, green, gold).

---

## 0. Scope, method, and what I could not do

### 0.1 Scope

The whole first-party surface: Julia server (`src/server/`), analysis and
pipeline (`src/analysis/`, `src/pipeline/`, `src/core/`), React/TypeScript
frontend (`frontend/src/`), configuration (`config/`), installers and CI
(`install.sh`, `start.sh`, `.github/workflows/`, `scripts/ci/`), and the
governance artefacts (`SECURITY.md`, `0-AI-MANIFEST.a2ml`, `.gitleaks.toml`,
`.machine_readable/`).

Out of scope by nature: the physical building, the network perimeter, the
operating system, the DV-cleared people, and the cryptographic accreditation of
the platform. Those are *inherited* controls — see §5.3, which says explicitly
which TOP SECRET behaviours software can carry and which it can only depend on.

### 0.2 Method

1. Asset and trust-boundary reconstruction from the code that owns them:
   `src/server/server.jl` (middleware, static serving, startup),
   `src/server/routes/*.jl` (155 routes), `src/server/jobs.jl` (execution).
2. Control-by-control reading of every place where a request value reaches a
   filesystem path, a shell, SQL, R, another host, or an outbound HTTP call.
3. Absence checks. For "there is no X" claims I grepped for X's vocabulary and
   report the zero (or the only hits, which are unrelated). An absence claim is
   only as good as the grep, so the greps are in §9 and can be re-run.
4. Mapping to three standards: GDPR (Reg. (EU) 2016/679), the HIPAA Security
   Rule (45 CFR Part 164 Subpart C), and the UK Government Security
   Classifications TOP SECRET tier (Tier 3) baseline behaviours supplied with
   this brief.
5. Colour-team simulation against CyBOK v1.1/v1.2 knowledge areas.

### 0.3 What I could not run, and therefore do not claim

| Limitation | Consequence |
| --- | --- |
| No Julia, R, bun or DuckDB in the review environment | No test was executed; no runtime behaviour is claimed. Every finding is from source reading and is reproducible by resolution reference. |
| Clone is shallow (`git rev-parse --is-shallow-repository` → `true`, 1 commit) | No Git-history secret scan and no historical-integrity claim. Gitleaks runs full-history in CI (`.github/workflows/secret-scanner.yml`); I assert its *design*, not its *result*. |
| No network access to the running server | No live request was sent. Exploit chains in §7 are reasoned from source and are labelled as such until a test proves them. |
| No access to the author's deployment (OS, disk encryption, network) | All environment-level controls in §5.3 are marked **inherited / to be attested**, never assumed present. |

---

## 1. Executive summary

### 1.1 What this system is, in security terms

MetaManifold-WebUI is a **single-operator, loopback-bound, unauthenticated
analysis appliance** that runs a shell- and R-driven bioinformatics pipeline,
stores results in DuckDB, and serves a browser UI that can start, cancel and
delete work. That is not a criticism: it is the design, stated plainly in the
code and in `SECURITY.md` ("Treat the Julia server as a trusted local analysis
service, not a public, multi-tenant hosting boundary"). `src/server/jobs.jl:7`
says it in one line: `# In-memory job store. Single-user local server - no
persistence needed.`

The security question in this brief is therefore not "is the appliance
vulnerable" but **"what has to change before this appliance may hold data whose
compromise could kill people"**. Those are very different questions, and the
answer to the second is: a great deal, and almost none of it in the scientific
code.

### 1.2 Verdicts

| Target | Verdict at `d6e8671` | One sentence |
| --- | --- | --- |
| **GDPR baseline** | **Not met** for any multi-user, network-exposed, or human-derived-data deployment. Defensible only as a single-user tool on a whole-disk-encrypted, access-controlled workstation with no personal data beyond sample labels. | There is no way to answer "who accessed or deleted this subject's data", which is Art. 5(2)/30/32 in one sentence. |
| **HIPAA baseline** | **Not met.** Three *required* implementation specifications fail outright (unique user identification, person/entity authentication, audit controls), and the two *addressable* encryption specifications have no implemented equivalent and no documented risk decision. | §164.312(a)(2)(i), (b), (d) are required, not addressable, and there is no identity anywhere in the process. |
| **TOP SECRET (Tier 3)** | **Not reachable by the application alone, and not reachable as deployed today even inside a perfect environment.** The environment can supply the Secure Isolated Network, the accredited rooms, the DV-cleared staff and the couriers; the application must still supply marking, need-to-know, the protected-document-registry equivalent, the witnessed-destruction record, and the audit trail — and supplies none of them. | The application cannot label, cannot attribute, cannot erase-with-evidence, and cannot prove it was not tampered with. |

### 1.3 What is genuinely good (do not rewrite it)

This codebase is unusually security-literate for a research tool. Twelve
controls are already implemented *well*, several of them better than commercial
products: parameterised SQL with an explicit identifier guard, a shell-quoting
helper plus metacharacter gating plus remote-target validation, a strict AST
parser for R formulas that refuses arbitrary call expressions, realpath
containment on three separate file-serving paths, a CORS/Origin allowlist that
also defeats DNS rebinding and is unit-tested, SHA-256 verification of every
reference-database download, content-addressed analysis records that refuse
tampering, SHA-pinned GitHub Actions with least privilege, and a sha256-verified
installer. §3 lists all twelve with line references.

The plan in `ultraplan-secure-private.md` therefore **adds** layers. It does not touch the
scientific code, the numeric contracts, or the parts of the request pipeline
that this review found sound.

### 1.4 The five findings that matter

1. **No identity, therefore no accountability, therefore no need-to-know.**
   Every route in `src/server/routes/` is unauthenticated and unauthorised.
   (SEC-01)
2. **No audit trail and no access log.** `access_log=nothing`
   (`src/server/server.jl:498`); destructive operations are recursive `rm`
   (`src/server/routes/studies.jl:233`, `runs.jl:465`) with no tombstone and no
   record of who asked. (SEC-02)
3. **No encryption at rest, anywhere** — zero occurrences of `encrypt`,
   `cipher` or key-management vocabulary in `src/`. (SEC-03)
4. **No classification model**: the words *classification*, *TOP SECRET*,
   *caveat*, *need-to-know* and *dissemination* appear nowhere in `src/`,
   `config/` or `frontend/src/`, while the app's whole purpose is to export
   artefacts. (SEC-04)
5. **One unauthenticated request can publish study material to the public
   internet** — `POST /api/v1/studies/{study}/doi/publish` with `confirm=true`
   (`src/server/routes/doi.jl:58-88`) pushes files to Zenodo with no
   classification check. That is simultaneously a GDPR Art. 44 transfer and a
   TOP SECRET dissemination breach. (SEC-05)

---

## 2. System model

### 2.1 Assets, in the order the classification tier cares about them

| # | Asset | Where it lives | Sensitivity driver |
| --- | --- | --- | --- |
| A1 | Raw sequence data (`*.fastq.gz`) | `data/{study}/{run}/` | May be human-derived; may carry subject linkage through sample names/metadata |
| A2 | Sample metadata and category sets | `config/composition.yml`, DuckDB columns, CSV exports | Direct identifiers appear here if anywhere |
| A3 | Results and derived analyses | `projects/{study}/**`, `*.duckdb`, `derived/` records | Scientific value; integrity-critical |
| A4 | Configuration and primer/reference libraries | `config/` | Integrity-critical (changes outputs silently) |
| A5 | Provenance and attestation | `attestation.yml`, `pipeline.log`, config hashes | The only tamper evidence that exists |
| A6 | Publication artefacts | `projects/{study}/report/`, figure rasters, exported ZIPs | The artefacts that leave the boundary |
| A7 | Externals: reference databases, Zenodo | downloads cache, Zenodo API | Supply chain and egress |
| A8 | Credentials: `ZENODO_TOKEN` | environment only | Secret |

### 2.2 Trust boundary as deployed

```
browser (operator)  ──HTTP, no TLS──►  Julia/Oxygen  ──bash -lc──►  tools (cutadapt, vsearch, …)
                            │                        ──RCall───►  R (DADA2)
                            │                        ──ssh─────►  remote compute host
                            │                        ──HTTPS───►  GitHub release assets, Zenodo
                            └─ no auth, no session, no audit, no rate limit, no at-rest crypto
```

The boundary is the **host**, not the process. Everything inside the host —
any other local user, any other process, any page the operator's browser has
open — is inside the boundary as the code currently stands. `SECURITY.md`
acknowledges this and correctly forbids direct internet exposure; what it does
not do is state the equivalent requirement for a *shared* host, which is where
the practical risk sits in a lab.

### 2.3 Actors

| Actor | Capability today | Capability it must have at TOP SECRET |
| --- | --- | --- |
| Operator (analyst) | full read/write/delete/execute | read/write *their* studies only |
| Second analyst on the same host | identical to the first, including delete | no access without an explicit grant |
| Local unprivileged user | reads `data/` and `projects/` via the filesystem if modes permit (no `chmod`/`umask` call exists in `src/`) | no access |
| Anyone who can reach the port | full API | nothing |
| A web page in the operator's browser | can frame the UI (no `frame-ancestors` on the SPA route) | cannot frame; cannot read |
| Remote compute host | receives complete inputs over ssh | inside the accredited boundary |
| Zenodo | receives whatever the operator selects | never, without a per-document determination |

---

## 3. Controls that already exist and are sound

Each row cites the code that implements it. These are the things the plan must
*not* disturb, and several are reusable primitives for the upgrade.

| # | Control | Evidence |
| --- | --- | --- |
| G1 | Entity-name validation (`[A-Za-z0-9._-]`, no leading dot, anchored with `\z`) applied before any name reaches a path, plus a URL-decoded path-segment guard that rejects `.`, `..`, `/`, `\`, `"`, NUL | `src/core/validate.jl:21`, `src/server/routes/studies.jl:148-150`, `src/server/server.jl:190-216` |
| G2 | `realpath` containment on every file-serving path: run files, DOI report files, the SPA root | `src/server/server.jl:404-410`, `src/server/routes/doi.jl:31-45`, `src/server/server.jl:429-434` |
| G3 | Origin allowlist + `Host` check on loopback binds + a wildcard-bind rule that admits only an `http://` origin whose IP literal equals the request `Host` (so a DNS-rebinding domain is refused). Unit-tested, including the refusal cases | `src/server/server.jl:299-380`, `test/unit/test_server_security.jl:44-130` |
| G4 | Oxygen's `/docs`, `/docs/schema` and `/metrics` disabled (they sit outside the middleware chain); `show_errors=false`; no stack trace reaches a client | `src/server/server.jl:498`, `src/server/server.jl:73-91` |
| G5 | Error bodies built through the JCS/I-JSON writer with a fallback, so a hostile path segment cannot turn a 400 into a 500 | `src/server/server.jl:73-91` |
| G6 | SQL: every request value is a bind parameter; identifiers are quoted and gated by an explicit `is_safe_name` check; category CASE expressions escape string literals | `src/server/routes/duckdb_helpers.jl:145-215`, `src/core/categories.jl:355-364`, `MetaManifold.Categories._sql_str` |
| G7 | Shell: single-quote helper, metacharacter allowlist for `optional_args`, and remote target validation (no leading `-`, no spaces, absolute staging dir) before anything becomes an ssh word | `src/pipeline/tools.jl:19,86-94`, `src/core/validate.jl:50-68`, `src/pipeline/remote_exec.jl:19-48` |
| G8 | R: ordination formulas parsed as a strict identifier/interaction AST and refused if they are call expressions — this closes the `as.formula` arbitrary-evaluation hole explicitly | `src/analysis/ordination.jl:216-260` |
| G9 | Uploads: per-route byte caps, PNG magic-byte check, UUID/slug file names, and uploaded bytes served with `Content-Security-Policy: default-src 'none'; …; sandbox` + `nosniff` | `src/server/routes/report.jl:11,57-86,140-141`, `src/server/routes/figures.jl:13-14,80-86`, `src/server/server.jl:412-419` |
| G10 | Integrity: SHA-256 and size verification of every reference database before and after download, with a partial-download pattern and a cleanup `finally`; content-addressed derived analyses that refuse a record whose id does not match its content; tree files served with their sha256 | `src/core/databases.jl:114-160,292-345`, `src/analysis/derived_analyses.jl:69`, `src/server/routes/trees.jl:95` |
| G11 | Secrets: the Zenodo token is server-side only, never in the frontend, and is redacted from any text written to a receipt or log | `src/core/doi.jl:93-95,112-120`, `src/server/routes/doi.jl:108-111` |
| G12 | Supply chain and CI: every action SHA-pinned with the version in a comment; top-level `permissions: contents: read`; no `pull_request_target` anywhere; full-history gitleaks with an estate baseline that fails closed if the baseline cannot be fetched; Scorecard; a sha256-verified, `--proto '=https'` installer; `persist-credentials: false`; signed-commit requirement documented | `.github/workflows/*.yml`, `.github/workflows/secret-scanner-reusable.yml:237-310`, `install.sh:167-190`, `notes/commit-signing.md` |

Two latent weaknesses inside otherwise sound controls are recorded as SEC-12
and SEC-13 below rather than as strengths.

---

## 4. Findings

Severity is judged against the *target tier*, not against a hobby deployment:
a finding that is Low for a laptop is High for a TOP SECRET candidate.

Each finding carries a **disposition** in the vocabulary this brief asks for:

- **E — Eliminate**: remove the exposure (the capability, the data, or the reach).
- **S — Substitute**: replace the risky mechanism with a safer one that costs the
  user nothing.
- **N — Notify**: detect, record and disclose — default-safe, never a prompt.

and a **friction cost**: `0` = invisible, `1` = one-off setup, `2` = recurs per
task. Nothing at `2` is proposed anywhere in this dossier.

---

### SEC-01 — No authentication, no authorisation, no session (Critical)

**Evidence.**
The middleware chain is five functions, none of which establishes an identity:
`src/server/server.jl:494-495` —
`[_bad_request_middleware, _r_busy_middleware, _cors_middleware, _analysis_source_middleware, _file_middleware]`.
The only `Authorization` strings in `src/` are Zenodo *client* code
(`src/core/doi.jl:112,119,182`). There is no session store, no token check, no
user table, no peer-credential check. `src/server/jobs.jl:7` states the design
assumption. `SECURITY.md` places the whole burden on the operator: "Treat the
Julia server as a trusted local analysis service… Remote deployments need an
authenticated, TLS-terminating reverse proxy."

**Impact.** All 155 routes are open to anything that can reach the port. That
includes destructive routes (`DELETE /api/v1/studies/{study}`,
`…/runs/{run}`, `…/results/tables/{table}`, `/api/v1/jobs/{id}`), execution
routes (`POST …/pipeline`, `POST …/stages/{stage}`), configuration routes
(`PATCH`/`DELETE` on global, study, group and run config), and the irreversible
publication route. There is no distinction between read and write, no
need-to-know, and no attributable actor for any of them.

**Standards.** GDPR Art. 32(1)(b),(d), Art. 5(1)(f), Art. 25; HIPAA
§164.312(a)(1) access control, §164.312(a)(2)(i) **unique user identification
(Required)**, §164.312(d) **person or entity authentication (Required)**,
§164.502(b) minimum necessary; TOP SECRET §5 and §7 (strict need-to-know,
recipients briefed and traceable).

**Disposition.** E for reach (bind loopback only — already the default at
`src/server/server.jl:507` — and refuse to start on a non-loopback bind without
an explicit acknowledgement *and* a terminating proxy), then S for identity
(accept a verified identity from a mutually-authenticated local proxy or the OS
account, and record it; do not build a password database). Friction: 0 for the
incumbent single user, 1 for a team.

---

### SEC-02 — No audit trail, no access log, no attributable deletion (Critical)

**Evidence.** `const _SERVE_OPTIONS = (access_log=nothing, …)`
(`src/server/server.jl:498`) — no request log at all. Deletion is
`rm(path; recursive=true, force=true)` with no record and no tombstone:
`src/server/routes/studies.jl:233-241`, `src/server/routes/runs.jl:465`,
`src/server/routes/results.jl:540`, `src/server/routes/trees.jl:140-148`,
`src/server/routes/figures.jl:98-103`, `src/server/routes/config.jl:631,896,981,1030`.
`log_command` and `log_written` record *what the pipeline did to what file*
(`src/core/log.jl:27-33`, `src/pipeline/tools.jl:45-52`) but nothing records
*who asked for it* or *who read it*.

**Impact.** No accountability and no forensics. After deletion there is no
evidence of what was deleted, by whom, when, or whether it succeeded — which is
simultaneously a GDPR erasure-evidence problem, a HIPAA audit-control failure,
and a direct contradiction of the TOP SECRET rule that assets may not be
destroyed without written approval and a DV-cleared witness.

**Standards.** GDPR Art. 5(2), Art. 30, Art. 32, Art. 33 (you cannot assess a
breach you cannot reconstruct); HIPAA §164.312(b) **audit controls (Required)**,
§164.308(a)(6) security incident procedures, §164.316(b)(2) six-year retention;
TOP SECRET §5 (destruction with a witness, recorded in the Protected Document
Registry book, destruction and witness both recorded).

**Disposition.** S — an append-only, hash-chained ledger written by the server
for a fixed vocabulary of events (access, export, delete, config write, publish,
run start/stop, auth decision). The primitives already exist: canonical JSON
(`src/canonical.jl`), `sha256` (`src/core/log.jl:27-33`), atomic publication
(`src/core/derived_analyses.jl`). Friction: 0 — the ledger is written by
`_bad_request_middleware`'s sibling, not by the user.

---

### SEC-03 — No encryption at rest, and no key management (Critical for the target)

**Evidence.** Grep for `encrypt|cipher` across `src/` returns zero. No `chmod`,
`chown` or `umask` call exists either, so directories created through `mkpath`
(`src/server/routes/studies.jl:201`, `src/server/routes/report.jl:81`,
`src/server/routes/figures.jl`, `src/core/config.jl`) take the process umask —
typically `0755`, i.e. world-readable on a shared host. DuckDB stores, FASTQ,
report uploads, `attestation.yml` and the logs are all plaintext files.

**Impact.** Any local user, backup system, snapshot, sync client or stolen disk
yields the whole dataset. There is no equivalent control and no documented risk
decision, which is what HIPAA's *addressable* standard requires.

**Standards.** GDPR Art. 32(1)(a) (encryption as an appropriate technical
measure), Art. 32(1)(b); HIPAA §164.312(a)(2)(iv) **encryption and decryption
(Addressable — implement or document the equivalent)**, §164.312(e)(2)(ii)
transmission encryption, §164.310(d)(2)(i) disposal; TOP SECRET storage and
transport rules throughout §5.

**Disposition.** S — two substitutions that cost the user nothing:
(a) **whole-tree encryption at the filesystem layer** (LUKS / FileVault /
BitLocker or an equivalent accredited FDE) as the baseline, documented as an
inherited control, plus `0700`/`0600` modes set at creation so the data is not
world-readable even inside the encrypted volume; (b) **envelope encryption for
anything that leaves the tree** — exports, backups and the attestation bundle —
using an age/X25519 recipient list or the platform keychain. Do **not** invent a
custom at-rest scheme. Friction: 0 (FDE is one-off), 1 for the export key.

---

### SEC-04 — No classification model: no marking, no caveats, no registry, no copy control (Critical for the target)

**Evidence.** `classification`, `top secret`, `caveat`, `need-to-know`,
`dissemination` and `handling` do not occur in `src/`, `config/` or
`frontend/src/` (the only hits repo-wide are in unrelated prose). Export paths
that produce material a human could leak: `GET …/report/export` (ZIP),
`POST …/results/tables/{table}/export` (XLSX), `POST …/analysis/publication-tables`,
figure rasters, tree files, `attestation.yml`, `combined_pipeline.log`.

**Impact.** Every artefact this tool emits is **unmarked**. That is the single
sharpest mismatch with the target tier: the TOP SECRET baseline is, at bottom, a
labelling-and-registry discipline (§5 — header/footer marking, copy numbers,
Protected Document Registry, handling instructions in the subject line, UK
prefix for international partners). A file that leaves this tool carries no
indication of what it is, so the control collapses to the user's memory.

It also means an export cannot be *scoped*: nothing prevents a report containing
one study's material from being combined with another's.

**Standards.** TOP SECRET §5 (all marking, registry, copy-number and
dissemination behaviours); GDPR Art. 5(1)(b) purpose limitation and Art. 44
transfers (an unmarked export has no record of what it may be sent to); HIPAA
§164.502(b) minimum necessary and §164.528 accounting of disclosures.

**Disposition.** S — a first-class `classification` attribute on study, group and
run, inherited downward, defaulting to `OFFICIAL`, enforced at **one** choke
point on every export path, rendered as a banner in the UI and in generated
HTML/CSV/XLSX/PDF, with a copy number and a dissemination list carried in the
export manifest. Friction: 0 — set once when a study is created; users never see
a prompt, they see a banner.

---

### SEC-05 — Public internet publication of study material with one request (High)

**Evidence.** `POST /api/v1/studies/{study}/doi/publish`
(`src/server/routes/doi.jl:58-88`) requires only `confirm: true` in the body,
then resolves report files and calls `publish_study`, which POSTs to
`DOI_ORIGIN` (default: the Zenodo *sandbox*) with the bearer token
(`src/core/doi.jl:153-190`). There is no check that the study's classification
permits external dissemination, no allowlist of files, and no approval record.

**Impact.** Irreversible publication to a third country platform. This is the
one route in the system whose effect cannot be undone by a restore, and it is
reachable by anything that can reach the port (SEC-01) or by a clickjack
(SEC-11).

**Standards.** GDPR Art. 44-46 (transfer outside the UK/EU without a mechanism),
Art. 5(1)(b) (a research purpose does not authorise public release), Art. 32;
TOP SECRET — dissemination outside the Secure Isolated Network is prohibited
outright; HIPAA §164.528 accounting of disclosures.

**Disposition.** E for the default (the route already refuses unless
`DOI_ENABLED=true` — keep and strengthen that), then S: require the study's
classification to be `OFFICIAL` and require an explicit, recorded approval entity
before publication, and write the publication to the audit ledger with the file
hashes. Friction: 0 in normal use (publication is already an exceptional act).

---

### SEC-06 — Unauthenticated rewrite of the reference-database configuration (High)

**Evidence.** `PUT /api/v1/databases` (`src/server/routes/databases.jl:129-140`)
replaces the whole `databases.yml` document, validated only for shape;
mismatches are *advisory* warnings (`_database_warnings`). The `uri:` field has
no scheme check and the `sha256:` field is optional; `local:` accepts any
absolute path. `POST /api/v1/databases/{key}/download` (`databases.jl:176-187`)
then fetches that URI into the cache, and `_resolve_entry`
(`src/core/databases.jl:292-345`) accepts a file that verifies only when a hash
is configured — the "hand-placed file gets the same scrutiny" comment is true
only if `sha256` is present.

**Impact.** An attacker (or an accidental edit) can point classification at an
arbitrary remote or local file. Downstream, taxonomy results are wrong in a way
that looks completely normal — the worst failure mode in a scientific tool; and
the download is an outbound GET to an attacker-chosen URL from inside the
accredited network.

**Standards.** Integrity of processing — GDPR Art. 5(1)(d),(f), Art. 32(1)(b);
HIPAA §164.312(c)(1) integrity; TOP SECRET — data-import controls and no
unvetted egress from the Secure Isolated Network.

**Disposition.** S — require `https` scheme, require `sha256`, refuse a `uri`
change unless it carries a hash, and make "no hash" a refusal rather than a
warning for pipeline use. Friction: 0.

---

### SEC-07 — No global request-size limit; unbounded job submission (High)

**Evidence.** Per-route caps exist (report 50 MB, figures 2 MB/200 MB, FASTA
100 MB, trees 50 MB, statistics 16 MB) but the shared body readers
(`_read_json_object` at `src/server/server.jl:96-118`, `_request_json` at
`src/server/server.jl:171-178`) have no cap, and the HTTP layer is not
configured with a maximum. There is no rate limiting anywhere in `src/` (grep:
zero). `JobQueue` prunes finished jobs (`src/server/jobs.jl:35`) but does not cap
*running* jobs, and a pipeline job holds the embedded R interpreter
(`src/core/r_runtime.jl`), so a handful of requests serialise into hours of
exclusive lock. The code already knows: `src/analysis/numeric_policy.jl:27-38`
— "Configuration limits are deliberately finite. They can be changed in source
after review, not raised per request until an unauthenticated request can OOM
us."

**Impact.** Memory exhaustion and denial of service by anything that reaches the
port. For a TOP SECRET appliance, availability is a security property.

**Standards.** GDPR Art. 32(1)(b) (availability); HIPAA §164.308(a)(7)
contingency plan, §164.312(c); TOP SECRET — availability of the processing
environment.

**Disposition.** E for the unbounded submission (cap queued+running jobs, reject
with 429), S for the body cap (one middleware, one number, applied before any
parser runs). Friction: 0 — no legitimate request is anywhere near the limits.

---

### SEC-08 — Destructive operations are unconditional and irreversible (High)

**Evidence.** Study, run, table, tree, figure, preset, category-set and job
deletion routes (inventory in §8.1) act immediately, with no confirmation token,
no soft delete, no undo and no notification. `POST /api/v1/studies/{study}/rename`
and the group rename move directories (`_safe_move`, `studies.jl:159-163`).
The job cancel route accepts any id (`src/server/routes/jobs.jl:29`).

**Impact.** One mistyped request or one clickjack deletes a study's raw data and
results permanently, with no record. This is the failure that a TOP SECRET
environment treats as a reportable incident rather than a mistake.

**Standards.** GDPR Art. 5(1)(e),(f), Art. 17 (erasure must be effective *and*
evidenced); HIPAA §164.312(c)(1) integrity, §164.308(a)(6);
TOP SECRET §5 — no destruction without written approval from the information
creator, and destruction recorded and witnessed.

**Disposition.** S — two-phase deletion: a `DELETE` marks and moves to a
quarantine area inside the tree and writes the ledger entry; a separate,
privileged, recorded `purge` removes it after a retention window. Friction for
the honest user: 0 (the item disappears from the UI immediately, exactly as
now). For the attacker: they now need two requests and they are both recorded.

---

### SEC-09 — No transport security in the server (High whenever it is not loopback)

**Evidence.** `start(; host="127.0.0.1", port=8080)` (`src/server/server.jl:500`)
calls `serve(; host, port, …)` with no certificate option; `grep -E "TLS|SSL|certfile"`
over `src/` returns nothing. `README.md:912` instructs `http://localhost:8080`.
`JULIA_METAMANIFOLD_ALLOWED_ORIGINS` accepts `https://` origins for a
split deployment while the API itself remains plaintext.

**Impact.** On loopback this is fine and honest. Any non-loopback bind — the
documented split deployment, or a shared lab box — sends study names, filters,
results and any metadata in clear text, and lets a network attacker inject into
the pipeline.

**Standards.** GDPR Art. 32(1)(a) (encryption in transit); HIPAA
§164.312(e)(1) **transmission security (Required)**, §164.312(e)(2)(ii);
TOP SECRET — Secure Isolated Network, no unaccredited bearer.

**Disposition.** E for reach (already loopback by default; make a non-loopback
bind without a TLS terminator a **startup refusal**, not a warning), S for the
encrypted path (support `:ssl` on the same `serve` call, or document the proxy as
a hard prerequisite and verify the `X-Forwarded-Proto`). Friction: 0.

---

### SEC-10 — Security headers are present on one route and absent on the rest (Medium)

**Evidence.** `src/server/routes/statistics_ui.jl:187-194` sets
`nosniff`, `Referrer-Policy: no-referrer` and a CSP **including
`frame-ancestors 'none'`** — exemplary. The SPA and static-asset responses set
only `Content-Type` and `Cache-Control` (`src/server/server.jl:440-447`), and
`/files` adds `nosniff` alone (`server.jl:416`). There is no
`X-Frame-Options`, no CSP, no `Referrer-Policy`, no `Permissions-Policy` and no
`Cross-Origin-*` isolation anywhere outside that one route.

**Impact.** The UI can be framed by any site (see SEC-11), referrer URLs leak
study and run names to third parties, and the frontend has no
defence-in-depth against an injected script (there is currently no
`dangerouslySetInnerHTML` in `frontend/src` — verified — so this is preventive,
not an active XSS).

**Standards.** GDPR Art. 32(1)(b) confidentiality; TOP SECRET — protection
against the "extremely high capability" threat actor includes not leaking
metadata in a `Referer` header.

**Disposition.** S — reuse the exact header set from `statistics_ui.jl` in one
response-side helper and call it from `_file_middleware` for every response.
Friction: 0. This is the highest value-per-line change in the whole dossier.

---

### SEC-11 — Clickjacking of an unauthenticated destructive UI (Medium; High in combination)

**Evidence.** No `frame-ancestors` / `X-Frame-Options` on the SPA
(SEC-10), deletion has no confirmation and no undo (SEC-08), and study deletion
is a single `DELETE` (`studies.jl:233`). Because the framed document *is* the
app, a clickjacked click arrives as a same-origin request that carries
`Origin: http://localhost:8080` — identical to a legitimate one — so the
Origin allowlist (G3), which correctly stops cross-origin scripting, is
structurally unable to stop UI redressing.

**Impact.** A page the operator visits in the same browser can position an
invisible frame over a plausible button and delete a study or start a pipeline
run. No credentials are needed, so `SameSite` cookies would not help even if a
session existed.

**Standards.** Same as SEC-10 plus TOP SECRET §5 (unauthorised removal or
destruction of assets).

**Disposition.** E — `frame-ancestors 'none'` (SEC-10) removes the attack
outright, which is why SEC-10 and SEC-11 ship together and first.

---

### SEC-12 — Identifier validation of SQL table/column names is implicit, not explicit (Medium, latent)

**Evidence.** `{table}` and `{column}` path params are interpolated into quoted
SQL (`src/server/routes/duckdb_helpers.jl:26-27,51,273-281,318-322`,
`src/server/routes/results.jl:404`). Today the injection is blocked *by
consequence*, not by validation: `_duckdb_columns` is parameterised, so a bogus
table yields `[]`, and callers return 404 before the interpolated statement runs
(`duckdb_helpers.jl:261-270,313-315`; `results.jl:449-451`). A future refactor
that reorders a check re-opens it. Identifier quoting is not escaping: a `"`
inside `table` would break out.

**Impact.** No current exploit path found — this is a defence-in-depth gap and a
regression trap.

**Standards.** GDPR Art. 32; HIPAA §164.312(c)(1); TOP SECRET — integrity of
stored data.

**Disposition.** S — validate `table`/`column` with `Validation.is_safe_name`
(or a dedicated identifier predicate, since real column names contain spaces and
slashes) at the route boundary, and add a unit test that a `"`-bearing table
name returns 400. Friction: 0.

---

### SEC-13 — Provenance artefacts record paths, hostnames and command lines verbatim (Medium, GDPR data minimisation)

**Evidence.** `src/core/provenance.jl:799-801` states it directly: "Paths and
command lines are recorded verbatim, and may carry a username or a study name.
The Attestation is a publishable artefact, so check it before publishing."
`probe_host()` records `gethostname()` (`provenance.jl:526-533`); `pipeline.log`
embeds whole tool logs (`src/core/log.jl`'s `_TOOL_LOG_FILES` registry and
`finalise_log`), which contain input paths and sample identifiers.

**Impact.** The artefacts built to make the science reproducible are also the
most likely vehicle for incidental personal data (usernames, hostnames, sample
identifiers, directory names containing a patient code) to travel to a journal,
a reviewer or a preprint server.

**Standards.** GDPR Art. 5(1)(c) minimisation, Art. 25, Art. 32; HIPAA
§164.502(b) minimum necessary; TOP SECRET — marking and dissemination control of
derived artefacts.

**Disposition.** N then S — (a) at export time, run a **path/identifier
scrubber** that rewrites absolute paths to `<root>`-relative and applies the
study's redaction list, and (b) *tell the user nothing*: the export simply no
longer contains `C:\Users\jsmith\…`. If a value cannot be safely rewritten the
export is refused with a clear reason, which is a `role="alert"` on an existing
error surface, not a new step. Friction: 0.

---

### SEC-14 — Personal data has no first-class state: no flags, no retention, no rights machinery (High for GDPR)

**Evidence.** Nothing in `src/` records whether a study contains personal data,
a lawful basis, a retention period, a purpose, or a subject list. Sample
identifiers and metadata are free text (`config/composition.yml`, category sets,
CSV column names). Erasure is `rm` (SEC-08). There is a study export (the report
ZIP) but it is a *manuscript* export, not a subject access export, and it carries
no index of what was disclosed.

**Impact.** For any dataset containing identifiable human data (a host-association
study with a site/participant code is enough), the controller cannot answer a
DSAR, cannot demonstrate minimisation, cannot evidence erasure, cannot bound
retention, and cannot produce a record of processing.

**Standards.** GDPR Art. 5(1)(c),(e), Art. 6, Art. 9 (if health data), Art. 12-22
rights, Art. 24, Art. 25, Art. 30, Art. 35 (DPIA is almost certainly required for
large-scale health-adjacent processing); HIPAA §164.502(b), §164.528.

**Disposition.** E first (do not accept direct identifiers: detect
identifier-shaped columns and header patterns at ingest and refuse or flag them —
the cheapest possible minimisation), then S (retention policy in config applied
by a maintenance job, and an audited erasure procedure), then N (a
`personal_data: true` flag that turns on the stricter export scrubber and the
retention clock). Friction: 0 for a study without personal data; 1 for a study
that declares it has some.

---

### SEC-15 — No rate limiting, and the SSE stream is unbounded (Medium)

**Evidence.** `@stream "/api/v1/events"` (`src/server/routes/events.jl:10`) adds
each client to a `Vector{Channel{String}}` under a lock
(`src/server/jobs.jl:38-39`); nothing caps the number of subscribers or
disconnects an idle one. No throttling exists on any route.

**Impact.** Trivial resource exhaustion; a monitoring gap in its own right.

**Disposition.** S — cap subscribers, drop the oldest idle, and add a single
token-bucket for mutating routes. Friction: 0.

---

### SEC-16 — Frontend persists study-derived UI state in browser storage (Low)

**Evidence.** `frontend/src/components/DataTable.tsx:85-92` writes column
visibility, sort and filters to `sessionStorage` under `dt:{key}`. There is no
logout, no session expiry and nothing clears it (`grep -rn logout frontend/src`
→ zero).

**Impact.** On a shared workstation, column names and filter values (which are
data values) persist for the tab's lifetime and may be recoverable afterwards.

**Disposition.** S — clear on unload and on any identity change (which arrives
with SEC-01). Friction: 0.

---

### SEC-17 — Documentation and policy drift versus the target tier (Medium)

**Evidence.** `SECURITY.md` is good and honest but describes a local tool;
`0-AI-MANIFEST.a2ml` lists an `invariants` set that includes "Do not put secrets
or private analysis data in Git" and a governance workflow set, but there is no
threat model, no data-flow map, no DPIA, no incident-response procedure, no
vulnerability disclosure SLA, no retention statement, and no classification
policy. `docs/` has no `security/` directory before this change.

**Impact.** Accreditation cannot begin from an undocumented system; a security
reviewer will ask for exactly these artefacts and there is nothing to read.

**Disposition.** N (publish) — this dossier is the start; the ultraplan adds the
threat model, DPIA skeleton, incident procedure and classification policy.

---

## 5. Standards assessment

### 5.1 GDPR (Reg. (EU) 2016/679) — article by article

| Clause | Requirement | Current state | Finding |
| --- | --- | --- | --- |
| Art. 5(1)(a)-(b) | Lawfulness, purpose limitation | No purpose or basis recorded anywhere | SEC-14 |
| Art. 5(1)(c) | Minimisation | Free-text metadata; path/username leakage on export | SEC-13, SEC-14 |
| Art. 5(1)(d) | Accuracy | Content-addressed results, config hashes — **good** (G10) | — |
| Art. 5(1)(e) | Storage limitation | No retention concept | SEC-14 |
| Art. 5(1)(f) | Integrity and confidentiality | No at-rest or in-transit crypto, no access control, world-readable dirs | SEC-01, 03, 09 |
| Art. 5(2) | Accountability | No audit trail at all | SEC-02 |
| Art. 24/25 | Controller responsibility, data protection by design | Not documented; defaults are permissive | SEC-17 |
| Art. 28 | Processor contract | Zenodo is a joint/third-party recipient with no recorded basis | SEC-05 |
| Art. 30 | Records of processing | Impossible to produce | SEC-02, SEC-17 |
| Art. 32(1)(a) | Encryption / pseudonymisation | None implemented | SEC-03, SEC-09 |
| Art. 32(1)(b) | Confidentiality, integrity, availability, resilience | Availability unbounded (SEC-07, 15); integrity good for results (G10), absent for access | SEC-07, SEC-15 |
| Art. 32(1)(c) | Restore after incident | No backup/restore path documented | ultraplan W8 |
| Art. 32(1)(d) | Regular testing | CI runs unit tests and gitleaks; no security testing of the HTTP surface beyond `test_server_security.jl` | ultraplan W7 |
| Art. 33/34 | Breach notification, 72 h | No incident procedure, no logging to investigate with | SEC-02, SEC-17 |
| Art. 35 | DPIA | Absent; likely required for health-adjacent data | SEC-14, SEC-17 |
| Art. 15-22 | Subject rights | No DSAR path, no evidenced erasure | SEC-08, SEC-14 |
| Art. 44-46 | Transfers | Zenodo publish is an uncontrolled transfer | SEC-05 |

### 5.2 HIPAA Security Rule — implementation specification by specification

| 45 CFR | Spec | Type | Current state | Finding |
| --- | --- | --- | --- | --- |
| §164.308(a)(1)(ii)(A) | Risk analysis | Required | This document is the first one | SEC-17 |
| §164.308(a)(1)(ii)(B) | Risk management | Required | `ultraplan-secure-private.md` | — |
| §164.308(a)(3) | Workforce security / sanction | Required | No workforce model exists | SEC-01 |
| §164.308(a)(4) | Information access management | Required | No authorisation | SEC-01 |
| §164.308(a)(5) | Security awareness / login monitoring | Required | No login exists | SEC-01 |
| §164.308(a)(6) | Security incident procedures | Required | Absent | SEC-02, SEC-17 |
| §164.308(a)(7) | Contingency plan | Required | No backup/restore/DR documentation | ultraplan W8 |
| §164.310(c) | Workstation security | Required | Inherited from the OS; undocumented | §5.3 |
| §164.310(d)(2)(i) | Disposal | Required | `rm` with no record | SEC-08 |
| §164.312(a)(1) | Access control | Required | **Fail** | SEC-01 |
| §164.312(a)(2)(i) | Unique user identification | **Required** | **Fail** — no identity exists | SEC-01 |
| §164.312(a)(2)(ii) | Emergency access | Required | N/A today (no access control) | — |
| §164.312(a)(2)(iii) | Automatic logoff | Addressable | No session to expire | SEC-01, SEC-16 |
| §164.312(a)(2)(iv) | Encryption at rest | Addressable | **Not implemented, not documented** | SEC-03 |
| §164.312(b) | Audit controls | **Required** | **Fail** — no access log | SEC-02 |
| §164.312(c)(1) | Integrity | Required | Good for results (G10); no baseline for config/data trees | SEC-06, SEC-12 |
| §164.312(c)(2) | Authentication of ePHI | Addressable | SHA-256 exists at artefact level (G10) — partial, undocumented | — |
| §164.312(d) | Person or entity authentication | **Required** | **Fail** | SEC-01 |
| §164.312(e)(1) | Transmission security | Required | **Fail** off loopback | SEC-09 |
| §164.312(e)(2)(ii) | Encryption in transit | Addressable | Not implemented, not documented | SEC-09 |
| §164.316(b)(2) | Six-year documentation retention | Required | Undocumented | SEC-17 |

Note on "addressable": HIPAA does not permit skipping an addressable
specification; it requires either the implementation or a documented equivalent
with the reasoning. Today there is neither for the two encryption specs.

### 5.3 TOP SECRET (Tier 3) baseline behaviours

Twenty-eight behaviours from the brief. The middle column classifies each as
something the **application** must do, something the **environment** must
provide and the app merely must not defeat (**inherited**), or something that has
**no software expression**. Only the first class is scored here.

**Verbal information**

| # | Behaviour | Class | Current state | Finding |
| --- | --- | --- | --- | --- |
| TS-01 | Chair declares the classification before a meeting; all attendees cleared | No software expression | — | — |
| TS-02 | Discuss only on IT/telephony approved for TOP SECRET | Inherited | App has no concept of an approved platform; it will happily run on an unaccredited one, unbounded, over plain HTTP | SEC-09 |
| TS-03 | Accredited meeting rooms, NACE guidance, TSCM sweeps | Inherited | — | — |
| TS-04 | Approved headphones where possible | Inherited | — | — |
| TS-05 | Personal/corporate devices, wearables and smart speakers prohibited in TOP SECRET areas | Inherited | Browser app is used on whatever device; nothing detects or records it | SEC-16 |
| TS-06 | Brief-back only to cleared staff, in a suitably secure area, per need-to-know | Application (enforcement) + inherited (area) | No need-to-know model exists; every route is open | SEC-01 |
| TS-07 | No discussion in public | Inherited / human | Nothing in the app encourages or prevents it | — |

**Hard copy**

| # | Behaviour | Class | Current state | Finding |
| --- | --- | --- | --- | --- |
| TS-08 | No unattended material; NPSA-approved physical storage | Inherited | — | — |
| TS-09 | Print only on approved devices; consider yellow paper | Inherited | The app generates the printable artefact but marks it with nothing | SEC-04 |
| TS-10 | Printed documents tethered, with a copy number on page 1 | Application (generation) | Generated HTML/PDF/XLSX/CSV carry no copy number and no marking | SEC-04 |
| TS-11 | Register in the Protected Document Registry with a reference number | Application (generation) + inherited (the book) | No registry, no reference number, no document identity | SEC-02, SEC-04 |
| TS-12 | No remote working from home at TOP SECRET | Inherited (network) | — | — |
| TS-13 | Mark "TOP SECRET" in header and footer; "UK" prefix for international partners | Application | No marking anywhere; no partner concept | SEC-04 |
| TS-14 | Mark a pack with its highest classification | Application | No classification attribute to aggregate | SEC-04 |
| TS-15 | Avoid handwritten notes; treat them as documents | Human | — | — |
| TS-16 | Never take material home | Inherited | — | — |
| TS-17 | Prefer secure printing at the destination | Inherited | — | — |
| TS-18 | Written rationale + TVRA + SCS1/SSA approval before moving documents; limited knowledge; registry checkout | Application (record) + inherited (approval) | No movement record, no approval record, no checkout | SEC-02 |
| TS-19 | Hand carriage: DV minimum, two DV escorts, double opaque tamper-evident packaging, marking inside only, return address, delivery receipt, locked discreet container | Inherited (physical) | — | — |
| TS-20 | No commercial courier domestically; approved secure mail with two DV escorts | Inherited | — | — |
| TS-21 | Overseas movement: creator + SSA/SA + SCS1 approval; diplomatic bag or military courier | Inherited + application (record) | No transfer record; and the app offers a *worse* channel — one-click public publication (SEC-05) | SEC-05 |
| TS-22 | Destruction: no destruction without written approval from the creator; return to creator first | Application | Deletion is unconditional, unapproved and unrecorded | SEC-08 |
| TS-23 | Destroy per NPSA Secure Destruction Standard with CSE products, approved shredder | Inherited (paper) / application (digital) | Digital destruction is `rm`, which does not sanitise; no NCSC secure-sanitisation path | SEC-08 |
| TS-24 | Destruction witnessed by a DV-cleared witness and recorded in the registry | Application (record) + inherited (witness) | No record, no witness field, no ledger | SEC-02 |

**Electronic information**

| # | Behaviour | Class | Current state | Finding |
| --- | --- | --- | --- | --- |
| TS-25 | Work only in organisation-authorised areas on approved equipment | Inherited | — | — |
| TS-26 | Never read material in public or in the presence of unauthorised people | Human | The UI has no "shoulder-surfing" affordance, and none is needed | — |
| TS-27 | Mark header/footer, number every page; "UK" prefix for partners | Application | Not implemented | SEC-04 |
| TS-28 | Draft, store and share only on systems approved for TOP SECRET; never on the OFFICIAL/SECRET corporate system or personal devices | Application (enforcement) + inherited | The app cannot tell what system it is on, does not encrypt at rest, and offers no way to state its own accreditation | SEC-03, SEC-09 |
| TS-29 | Lock devices when leaving the workspace | Inherited | No automatic logoff (nothing to log off) | SEC-01 |
| TS-30 | Do not send information outside the Secure Isolated Network | Application (egress) | Two egress paths exist and are controlled only by config: reference-database downloads (SEC-06) and Zenodo publication (SEC-05) | SEC-05, SEC-06 |
| TS-31 | Do not share outside the organisation without the creator's authorisation and need-to-know | Application | No creator concept, no authorisation gate on export | SEC-04, SEC-05 |
| TS-32 | Clear handling instructions in the subject line and body | Application (generated artefacts) | No artefact carries handling instructions | SEC-04 |
| TS-33 | Digital destruction per NPSA standard / NCSC secure sanitisation of storage media | Application + inherited | `rm` only; no sanitisation, no certificate of destruction | SEC-08 |

**Reading of the matrix.** Sixteen of the thirty-three behaviours have no
software expression and belong to the accredited environment; the application
must not defeat them, and today it mostly does not. Nine are *records* the
application should produce and does not (TS-10, TS-11, TS-18, TS-22, TS-24,
TS-27, TS-31, TS-32, TS-33) — those are the ones the ultraplan targets. Two
(TS-28, TS-30) are enforcement points where the application is actively
non-compliant today.

**The unavoidable conclusion.** TOP SECRET is an *accreditation* of a system,
not a property of an application. A Julia + R + DuckDB + browser stack with
dozens of third-party packages, built by an unvetted toolchain, running on a
general-purpose OS, cannot be *asserted* to the TOP SECRET standard by its own
code. What the code can do is stop being the reason an accreditation fails. The
realistic ladder is in `ultraplan-secure-private.md` §3.

---

## 6. Colour-team simulation

The full exercise — six teams, CyBOK knowledge-area mapping, scenarios, results
and the detection matrix — is in [`colour-teams.md`](colour-teams.md). Summary:

| Team | CyBOK KAs | Verdict |
| --- | --- | --- |
| **White** (governance, law, risk) | RMG, LR, POR | The policy skeleton an assessor expects (threat model, DPIA, retention, incident, classification) is absent. This dossier starts it. |
| **Red** (adversary) | AB, WAM, SS, NS, MAT | The application survives a competent web attacker *on the code surface* (path traversal, SQLi, XSS, RCE all defended — §3) and loses completely on *identity and framing*: 2 requests delete a study, 1 clickjack or 1 script on the host. |
| **Blue** (defence, SOC) | SOIM, F | Detection is essentially absent: no access log, no auth events, no integrity baseline, no alerting. Forensic readiness is, unusually, better than detection because provenance already hashes artefacts. |
| **Purple** (validation) | AB + SOIM | Of ten red scenarios, two would be visible today (both after the fact, via provenance), eight would not. Each proposed control in the ultraplan carries the detection it enables. |
| **Green** (build, crypto, platform) | SSL, SS, C, AC, OSV, DSS | Build hygiene is strong (SHA-pinned actions, hashed locks, verified installer, signed-commit policy). Crypto is entirely absent — not weak, absent. No SBOM, no reproducible build, no signed release. |
| **Gold** (human factors, insider, trust) | HF, AAA | The single-user assumption is the biggest human risk, and it is invisible to the user. Every control in the ultraplan is scored for friction; the total added user actions across the whole plan is **zero**. |

---

## 7. Attack chains (reasoned from source; not yet executed as tests)

### C1 — "Delete the study" in two requests, unauthenticated
`DELETE /api/v1/studies/{study}` → `rm(recursive=true)` on `data/` and
`projects/` (`studies.jl:233-241`). No identity, no confirmation, no record. If
the study has no active job (the only precondition, `studies.jl:236`), raw
sequence data is gone. Chains with C2 for attribution-free destruction.

### C2 — Clickjack the operator
Any web page embeds `http://localhost:8080` (no `frame-ancestors`,
`server.jl:440-447`), overlays a button, and the click arrives as a same-origin
`DELETE`. The Origin allowlist cannot help (SEC-11). Two clicks, one study.

### C3 — Poison the reference database
`PUT /api/v1/databases` with a new `uri` and no `sha256`
(`databases.jl:129`), then `POST /api/v1/databases/{key}/download`
(`databases.jl:176`), then run the pipeline. Every downstream taxonomic
conclusion is now derived from attacker-supplied data, with normal-looking
provenance, and an outbound fetch of the attacker's choosing has occurred from
inside the network (SEC-06).

### C4 — Publish to the world
`POST …/doi/publish` with `confirm: true` (`doi.jl:58-88`). Irreversible,
uncounted, unclassified. If the deployment has `DOI_ENABLED=true` and a token —
the documented configuration — one request is a reportable breach (SEC-05).

### C5 — Local peer reads everything
A second account on the same host reads `data/` and `projects/` directly,
because nothing sets restrictive modes and nothing encrypts (SEC-03). Requires
only a login on a shared box — the commonest lab deployment there is.

### C6 — Memory exhaustion
A single POST to any route that parses a body without a cap
(`_read_json_object`, `server.jl:96-118`), or a burst of pipeline job submissions
against a single-threaded R runtime, denies service to the operator (SEC-07).

---

## 8. Risk register and route inventory

### 8.1 Mutating routes (the blast radius of SEC-01)

Counted from `src/server/routes/*.jl`: **155 routes** — `GET` 64,
`POST` 54, `DELETE` 20, `PUT` 11, `PATCH` 5, `SSE` 1. The ones that matter most:

- Destructive: `studies.jl:233,288`; `runs.jl:465`; `results.jl:540`;
  `trees.jl:140`; `figures.jl:98`; `report.jl:119`; `composition.jl:231,251,367`;
  `results.jl:527`; `config.jl:631,896,981,1030`; `jobs.jl:29`;
  `phylogeny.jl:257,551`; `cladistics.jl:321`; `evidence.jl:696`.
- Executing: `pipeline.jl:622,666`; `phylogeny.jl:281,611`;
  `databases.jl:176`; `doi.jl:58`.
- Configuration: `config.jl:615,879,962,1011`; `databases.jl:129`;
  `config.jl:862` (primers).

### 8.2 Prioritised register

| Rank | ID | Finding | Sev | Effort | Ship in |
| --- | --- | --- | --- | --- | --- |
| 1 | SEC-10/11 | Security headers + `frame-ancestors 'none'` on every response | High | S | W1 |
| 2 | SEC-07 | Body cap + job concurrency cap + SSE subscriber cap | High | S | W1 |
| 3 | SEC-02 | Append-only hash-chained audit ledger, access log on | Critical | M | W2 |
| 4 | SEC-08 | Two-phase deletion with quarantine + ledger entry | High | M | W2 |
| 5 | SEC-01 | Identity from proxy/OS + per-study authorisation | Critical | L | W3 |
| 6 | SEC-03 | Restrictive modes + FDE attestation + envelope-encrypted exports | Critical | M | W3 |
| 7 | SEC-04 | Classification attribute, marking, copy numbers, export manifest | Critical | L | W4 |
| 8 | SEC-05 | Publication gate on classification + recorded approval | High | S | W4 |
| 9 | SEC-09 | Refuse non-loopback bind without TLS termination | High | S | W1 |
| 10 | SEC-06 | `databases.yml`: require https + sha256, refuse unhashed URIs | High | S | W2 |
| 11 | SEC-14 | Personal-data flag, retention, DSAR/erasure procedure | High | M | W5 |
| 12 | SEC-13 | Export path/identifier scrubber | Medium | S | W5 |
| 13 | SEC-12 | Explicit identifier validation for table/column | Medium | S | W2 |
| 14 | SEC-15 | Token bucket on mutating routes | Medium | S | W1 |
| 15 | SEC-16 | Clear browser-side UI state on unload/identity change | Low | S | W3 |
| 16 | SEC-17 | Threat model, DPIA, incident procedure, classification policy | Medium | M | W0/W6 |

---

## 9. Evidence log (reproducible)

Run from the repository root. Every claim in this report is one of these.

```bash
# 1. No authentication or authorisation
grep -rniE 'authorization|bearer|session|login|password|authenticate|jwt' src/ --include='*.jl'
#   → only src/core/doi.jl:112,119,182 (outbound Zenodo client + redaction)

# 2. No access log; docs/metrics off
grep -n 'const _SERVE_OPTIONS' -A 2 src/server/server.jl
#   → access_log=nothing, show_errors=false, docs=false, metrics=false

# 3. Middleware chain contains no identity step
grep -n 'const _MIDDLEWARE' -A 2 src/server/server.jl

# 4. No encryption at rest, no key management
grep -rniE 'encrypt|cipher|keyring|gpg|aes' src/ --include='*.jl'
#   → no matches

# 5. No filesystem permission hardening
grep -rn 'chmod\|chown\|setperm\|umask' src/ --include='*.jl'
#   → no matches

# 6. No TLS in the server ('lossless' matches a bare /SSL/i, so word-anchor it)
grep -rniE '\bTLS\b|SSL_|certfile|cert_?chain|:ssl\b' src/ --include='*.jl'
#   → no matches

# 7. No rate limiting
grep -rniE 'rate.?limit|throttl|token.?bucket' src/
#   → no matches

# 8. No classification vocabulary. Both hits are unrelated: the statistical
#    'calibration caveat' in differential results, not a handling caveat.
grep -rniE 'classification:|top secret|need.to.know|caveat:|disseminat' src/ config/ frontend/src/
#   → src/analysis/differential.jl, src/core/evidence.jl,
#     frontend/src/components/DifferentialPanel.tsx:256 (all 'calibration caveat')
grep -rniE 'top secret|need.to.know|disseminat|handling caveat' src/ config/ frontend/src/
#   → no matches

# 9. Single-user assumption, stated
sed -n '7p' src/server/jobs.jl

# 10. Destructive routes
grep -rn '@delete' src/server/routes/*.jl

# 11. Unauthenticated config and database rewrite
grep -n '@put "/api/v1/databases"' -A 12 src/server/routes/databases.jl

# 12. Publication route gate
grep -n 'doi/publish' -A 30 src/server/routes/doi.jl | head -40

# 13. Headers: the one good route vs the rest
sed -n '187,194p' src/server/routes/statistics_ui.jl
sed -n '440,447p' src/server/server.jl

# 14. Provenance data-minimisation warning, in the author's own words
sed -n '795,802p' src/core/provenance.jl

# 15. Strengths: name validation, shell safety, remote target validation
sed -n '21,22p;50,68p' src/core/validate.jl
sed -n '86,94p' src/pipeline/tools.jl
sed -n '19,48p' src/pipeline/remote_exec.jl

# 16. Strengths: R formula AST validation, SQL identifier guard
sed -n '216,260p' src/analysis/ordination.jl
sed -n '355,364p' src/core/categories.jl

# 17. Strengths: integrity of reference databases and derived records
sed -n '114,125p' src/core/databases.jl
grep -n 'does not match its ID' src/analysis/derived_analyses.jl

# 18. Strengths: CI posture
grep -n 'permissions:' -A 3 .github/workflows/ci.yml
grep -n 'pull_request_target' -r .github/workflows/ ; echo "exit=$?"
grep -n 'uses:' .github/workflows/ci.yml | head

# 19. Absence of dynamic XSS sinks in the frontend
grep -rn 'dangerouslySetInnerHTML\|innerHTML\|eval(' frontend/src
#   → no matches

# 20. Environment limits of this review
git rev-parse --is-shallow-repository   # → true
command -v julia Rscript bun            # → none present
```

---

## 10. Residual limitations

1. **No runtime evidence.** Nothing in this report was observed executing. Two
   findings (SEC-11, SEC-12) are explicitly reasoning-only; SEC-07's DoS is
   inferred from the absence of a cap, not measured.
2. **No dependency audit.** I did not consult GHSA/OSV for the Julia, R or npm
   trees. Dependabot is configured (`.github/dependabot.yml`) and Dependabot
   alerts plus Scorecard are the current evidence; that is not the same as a
   clean advisory scan, and I do not claim one.
3. **No cryptographic review** of TLS termination, if any, outside this repo;
   none is implemented here.
4. **No physical or personnel assessment**, and none is possible from a
   repository.
5. **Threat model is generic.** The actor set in §2.3 is inferred from the
   deployment documentation; if the author's real deployment differs (e.g. it is
   already behind mTLS and FDE), SEC-01's and SEC-03's severity drops
   substantially and the ultraplan's W3 shrinks to documentation. That
   distinction should be confirmed before any engineering starts.
