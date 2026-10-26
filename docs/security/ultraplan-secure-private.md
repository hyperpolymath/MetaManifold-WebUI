<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Ultraplan — secure and private: from local analysis tool to classification-ready appliance

Status: plan and evidence map for the branch
`arena/924008e1-metamanifold-webui`, based on `d6e8671` (`main`).
Companion to [`recon-report.md`](recon-report.md) (what is wrong and why it
matters), [`colour-teams.md`](colour-teams.md) (the adversarial and governance
read) and [`../proposals/security-and-integrity-ultraplan.md`](../proposals/security-and-integrity-ultraplan.md)
(the remedy schedule: the same programme expressed as harms, gates, signatures
and evidence for the people who carry institutional risk). Finding IDs `SEC-nn`
refer to the recon report.

**Why the name.** *Secure* is the confidentiality, integrity and availability
work: identity, authorisation, the audit ledger, transport, at-rest protection,
resource limits. *Private* is the data-protection work: minimisation at ingest,
retention, subject rights, the export scrubber, and a deployment posture that is
private by default rather than private by configuration. They are one programme
because they share one choke point — the point at which an artefact is created,
labelled, recorded and released — but they are separable in review, and the
rungs in §3 keep them separable in delivery. Where a commitment exists to hold
data that could identify a person *or* to be used by more than one person, both
halves apply.

**Nothing in this plan is applied.** No source file was modified by this
session; the branch adds documentation only. No test was run: the review
environment has no Julia, R or bun (see `recon-report.md` §0.3).

---

## 1. The four rules this plan is built on

### Rule 1 — Eliminate, substitute, notify, in that order

For every exposure, choose the first of these that works:

1. **Eliminate** — remove the reach, the capability or the data. Nothing to
   defend afterwards.
2. **Substitute** — replace the mechanism with a safer one that produces the
   same result for the user. Same request, same output, different internals.
3. **Notify** — record and disclose, default-safe. Reads fail open *only* where
   the data is already visible; writes fail closed.

If a control can only be implemented as "ask the user to be careful", it is not
on this list and does not ship.

### Rule 2 — Zero recurring friction

The friction budget is **zero added user actions** in the routine path
(`colour-teams.md` §6.3). Any proposal that adds a per-action prompt, a
remembered credential, or a periodic interruption is rejected in favour of a
substitute. The one-off setup cost (setting a study's classification, declaring
that it holds personal data) is capped at **two decisions per study, ever**.

### Rule 3 — One logical change per PR

`CONTRIBUTING.md` requires a branch from current `main`, no merge commits, one
logical change, CI evidence, and fast-forward merges with signed commits. Every
workstream below is therefore split into PR-sized units, each of which is
independently revertible and independently useful.

### Rule 4 — Do not touch the science

`0-AI-MANIFEST.a2ml` invariants stand: keep the settled toolchains, keep the
independent Python reference oracles, never replace scientific results with
placeholders, keep JSON as I-JSON/JCS and new config as KYAML. This plan touches
none of the numeric, statistical or pipeline logic. Where a change reaches a
route that returns a scientific result, the acceptance test is that the
**bytes are unchanged** for the same input.

---

## 2. Target architecture (what "done" looks like)

```
┌──────────────────────────── accredited boundary ────────────────────────────┐
│  operator's browser  ──HTTPS via local proxy (mTLS or OS SSO)──┐            │
│                                                                ▼            │
│    proxy asserts principal ──► Julia server (127.0.0.1 only)                │
│                                 ├─ identity middleware  (SEC-01)            │
│                                 ├─ authorisation        (SEC-01)            │
│                                 ├─ audit ledger (hash-chained, append-only) │
│                                 ├─ classification gate  (SEC-04)            │
│                                 ├─ egress allowlist     (SEC-05/06)         │
│                                 └─ resource caps        (SEC-07/15)         │
│                                                                             │
│  data/ + projects/  →  restrictive modes, inside an FDE volume (SEC-03)     │
│  exports            →  marked, numbered, manifest-hashed, envelope-encrypted│
│  every artefact     →  carries classification, copy number, provenance      │
└─────────────────────────────────────────────────────────────────────────────┘
```

Design commitments:

- **Identity is asserted, never invented.** No user table, no password store, no
  MFA prompt. The principal comes from a mutually authenticated proxy header or
  the OS account of the connecting process on a loopback socket. The server
  records it and authorises with it; it never stores a credential.
- **One audit ledger for three standards.** The same append-only records satisfy
  GDPR Art. 30/32, HIPAA §164.312(b) and the TOP SECRET registry/registry-book
  behaviours (TS-11, TS-18, TS-24).
- **One classification attribute**, inherited down study → group → run, enforced
  at one choke point, rendered everywhere.
- **One choke point per concern.** All export routes write through a single
  `_publish_artefact` function; all state-changing routes go through one
  authorisation + ledger middleware pair. If a new route is added, it is
  covered by construction, not by remembering.

---

## 3. The ladder, and which rung each workstream buys

| Rung | Meaning | Bought by |
| --- | --- | --- |
| R1 OFFICIAL-ready | safe on a managed workstation | W1, W2 |
| R2 OFFICIAL-SENSITIVE-ready | safe for sensitive personal data | W3, W5 |
| R3 SECRET-candidate | deployable inside an accredited SECRET environment | W4, W6, W7 |
| R4 TOP SECRET | an accredited component inside a Tier 3 SIN | W8 + the human gates in §7 |

Do not claim a rung above the last one whose exit criteria are signed off. The
ladder exists so that partial delivery is still a truthful statement.

---

## 4. Workstreams

Each workstream gives: objective, the exact files touched, the acceptance
evidence (a command and its expected result), the standards clauses closed, the
event(s) added to the ledger, and the friction cost.

---

### W0 — Publish the evidence base (documentation only) — **this branch**

**Objective.** An assessor can start work without interviewing anyone.

**Changes.** `docs/security/README.md`, `recon-report.md`, `colour-teams.md`,
`ultraplan-secure-private.md`; a pointer section in `SECURITY.md`; optionally a line in
`0-AI-MANIFEST.a2ml`'s `evidence` block naming the security dossier.

**Acceptance.** `docs/security/` exists, the evidence log in
`recon-report.md` §9 runs clean on `main`, and every claim in the dossier
resolves to a file and line at `d6e8671`.

**Closes.** SEC-17 (partially). **Friction.** 0.

**PR.** One. Pure documentation, no executable change, so it cannot regress the
suite.

---

### W1 — Close the zero-cost exposures (the whole of it is headers, caps, refusals)

**Objective.** Remove every attack in the recon report that needs no
architectural change. This is the highest value-per-line work in the plan and it
should ship first, in one or two PRs.

**W1.1 — Security headers on every response (SEC-10, SEC-11).**
Reuse the header set already proven on the statistics page
(`src/server/routes/statistics_ui.jl:187-194`). Add one helper in
`src/server/server.jl` and apply it in `_file_middleware` for API, static, SPA
and `/files` responses:

```julia
# Sketch only — not applied, not compiled.
const _BASE_HEADERS = (
    "X-Content-Type-Options"    => "nosniff",
    "Referrer-Policy"           => "no-referrer",
    "X-Frame-Options"           => "DENY",
    "Content-Security-Policy"   => "default-src 'self'; script-src 'self'; " *
                                   "style-src 'self' 'unsafe-inline'; img-src 'self' data:; " *
                                   "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    "Permissions-Policy"        => "geolocation=(), camera=(), microphone=(), usb=()",
    "Cross-Origin-Opener-Policy" => "same-origin",
)
```

Note the two constraints the existing app has that a naive CSP will break:
Plotly injects inline styles (`style-src 'unsafe-inline'` is required), and the
frontend is a bundled SPA (`script-src 'self'` is sufficient, no inline script).
Verify by loading the app and every panel.

**Acceptance.** `test/unit/test_server_security.jl` gains assertions that
`GET /`, `GET /api/v1/studies`, and `GET /files/...` all carry
`frame-ancestors 'none'` and `nosniff`; and a new test that the CSP header on
`/` contains no `unsafe-eval`.

**W1.2 — Resource caps (SEC-07, SEC-15).**
One middleware that rejects a request whose `Content-Length` (or accumulated
body) exceeds `MAX_REQUEST_BYTES` from `src/analysis/numeric_policy.jl:38` with
`413`; a cap on queued+running jobs in `src/server/jobs.jl` returning `429`; a
cap on SSE subscribers in `events.jl`/`jobs.jl`.

**Acceptance.** New tests: a body of `MAX_REQUEST_BYTES + 1` on
`/api/v1/studies/{s}/report` returns 413 *before* anything is written; the
`(n+1)`-th concurrent pipeline submission returns 429; `GET /api/v1/jobs`
reports no leaked channels after a subscriber cap is hit.

**W1.3 — Refuse an unaccredited bind (SEC-09).**
In `start()`: if `host` is not loopback and neither
`JULIA_METAMANIFOLD_TLS_TERMINATED=1` nor an explicit
`JULIA_METAMANIFOLD_ALLOW_PLAINTEXT=1` is set, log the reason and **refuse to
start**. Prefer refusing over warning: a warning in a startup log is not a
control.

**Acceptance.** Test that `start(host="0.0.0.0")` throws with a message naming
both escape hatches, and that the loopback path is unchanged.

**W1.4 — Strengthen the existing egress gates (SEC-06, SEC-05 default).**
`PUT /api/v1/databases`: require `https` for `uri`, require `sha256` (and
`size`) whenever `uri` is present, and require that a change to `uri` carries a
new hash. Keep the advisory warnings, but make the *refusals* hard.

**Acceptance.** Tests: `http://` URI → 400; `https://` with no hash → 400;
`local:` path outside the configured database directory → 400; a legitimate
document round-trips byte-identically.

**Closes.** SEC-05 (default path), SEC-06, SEC-07, SEC-09, SEC-10, SEC-11,
SEC-15. **Ledger events.** `limit.exceeded`, `config.write databases`,
`startup.refused`. **Friction.** 0. **Size.** S–M.

---

### W2 — The audit ledger and two-phase deletion (SEC-02, SEC-08)

**Objective.** Every state change is attributable, and destruction is a
recorded, two-step, recoverable act.

**W2.1 — `src/core/audit.jl`.**
An append-only ledger under `projects/.audit/`, one canonical-JSON record per
line, each record carrying `prev_sha256`, so the chain is verifiable. Reuse
`src/canonical.jl` (`jcs_bytes`) and `SHA.sha256`. Fixed event vocabulary in one
place (`const AUDIT_EVENTS`) so later workstreams extend it deliberately.

Record shape:

```json
{"seq":42,"at":"2026-10-25T12:00:00Z","event":"delete.requested",
 "actor":{"kind":"proxy","id":"j.smith","source":"127.0.0.1"},
 "target":{"study":"Gut2026","run":"run_A","items_sha256":"…","count":3},
 "prev_sha256":"…","record_sha256":"…"}
```

Two rules that keep it honest:
- The actor is `{"kind":"unauthenticated"}` until W3 lands; do **not** omit the
  field, or the ledger will have to be rewritten when identity arrives.
- A ledger write failure **fails the operation** for mutating events. A control
  that silently stops recording is worse than no control.

**W2.2 — Wire it.**
A middleware pair around the mutating routes (a `_ledger_middleware` beside
`_bad_request_middleware`, `src/server/server.jl:494`) plus explicit calls in
the ~12 destructive/executing/configuration routes enumerated in
`recon-report.md` §8.1. Turn on a structured access log at the same time
(replaces `access_log=nothing`, `server.jl:498`).

**W2.3 — Two-phase delete.**
`DELETE` moves the target into `projects/.quarantine/{uuid}` with a manifest
(hash, size, count, original path) and writes `delete.requested`. A new
privileged `POST /api/v1/quarantine/{id}/purge` removes it and writes
`purge.committed`. A maintenance job purges after a configurable retention
(no default purge at all, so nothing disappears unexpectedly). The UI shows a
"Recently deleted" list — a *recovery* affordance, not a confirmation step.

**Acceptance.** `julia --project=. -t2 test/unit/test_audit.jl` verifies: chain
integrity after N writes; tampering with record k is detected at k+1; a failed
ledger write aborts the delete; delete→purge sequence is order-enforced;
quarantine content hash matches the manifest; concurrent writers serialise.
Plus a route test that `DELETE /api/v1/studies/{s}` on a study with an active
job still returns 409 (behaviour unchanged).

**Closes.** SEC-02, SEC-08; TS-11, TS-18, TS-22, TS-24, TS-33 (records).
**Ledger events.** `delete.requested`, `purge.committed`, `config.write`,
`run.start`, `run.cancel`. **Friction.** 0. **Size.** M.

---

### W3 — Asserted identity and per-study authorisation (SEC-01, SEC-03a, SEC-16)

**Objective.** Every request has a principal; every principal has a scope;
nothing on the host is world-readable.

**W3.1 — `_identity_middleware`.**
Accept a principal in this order, first match wins:

1. `X-Auth-Request-User` (or a configurable header name) **only** when the
   request arrives on loopback *and* `JULIA_METAMANIFOLD_TRUSTED_PROXY=1`. This
   is the oauth2-proxy / Authelia pattern: the proxy does the hard part, the app
   records the result.
2. `SO_PEERCRED`/`getpeereid` on a Unix socket, mapping the uid to a name.
3. `ENV["USER"]` **only** for a loopback bind with no proxy — the today case,
   and it is documented as "trust the operating system's session".

The principal goes into task-local storage next to `mm_analysis_source`
(`src/server/server.jl:221`) so every route and every ledger record can read it without
signature changes.

**W3.2 — Authorisation.**
A `study_acl.yml` under `config/` mapping principal → studies (and roles
`viewer`/`editor`/`deleter`/`admin`). Default policy for a loopback,
single-user install: **permit all**, recorded in the ledger as
`{"kind":"os-session"}` — the incumbent sees no change at all. When a second
principal exists, the default flips to deny-by-default for studies they are not
granted, because by then the operator has explicitly asked for multi-user.

Every route body that takes a `{study}` gets its check through one helper,
`_authorise!(principal, study, role)`, called from `_validate_run_request` and
`_study_exists`'s callers — i.e. from the two functions every route already
calls, so coverage is by construction.

**W3.3 — Filesystem modes and at-rest position (SEC-03).**
Set `0700` on created directories and `0600` on created files
(a `_secure_mkpath`/`_secure_write` pair used by `studies.jl`, `report.jl`,
`figures.jl`, `trees.jl`, `config.jl`). Add a startup check that the data root
is on an encrypted volume where the platform can tell (Linux: `/proc/mounts`
dm-crypt/crypt target; macOS: `diskutil apfs listcryptousers`; Windows: skip and
warn), and record the verdict in the attestation and the startup log. Do not
implement application-level file encryption for the working tree: FDE is the
substitute, and a second layer inside the app adds a key to lose.

**W3.4 — Clear client-side state (SEC-16).** Clear `sessionStorage` on
`pagehide` and on principal change (`DataTable.tsx:85-92`).

**Acceptance.** Tests: request with no principal under default policy succeeds
and the ledger records `os-session`; with `trusted_proxy=1` and the header set,
the ledger records that principal; a header supplied *without*
`trusted_proxy=1` from a non-loopback peer is ignored (spoofing test); principal
A gets 403 on principal B's study once the ACL exists; a created directory is
`0700` (assert with `stat`).

**Closes.** SEC-01, SEC-03 (a), SEC-16; GDPR Art. 32(1)(b); HIPAA
§164.312(a)(1), (a)(2)(i), (d), §164.308(a)(3)(4); TS-06, TS-28, TS-29.
**Ledger events.** `auth.grant`, `authz.denied`. **Friction.** 0 with a proxy or
an OS session; 1 (one ACL file) for a team. **Size.** L — this is the largest
workstream and the only one that changes every route's assumptions. Ship it in
four PRs: middleware, ACL, helpers, modes.

---

### W4 — Classification, marking, and dissemination (SEC-04, SEC-05)

**Objective.** Every artefact the tool emits says what it is, who may have it,
and which copy it is — without ever asking the user again after study creation.

**W4.1 — The attribute.**
`classification: OFFICIAL | OFFICIAL-SENSITIVE | SECRET | TOP-SECRET` plus
`dissemination: [list]` and `originator: <principal>` on the study's
`pipeline.yml`; inherited by group and run via the existing cascade
(`src/core/config.jl`), so no new storage model is needed. Validation lives in
`src/core/validate.jl` beside `SAFE_NAME_RE`; the value is part of the config
hash, so a classification change invalidates the stages exactly as any other
config change does.

Note the cascade's existing behaviour helps here: the *most specific* level wins,
which is the opposite of what classification requires. Fix it in one place — the
effective classification is the **maximum** over the cascade, never the leaf —
and test it explicitly, because "an analyst quietly downgraded a study" is the
attack this control exists to stop.

**W4.2 — One export choke point.**
Introduce `_publish_artefact(study; bytes, kind, filename, format)` in a new
`src/server/routes/publication.jl`, used by the report ZIP, the XLSX export,
publication tables, figure rasters, tree files and the attestation. It:

1. resolves the effective classification,
2. injects the marking banner and a copy number,
3. stamps a manifest (`items`, `sha256`, `classification`, `originator`,
   `generated`, `dissemination`) into the archive and alongside the file,
4. writes `export.generated` to the ledger,
5. refuses the export if the format cannot carry a marking and the
   classification is above OFFICIAL (a CSV cannot carry a banner — so a marked
   companion `.txt`/manifest travels with it automatically; that is a
   substitution, not a refusal of the user's workflow).

Marking formats to follow exactly, from the Tier 3 behaviour table: header and
footer on every page (HTML/PDF), `TOP SECRET` on the inner packaging only when
transporting (not applicable to files), a `UK` prefix when shared with an
international partner, copy numbers `1 of 3` top-right of page 1 of a printed
pack, and a pack marked at its **highest** classification.

**W4.3 — Banner in the UI.**
A single persistent banner rendered by `App.tsx` from `GET /api/v1/capabilities`
(extend that route rather than adding one). It shows the current study's
classification and the principal. This is the software analogue of the chair's
opening declaration (TS-01) and the "handling instructions in the subject line"
behaviour (TS-32), and it costs no interaction.

**W4.4 — Gate publication (SEC-05).**
`POST /api/v1/studies/{study}/doi/publish` refuses unless the effective
classification is `OFFICIAL` and records the approval identity, the file hashes
and the DOI in the ledger on success. `DOI_ENABLED` remains the master switch.

**Acceptance.** Tests: cascade maximum (study OFFICIAL + run TOP-SECRET →
TOP-SECRET); every export route returns bytes containing the banner and a
manifest whose `classification` equals the effective value; a CSV export above
OFFICIAL produces the manifest companion automatically; publish refuses at
SECRET with `403 classification_blocked` and writes `publish.refused`; the
same-input bytes of a scientific JSON response are unchanged (Rule 4).

**Closes.** SEC-04, SEC-05; TS-09, TS-10, TS-11, TS-13, TS-14, TS-27, TS-31,
TS-32. **Ledger events.** `classification.changed`, `export.generated`,
`publish.requested|refused|completed`. **Friction.** 1 decision per study.
**Size.** L. Split into: attribute+cascade, choke point, banner, publish gate.

---

### W5 — Privacy: personal-data state, retention, rights, export scrubbing (SEC-13, SEC-14)

**Objective.** The controller can answer a DSAR, evidence an erasure, bound
retention, and stop incidental identifiers leaving in the provenance artefacts.

**W5.1 — Declare and detect.** `personal_data: true|false|unknown` on the study
(default `unknown`, which behaves like `false` but shows a one-line hint once).
At ingest, run a cheap identifier scan on column names and on sample-name
patterns (`NHS`, `MRN`, `DOB`, postcodes, `surname`, clinical-looking tokens)
and, if `personal_data` is false but the scan fires, refuse with a clear reason.
That is eliminate-by-default: the cheapest minimisation is not accepting the
identifier in the first place.

**W5.2 — Retention.** `retention_days` in config; a maintenance job (reuse the
`JobQueue`) that lists — never deletes — studies past their window, writing
`retention.due` to the ledger. Deletion stays a human act, recorded, and
two-phase from W2.

**W5.3 — Rights.** `GET /api/v1/studies/{study}/dsar` produces a manifest of
everything held for a declared subject (a study-scoped export plus the ledger
entries that touched it) — this is mostly assembly of what already exists.
Erasure is the W2 two-phase delete plus a `erasure.evidenced` ledger record that
names what was destroyed and by whom. Both write to the ledger, which is what
makes them *evidence* rather than *activity*.

**W5.4 — Export scrubber (SEC-13).** The scrubber in W4.2's choke point: rewrite
absolute paths to `<root>`-relative, drop `hostname` from published
attestations (keep it in the local copy), and apply the study's redaction list to
log text. Nothing is asked of the user; the bytes simply stop carrying
`C:\Users\jsmith\`.

**Acceptance.** Tests: an identifier-shaped column with `personal_data: false`
is refused; a DSAR manifest lists the study's files and their hashes and the
ledger slice; a published attestation contains no `hostname` and no absolute
path; erasure produces a `erasure.evidenced` record whose item hash matches what
was quarantined.

**Closes.** SEC-13, SEC-14, SEC-17 (DPIA input); GDPR Art. 5(1)(c),(e), 12-22,
30; HIPAA §164.502(b), §164.528. **Friction.** ≤1 decision per study.
**Size.** M.

---

### W6 — Assurance: SBOM, signing, sandbox, and a security test lane (SEC-12, SEC-17)

**Objective.** Make the release itself something a reviewer can trust, and make
future regressions fail CI.

**W6.1 — SBOM per release.** Emit CycloneDX for the Julia manifest, `renv.lock`
and `bun.lock` in CI; publish as a workflow artefact and attach it to the
release.

**W6.2 — Reproducible frontend build + signed release.** `--frozen-lockfile` is
already used in `start.sh`; pin `SOURCE_DATE_EPOCH`, build twice and diff the
`web/dist` hashes in CI, and sign the release bundle (sigstore/cosign or a
GPG-signed `SHA256SUMS`). Document that the *source* is signed
(`notes/commit-signing.md`) and the *artefact* now is too.

**W6.3 — Advisory gate.** Add an `osv-scanner` (or `npm audit --production` +
`bundle-audit` equivalent) step over the three lockfiles, failing on a known
vulnerable direct dependency and reporting transitive ones.

**W6.4 — Runtime hardening guidance.** `start.sh`/`docs`: run under a dedicated
unprivileged account, `systemd` with `ProtectSystem=strict`,
`ProtectHome=read-only`, `PrivateTmp=yes`, `NoNewPrivileges=yes`,
`RestrictAddressFamilies=AF_UNIX AF_INET`, and a read-only bind of the
application tree. Document that `bash -lc` and in-process R are deliberate
capabilities and that isolation therefore belongs to the unit file, not to the
router.

**W6.5 — Security test lane (SEC-12 and regression traps).**
New `test/unit/test_server_security_hardening.jl`:
- explicit identifier predicates for `{table}`/`{column}`, with a `"`-bearing
  name returning 400 (removes the "defended by consequence" pattern);
- headers present on every response class;
- body-cap and job-cap behaviour;
- spoofed proxy header ignored without the trust flag;
- ledger chain integrity;
- classification cascade maximum.

Add a fuzz lane over the JSON/YAML/NEWICK parsers (Julia `Fuzz`/simple seeded
random corpus) and a nightly `zap`-style baseline against a loopback instance.
Both are additive CI jobs; neither gates a PR until it has been green for a
week, then it does.

**Acceptance.** The new job proves: SBOM exists and lists the three trees; two
builds of the same tree give identical `web/dist` hashes; the signature
verifies; the fuzz lane runs 10k cases with no 500 and no crash.

**Closes.** SEC-12, SEC-17 (testing); the green-team gaps in
`colour-teams.md` §5 (G-02..G-07). **Friction.** 0. **Size.** M.

---

### W7 — Verification of the recon itself (turn reasoning into tests)

**Objective.** Every red-team scenario in `colour-teams.md` §2 becomes either a
test that fails before the fix and passes after, or an explicitly accepted risk.

| Scenario | Test to write |
| --- | --- |
| R-01 delete | `DELETE /api/v1/studies/{s}` moves to quarantine, does not `rm`; a second request purges (W2) |
| R-02 clickjack | response headers carry `frame-ancestors 'none'` on `/` and `/files` |
| R-03 database swap | `http://` and hash-less URIs refused; a swapped `databases.yml` cannot reach a run |
| R-04 publish | refusal at SECRET, ledger entry written |
| R-05 peer read | created dirs are `0700`; FDE check reports its verdict |
| R-06 DoS | body cap, job cap, SSE cap |
| R-07..R-11 | keep as regression tests so they stay closed |

**Acceptance.** A new `test/unit/test_threat_scenarios.jl` in which each test
names the scenario ID in its `@testset` label, so the evidence map is
machine-readable.

**Size.** S–M.

---

### W8 — The accreditation pack and the human gates

**Objective.** Everything a security assessor or a DPO asks for, produced from
the repository rather than written from memory.

Deliverables (docs only, but each must be signed):

1. **System security policy** — scope, classification policy, roles, handling
   rules, sanctions.
2. **Threat model** — asset/actor/trust-boundary from `recon-report.md` §2,
   extended with the deployment's real answer to §10.5.
3. **DPIA** (or a documented screening decision) — purpose, necessity,
   proportionality, risks, mitigations, residual risk, sign-off.
4. **Record of processing** template + a version generated from the ledger.
5. **Incident response procedure** — including the specific case "study
   published to Zenodo in error" (revocation, notification, ledger evidence).
6. **Retention and destruction policy** — mapped to W2 and W5 mechanisms.
7. **Configuration baseline** — the exact `config/defaults/*` and unit file an
   accredited instance must run.
8. **Residual risk statement** — honest, signed, with the rung from §3 named.
9. **Evidence index** — one row per claim, each with a command and a result
   (the `recon-report.md` §9 format, extended to every control).

**Human gates that cannot be closed by an agent, and must not be claimed:**

- independent security review of the changes in W1–W7;
- DPO sign-off on the DPIA;
- SSA/SA (or equivalent) acceptance of the residual risk;
- cryptographic approval of the at-rest and envelope schemes;
- platform accreditation (the SIN, the rooms, the TSCM, the personnel);
- for TOP SECRET specifically: the Government Security Group guidance the brief
  mentions is held at a higher classification, and the NCSC must be consulted
  where there is a business need. **This repository cannot contain that
  material, and this plan does not attempt to.**

**Size.** M (documentation), plus unbounded calendar time for the gates.

---

## 5. Sequencing, dependencies, and PR order

```
W0 docs ──────────────────────────────────────────────────────────► main now
W1.1 headers ─┬─► W1.3 bind refusal ─► W1.4 egress refusals
W1.2 caps ────┘                                   │
                                                   ▼
W2 ledger + two-phase delete ──────────────► W3 identity + ACL + modes
                                                   │
                                     ┌─────────────┴─────────────┐
                                     ▼                           ▼
                              W4 classification            W5 privacy
                                     └─────────────┬─────────────┘
                                                   ▼
                                        W6 assurance + test lane
                                                   ▼
                                     W7 threat-scenario tests
                                                   ▼
                                            W8 accreditation pack
```

Why this order:

- W1 first because it is the only workstream that removes live attack paths
  without touching a route's contract, and because `frame-ancestors` is
  eliminate-class.
- W2 before W3 because the ledger must exist before there is an actor to record;
  the ledger's `actor` field is populated with `unauthenticated` from day one so
  no schema migration is needed later.
- W4 after W3 because a classification whose enforcement depends on an
  unauthenticated caller is theatre.
- W5 after W4 because the export scrubber lives in W4's choke point.
- W6 and W7 last because they are evidence, and evidence of a design that is
  still moving is noise.

Each bullet below is one PR:

| PR | Content | Depends on |
| --- | --- | --- |
| 1 | W0 docs (this branch) | — |
| 2 | W1.1 headers + tests | 1 |
| 3 | W1.2 caps + W1.3 bind refusal + tests | 2 |
| 4 | W1.4 database-document refusals + tests | 2 |
| 5 | W2.1 `src/core/audit.jl` + chain tests | — |
| 6 | W2.2 wiring + access log + tests | 5 |
| 7 | W2.3 two-phase delete + UI recovery list | 6 |
| 8 | W3.1/3.2 identity + ACL + tests | 6 |
| 9 | W3.3 modes + FDE check + W3.4 client state | 8 |
| 10 | W4.1 attribute + cascade maximum + tests | 9 |
| 11 | W4.2 export choke point + manifests + tests | 10 |
| 12 | W4.3 banner + W4.4 publish gate | 11 |
| 13 | W5.1/5.2 personal-data + retention | 12 |
| 14 | W5.3/5.4 rights + scrubber | 13 |
| 15 | W6.1/6.2 SBOM + reproducible + signing | 14 |
| 16 | W6.3 advisory gate + W6.4 unit file | 15 |
| 17 | W6.5 + W7 test lanes | 16 |
| 18 | W8 pack | 17 |

PRs 5 and 2 can start in parallel with anything; everything else follows the
graph. Sixteen of the eighteen PRs add files or middleware; only PR 7, 9, 11, 12
and 14 touch existing route bodies, which keeps the review surface small.

---

## 6. Definition of done, per rung

**R1 (after W2).** Headers on every response; caps enforced; unaccredited binds
refused; every mutating route writes an audit record; deletion is two-phase;
ledger verifies; the existing suite is green and no scientific response changed
byte-for-byte.

**R2 (after W5).** Every request has a recorded principal; per-study
authorisation exists and defaults to the incumbent behaviour; data directories
are `0700` inside an attested FDE volume; exports are marked, numbered and
manifest-hashed; personal data is declared, scanned and retained on a schedule;
DSAR and erasure produce evidence.

**R3 (after W7).** All of R2, plus: every export carries a copy number and a
dissemination list; publication is gated on classification and recorded; the
build is reproducible, signed, SBOM'd and advisory-scanned; a security test lane
covers the ten red scenarios; the accreditation pack exists and every claim in it
has a command and a result.

**R4.** R3 plus the human gates in W8 and the platform accreditation. **Not
deliverable from this repository, by design and by definition.**

---

## 7. What not to build (and why)

| Tempting control | Why not | Substitute instead |
| --- | --- | --- |
| A password database / local accounts | Creates a credential to steal, a reset flow to support, and a second identity model next to the proxy's. AAA research has been clear for a decade: don't own the authenticator if you don't have to. | Asserted identity (W3.1) |
| Per-action confirmation dialogs | Click-through blindness; measurable friction with no security gain once two-phase delete exists. | Quarantine + recovery list (W2.3) |
| A classification dropdown on every export | Guarantees wrong answers within a week. | Inherited attribute set once (W4.1) |
| Application-level file encryption of the working tree | A second key to manage, a performance cost on multi-GB FASTQ, and no better threat model than FDE on a managed device. | FDE + restrictive modes (W3.3) |
| Home-grown crypto anywhere | Non-negotiable. | age/sigstore/platform primitives |
| An in-app "handling instructions" cookie banner | Nobody reads them. | Marking on the artefact itself (W4.2) |
| Rewriting the toolchain in a memory-safe language | The manifest invariants forbid it, and it addresses none of the findings in `recon-report.md` §4. | Isolation via the unit file (W6.4) |
| Deleting the DOI feature | Loses a real capability the author needs. | Gate it (W4.4) |
| Removing the remote-compute feature | Same. | It inherits the boundary; document it in the accreditation pack (W8.7) |

---

## 8. Evidence the author should expect to provide

Per rung, kept in the repository so it does not rot:

| Evidence | Command | Where it lands |
| --- | --- | --- |
| Headers on every response class | `julia --project=. -t2 test/unit/test_server_security.jl` | CI |
| Caps enforced | `julia --project=. -t2 test/unit/test_server_security_hardening.jl` | CI |
| Ledger chain verifies | `julia --project=. -t2 test/unit/test_audit.jl` | CI |
| Threat scenarios closed | `julia --project=. -t2 test/unit/test_threat_scenarios.jl` | CI |
| Classification cascade | `julia --project=. -t2 test/unit/test_classification.jl` | CI |
| Export marking and manifests | `julia --project=. -t2 test/unit/test_publication.jl` | CI |
| Reproducible frontend | `bash scripts/ci/check-reproducible-frontend.sh` (new) | CI |
| SBOM | `bash scripts/ci/emit-sbom.sh` (new) | release artefact |
| Advisory scan | `osv-scanner -r .` (new step) | CI |
| Secret scan | existing `.github/workflows/secret-scanner.yml` | CI |
| Scorecard | existing `.github/workflows/scorecard.yml` | GitHub |
| Full suite unchanged | existing `ci.yml` | CI |

Every new CI step must pin its action by SHA, take `permissions: contents: read`,
and avoid `pull_request_target`, matching the estate rules the repository already
enforces in `scripts/check-governance-contract.sh`.

---

## 9. Risks in executing this plan

| Risk | Mitigation |
| --- | --- |
| Headers break the app (Plotly inline styles, worker scripts, blob URLs) | Apply CSP in report-only mode for one release, collect violations, then enforce. Ship `frame-ancestors` and `nosniff` immediately — neither can break a legitimate page. |
| The ledger becomes a per-request write on every route and slows the API | Ledger only for mutating events and access to *classified* artefacts; batch-fsync; measure with the existing `bench/` harness and record the number in the PR. |
| Identity changes touch every route and risk a regression in scientific output | The ACL check goes into `_validate_run_request`/`_study_exists`, which routes already call; a "permit all in single-user mode" default means the incumbent path is byte-identical, asserted by a full-suite run plus a byte-comparison test on one analysis response. |
| Classification cascade maximum contradicts the config cascade's leaf-wins rule | Implement as an explicit `effective_classification()` function, not as a change to the merge, and test the contradiction directly. |
| The plan is seen as scope creep by the scientific maintainer | W1 is one PR and removes six attack paths; everything else is opt-in by rung. The `0-AI-MANIFEST.a2ml` invariants are explicitly preserved (§1 Rule 4). |
| Accreditation is asked for before R2 is real | The §3 ladder plus the residual-risk statement in W8.8 is the answer: name the rung, never the aspiration. |
| Overhead of 18 PRs on a fast-moving `main` | PRs 2, 5 and 10 are independent of everything else and can be rebased; the rest touch disjoint files by design. |

---

## 10. Indicative sizing

T-shirt sizes and the reasoning, not dates:

| Workstream | Size | Why |
| --- | --- | --- |
| W0 | S | Write-up of what is already true |
| W1 | S–M | One middleware, one helper, four refusals, tests |
| W2 | M | New module + chain verification + quarantine semantics |
| W3 | **L** | Touches every route's assumptions; four PRs; the only high-risk item |
| W4 | L | New attribute, one choke point across six export routes, marking formats |
| W5 | M | Assembling what exists; scrubber; retention job |
| W6 | M | New CI jobs, signing, SBOM, unit file |
| W7 | S–M | Mechanical once W1–W5 are in |
| W8 | M | Documentation + calendar time for the gates |

Sequence W1 now. It is small, it is eliminate-class, it regresses nothing, and
it changes the answer to "can this box be left on a lab network?" from *no* to
*it depends* — which is the first honest step on the ladder.

---

## 11. What this plan deliberately does not do

- It does not claim any rung is reached. Nothing here was run, and the
  recon was static (`recon-report.md` §0.3).
- It does not touch the analysis, statistics or pipeline code.
- It does not add a second identity system, a crypto implementation, or a
  password store.
- It does not attempt to bring TOP SECRET guidance held at a higher
  classification into this repository. The brief's own §4 says where that comes
  from: the Government Security Group, via the organisation's security team,
  with the NCSC consulted where there is a business need.
