<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Ultraplan — remedy: closing the institutional security and integrity gaps

Status: remedy plan for decision. Written against `d6e8671` on `main`.
Companion to [the proposal](../proposals/security-and-integrity-programme.md)
(why this matters, in institutional terms), [the recon report](../security/recon-report.md)
(what is wrong, with evidence), [the secure-and-private ultraplan](../security/ultraplan-secure-private.md)
(what gets built, in what order) and [the colour-team assessment](../security/colour-teams.md)
(what an adversary and a defender each conclude).

Finding IDs `SEC-nn` are the recon report's. Work packages here are `RP-n`;
they are **not** the engineering workstreams `W0`–`W8` — §0.2 explains the split
and why both are needed.

**Nothing here is implemented.** The branch adds documentation; no source file
is changed. No test was run: the review environment has no Julia, R or bun
(`recon-report.md` §0.3).

---

## 0. What a remedy plan is, and what it is not

### 0.1 The three plans, one programme

A gap can be closed three ways and each one needs a different document, because
each one is read by a different person and answers a different tense:

| Document | Tense | Reader | Produces |
| --- | --- | --- | --- |
| [Proposal](../proposals/security-and-integrity-programme.md) | *Should* we | Research office, DPO, KEC partner | A decision to act, and the language to justify it |
| [Secure-and-private ultraplan](../security/ultraplan-secure-private.md) | *How* we build it | Engineer, reviewer | Eighteen pull requests with tests |
| **This remedy plan** | *What harm is removed, for whom, and what will we be able to prove* | Risk owner, auditor, assessor, partner | A register, gates, evidence, and signature points |

A delivery plan says "add an audit ledger". A remedy plan says "the harm is an
unattributable deletion; the remedy is a ledger plus recovery; the owner is the
research office; the evidence is a chain that verifies; the claim becomes
sayable at gate R1; and if we do not do it, this is the residual risk someone
must sign."

The engineering plan without this document builds controls nobody has agreed to
own. This document without the engineering plan is a promise. They ship together
or not at all.

### 0.2 What "remedy" changes about the analysis

An engineering plan starts from the defect and works forward: *no identity →
add identity*. A remedy plan starts from the harm and works backward: *a result
cannot be attributed → which defect causes that → what removes it → who carries
it today → what evidence closes it → who signs.*

That reversal matters because **the same defect maps to different harms for
different readers**, and the harms, not the defects, are what get funded:

| Defect | Engineering statement | Remedy statement (institutional) |
| --- | --- | --- |
| SEC-01 no identity | "Add a principal middleware" | "A finding cannot be attributed to a person, so the institution cannot defend a misconduct allegation or a challenge to a published result" |
| SEC-02 no audit | "Add a hash-chained ledger" | "A subject access request cannot be answered, a breach cannot be reconstructed inside 72 hours, and a deletion cannot be evidenced" |
| SEC-03 no encryption at rest | "Set 0700 and attest FDE" | "A stolen laptop or a shared lab machine is a reportable personal data breach with no mitigating control to point to" |
| SEC-04 no classification | "Add an inherited attribute and a choke point" | "Material leaves the institution with nothing on it, so no handling instruction survives the first email" |

### 0.3 The rules that carry over, unchanged

1. **Dispose of every harm by eliminate → substitute → notify**, in that order.
   Two dispositions are added here, because an institution always has them and
   pretending otherwise is how plans lose credibility: **transfer** (contract or
   insurance) and **accept, recorded and signed**. Acceptance is legitimate. An
   *unrecorded* acceptance is the failure mode this document exists to prevent.
2. **Zero recurring friction.** Any remedy that adds a step to the analyst's day
   is rejected in favour of a substitute. The budget is stated in the proposal:
   zero added actions, at most two one-off decisions per study.
3. **Never claim above the last signed gate.** §4 defines what may be said at
   each rung and, explicitly, what may not.
4. **Do not disturb the science.** Same inputs, same bytes out. Every remedy
   work package inherits that test.

---

## 1. The remedy register

Twenty remedies. Each is a harm, not a feature: **R-01 to R-17** close the recon
report's findings, **R-18 to R-20** are institutional obligations that no code
change can discharge and that would otherwise be quietly dropped.

Columns: *class* is the disposition (E/S/N/T/A); *rung* is the earliest gate at
which the harm is materially reduced; *evidence* is the artefact an assessor
will ask for.

### 1.1 Technical harms (closed by code)

| ID | Harm, as an institution would state it | Cause | Class | Remedy | Rung | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| R-01 | A result cannot be attributed to a person | SEC-01 | S | Principal asserted by the local proxy or the OS account, recorded on every request — never a password store owned by this project | R2 | `auth.grant`/`authz.denied` ledger records; proxy configuration in the accreditation pack |
| R-02 | Anyone who reaches the port can delete a study | SEC-01, SEC-08 | E then S | Bind loopback by default and refuse an unaccredited non-loopback bind; deletion becomes two-phase with a quarantine and a recorded purge | R1 | Bind-refusal test; `delete.requested` → `purge.committed` sequence test |
| R-03 | A deletion cannot be reconstructed: not what, not by whom, not when | SEC-02 | S | Append-only, hash-chained audit ledger with a fixed event vocabulary | R1 | Chain verification test; `test_audit.jl` |
| R-04 | A breach cannot be investigated because nothing is logged | SEC-02 | E | Structured access log replaces `access_log=nothing`; destruction and release events are first-class | R1 | Access-log fixture asserted in `test_server_security.jl` |
| R-05 | A stolen laptop or shared lab machine discloses the whole dataset | SEC-03 | S | Whole-disk encryption attested at start; `0700`/`0600` at creation so the tree is not world-readable inside it | R2 | FDE verdict in the startup log and attestation; mode assertion via `stat` |
| R-06 | A file sent to a partner is unprotected in transit and at rest | SEC-03 | S | Envelope encryption (age/X25519 or the platform keychain) for anything leaving the tree | R3 | Export manifest records the recipient key and the ciphertext hash |
| R-07 | Material leaves the institution with nothing on it | SEC-04 | S | Inherited classification, marking, copy number, dissemination list and manifest at one export choke point | R3 | Export-bytes test per route; manifest equality test |
| R-08 | A study is published to a third-country platform in one request, irreversibly | SEC-05 | E then S | Publication gated on classification and on a recorded approval; `DOI_ENABLED` remains the master switch | R3 | `publish.refused` at SECRET; `publish.completed` with DOI and file hashes |
| R-09 | The science silently depends on reference data someone else chose | SEC-06 | S | Require `https` and a checksum whenever a URI is present; refuse an unhashed source | R1 | Route tests for `http://` and hash-less documents |
| R-10 | The service can be taken down during a deadline | SEC-07, SEC-15 | E | One body cap, one job cap, one subscriber cap, one token bucket for mutating routes | R1 | `413`, `429` tests; `limit.exceeded` ledger events |
| R-11 | Traffic is readable and injectable off loopback | SEC-09 | E | A non-loopback bind without documented TLS termination is a startup refusal, not a warning | R1 | Startup-refusal test naming both escape hatches |
| R-12 | The interface can be framed and clickjacked into destructive actions | SEC-10, SEC-11 | E | `frame-ancestors 'none'` and the full header set on every response class | R1 | Header assertions on `/`, `/api/…`, `/files/…` |
| R-13 | A refactor could re-open SQL identifier injection | SEC-12 | S | Explicit identifier validation at the route boundary, replacing defence-by-consequence | R2 | A `"`-bearing table name returns 400 |
| R-14 | Reproducibility artefacts leak usernames, hostnames and paths | SEC-13 | S | Export scrubber: paths root-relative, hostname dropped from published attestations, redaction list applied | R2 | Published attestation contains no hostname and no absolute path |
| R-15 | Personal data has no state: no flag, no purpose, no retention, no rights path | SEC-14 | E then S | Identifier scan at ingest refuses undeclared personal data; retention clock; DSAR manifest; evidenced erasure | R2 | Refusal test; DSAR manifest test; `erasure.evidenced` record |
| R-16 | Study-derived values persist in the browser on a shared machine | SEC-16 | S | Clear client-side UI state on unload and on principal change | R2 | Frontend test |
| R-17 | No assessment can begin because nothing is documented | SEC-17 | N | The dossier, plus the pack named in RP-7 | R1 | This document set |

### 1.2 Institutional harms (no code can discharge them)

| ID | Harm | Class | Remedy | Rung | Evidence |
| --- | --- | --- | --- | --- | --- |
| R-18 | Processing has no lawful basis, purpose or DPIA, so the institution is in breach before any defect is exploited | S (substitute a decision for an assumption) | DPIA or a signed screening decision; record of processing generated from the ledger; named controller and, if hosted for others, processor terms | R2 | Signed DPIA; ROPA export |
| R-19 | Nobody has been briefed, so the controls depend on a document nobody read | N | Role-based briefing at first use of a classified study — the software analogue of the Tier 3 requirement that users are briefed before first access and refreshed routinely | R3 | Briefing record per principal, acknowledged in the ledger |
| R-20 | A disclosure to a partner or platform has no contractual cover | T | Data transfer position documented (UK IDTA / addendum or equivalent), sub-processor list, and a KEC security schedule answered from R-01…R-17 evidence | R3 | Signed schedule; sub-processor register |

### 1.3 Register arithmetic

Seventeen technical remedies close all seventeen findings. Three
institutional remedies close what code cannot. **Six remedies reach R1** — they
are the ones that make the difference between "cannot be discussed with a
partner" and "can be discussed with caveats". Two are eliminate-class and cost
nothing to run (R-10, R-12); two are eliminate-class and cost one configuration
decision (R-02, R-11).

---

## 2. Remedy packages

Nine packages, sequenced so that each is independently fundable, independently
reviewable and independently abandonable. Each names: the harms it closes, the
engineering workstream it draws on, the artefacts it produces, its exit test, its
owner and the decision it needs.

Owner abbreviations: **PI** principal investigator / maintainer · **RO** research
office · **DPO** data protection officer · **RI** research integrity · **ITS** IT
security · **KEC** knowledge-exchange / commercial team.

---

### RP-0 — Decide (no engineering)

**Closes.** Nothing. It unblocks everything.

**Produces.** A signed decision record naming: the target rung for the next
release; the DPIA owner; the classification vocabulary; whether the author's
affiliations are stated publicly and in what wording; and whether this goes
upstream as a `Proposal:` issue before code lands.

**Exit test.** The record exists, is dated, and names an owner for RP-1 and RP-2.
Without it, no later package starts — the most common failure of programmes like
this is beginning with the code because the decision is uncomfortable.

**Decision needed.** Proposal §10, questions 1–6.

---

### RP-1 — Contain

**Closes.** R-02 (part), R-09, R-10, R-11, R-12.
Draws on W1.1–W1.4.

**Why first.** These are the remedies that remove reach rather than manage it,
they touch no analysis code, and they change the answer to "may this box sit on
a lab network?" from *no* to *it depends*. They are also the cheapest possible
demonstration that the programme will actually ship.

**Artefacts.** Header helper plus tests; one body-cap middleware; job and SSE
caps; startup refusal for an unaccredited bind; hard refusals in the database
document route.

**Exit test.** The existing suite is green; four new tests assert the refusals;
one analysis response is byte-identical to its pre-change output.

**Owner.** PI implements; ITS accepts the bind and transport position.

**Rung.** Contributes R1.

---

### RP-2 — Record

**Closes.** R-02 (remainder), R-03, R-04.
Draws on W2 and W2.3.

**Why here.** A ledger without an actor is still worth building — the `actor`
field carries `unauthenticated` from the first record — but an actor without a
ledger has nowhere to be written. Order matters and this is the order.

**Artefacts.** `src/core/audit.jl`; ledger written by every mutating route;
structured access log; quarantine and recorded purge; a "recently deleted"
recovery list in the interface.

**Exit test.** Chain verifies over N writes; tampering at record *k* is detected
at *k+1*; a failed ledger write aborts a delete; delete→purge ordering is
enforced; a deleted study is recoverable before purge.

**Owner.** PI implements; RO accepts the deletion policy and the retention window.

**Rung.** Completes R1 once RP-1 is signed.

---

### RP-3 — Attribute

**Closes.** R-01, R-16.
Draws on W3.1, W3.2, W3.4.

**Why third.** Identity is the only package with real regression risk: it changes
every route's assumptions. It is sequenced after the ledger so that its first
records are meaningful, and it defaults to the incumbent single-user behaviour so
that a solo installation sees no change at all.

**Artefacts.** Principal middleware (proxy assertion, peer credential, or OS
session); per-study access file; `_authorise!` called from the two helpers every
route already uses.

**Exit test.** Default single-user policy permits and records `os-session`; a
spoofed proxy header without the trust flag is ignored; a second principal gets
403 on a study it was not granted.

**Owner.** PI implements; ITS owns the proxy configuration; RO owns the access
grants.

**Rung.** R2.

---

### RP-4 — Protect

**Closes.** R-05, R-06.
Draws on W3.3.

**Artefacts.** Secure creation modes; encryption-position check at start (Linux
dm-crypt, macOS APFS crypto users, Windows warns and records); envelope
encryption for exports and backups.

**Exit test.** A created directory is `0700`; the startup log and attestation
carry the FDE verdict; an export decrypts with the recipient key and not without.

**Owner.** ITS owns the platform; PI implements the check and the modes.

**Rung.** R2.

---

### RP-5 — Distinguish and disseminate

**Closes.** R-07, R-08.
Draws on W4.

**Why this rung and not earlier.** A classification enforced against an
unauthenticated caller is theatre. It lands after RP-3 for that reason alone, and
it is the package that turns "our exports are unmarked" into "our exports carry
their handling".

**Artefacts.** Inherited attribute with **maximum-over-cascade** semantics;
export choke point; marking, copy number, dissemination list, manifest; banner in
the interface; publication gate.

**Exit test.** A study at OFFICIAL with a run at a higher tier exports at the
higher tier; every export route emits a banner and a manifest; publication at
SECRET is refused and recorded; a CSV above OFFICIAL carries a manifest companion
automatically rather than refusing the export.

**Owner.** PI implements; RO sets the policy; RI confirms the marking scheme.

**Rung.** R3.

---

### RP-6 — Respect rights

**Closes.** R-14, R-15.
Draws on W5.

**Artefacts.** Ingest-time identifier scan; `personal_data` flag; retention clock
that lists but never deletes; DSAR manifest; evidenced erasure; export scrubber.

**Exit test.** An identifier-shaped column with `personal_data: false` is refused;
a DSAR manifest lists the study's files, their hashes and the ledger slice; a
published attestation carries no hostname and no absolute path; erasure produces
a record whose item hash matches what was quarantined.

**Owner.** DPO owns the policy and signs the DPIA input; PI implements.

**Rung.** R2, completed at R3 once the scrubber covers every export.

---

### RP-7 — Prove

**Closes.** R-17 (completion) and the evidence question behind every other row.
Draws on W6, W7 and W8.

**Artefacts.** The accreditation pack: system security policy, threat model, DPIA
input, ROPA template, incident procedure including "published to Zenodo in
error", retention and destruction policy, configuration baseline, residual risk
statement, and an evidence index in which every claim has a command and a
retained result. Plus the assurance CI lane so the index cannot rot.

**Exit test.** A reviewer who has never spoken to the author can answer every
question in §3 of this document from repository artefacts alone.

**Owner.** RO assembles; PI supplies commands; DPO and RI sign their sections.

**Rung.** Enables R3 and is the precondition for any R4 conversation.

---

### RP-8 — Sustain

**Closes.** R-18, R-19, R-20.
Draws on nothing in the engineering plan, by design.

**Artefacts.** DPIA and ROPA in force; briefing record per principal; transfer
position and sub-processor register; annual re-attestation; a named review
cadence (§7).

**Exit test.** Every principal who has touched a classified study has a briefing
record; the ROPA matches the ledger; the transfer position is signed.

**Owner.** DPO and RO jointly; ITS for the technical attestations.

**Rung.** R2 for the DPIA, R3 for briefing and transfer.

---

## 3. Gates: what may be claimed, by whom, when

A gate is not a milestone; it is a **permission to say something**. The right
column is the part that keeps the programme honest under pressure.

### R1 — Contained and recorded

**Signed by:** PI and ITS. **Needs:** RP-1, RP-2 complete and green.

| May say | May not say |
| --- | --- |
| "Deletions and releases are recorded and recoverable" | "Access is controlled" — it is not, until R2 |
| "The tool refuses to be exposed without TLS termination" | "The tool is secure" — no assessment has been done |
| "Reference data cannot be substituted without a checksum" | "The data is encrypted" — the platform position is unverified until R2 |
| "Denial of service by unauthenticated request is bounded" | "GDPR compliant", "HIPAA compliant", "TOP SECRET ready" |

### R2 — Attributed and protected

**Signed by:** PI, ITS, DPO. **Needs:** RP-3, RP-4, RP-6 (policy half), RP-8 (DPIA).

| May say | May not say |
| --- | --- |
| "Every request is attributable to a principal" | "Need-to-know is enforced institution-wide" — only per study |
| "Data sits inside an attested encrypted volume with restrictive modes" | "Exports are safe to share" — they are unmarked until R3 |
| "A subject access request and an erasure can be evidenced" | "The institution is compliant" — that is the DPO's determination, not the tool's |
| "Personal data is declared, scanned and retained on a schedule" | "TOP SECRET candidate" — that is R3 |

### R3 — Distinguished and provable

**Signed by:** PI, RO, DPO, RI, and an independent reviewer. **Needs:** RP-5, RP-6 (scrubber), RP-7, RP-8 (briefing and transfer).

| May say | May not say |
| --- | --- |
| "Every artefact carries its classification, copy number and handling" | "Accredited" — that is R4 and the environment's to give |
| "Release outside the institution is gated and recorded" | "TOP SECRET" in any form |
| "A partner's security schedule can be answered from repository evidence" | "Certified", "approved for government use", or any rung above R3 |

### R4 — Not offered

TOP SECRET is an accreditation of a system **inside** an accredited environment:
the Secure Isolated Network, the accredited rooms, the TSCM sweeps, the DV-cleared
staff, the approved couriers and the destruction products are all environmental,
and sixteen of the thirty-three Tier 3 baseline behaviours have no software
expression (`recon-report.md` §5.3). This plan does not take a system to R4. It
takes the *code* from being a reason an accreditation fails to not being one.

**Gate discipline.** A gate is signed once, with a date and a named signatory,
and it can be withdrawn. If a later change weakens a control a gate depends on,
the gate is suspended in the same pull request that weakens it — not in the next
review cycle.

---

## 4. The answer pack: what a partner asks, and what we can say

This is the deliverable that makes the programme visible to a university or a
KEC partner. Each row is a question that appears in a real due-diligence
schedule; the value at each rung is the answer the institution is *permitted* to
give under §3.

| # | Question in the schedule | At R1 | At R2 | At R3 | Evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | Who can access the data? | Anyone with host access (single-operator tool) | Named principals, per-study grants | Same, plus recorded briefing | `study_acl.yml`; `auth.*` records |
| 2 | Is access logged? | Yes — every state change and release | Same, with actor | Same, plus classification context | Ledger chain |
| 3 | Is data encrypted at rest? | Platform-dependent, now recorded rather than assumed | Attested FDE + restrictive modes | Same, plus encrypted exports | Startup verdict; mode assertions |
| 4 | Is data encrypted in transit? | Not by the server; a non-loopback bind is refused without TLS termination | Same | Same | Bind-refusal test |
| 5 | Can you delete data on request? | Yes, and deletion is recoverable before purge | Same, plus evidenced erasure | Same | `delete.requested`, `erasure.evidenced` |
| 6 | How long is data retained? | Not enforced (policy only) | Enforced clock, listed not auto-deleted | Same | `retention.due` records |
| 7 | Are releases to third parties controlled? | Recorded after the fact | Recorded | Gated on classification before release | `publish.*` records |
| 8 | Are sub-processors identified? | No | No | Yes, with transfer position | Sub-processor register |
| 9 | How is personal data minimised? | Not addressed | Identifier scan at ingest; scrubber on export | Same | Refusal test; manifest |
| 10 | Can a result be attributed and shown unaltered? | Unaltered: yes. Attributed: no | Both | Both, with classification | Content-addressed records + ledger |
| 11 | What is your incident process? | None documented | Drafted (RP-7) | Signed and drilled | Incident procedure |
| 12 | How do you demonstrate all of the above? | By inspection of this repository | Same, plus R2 artefacts | Same, plus a signed evidence index | Evidence index |

Rows 1, 3, 5, 7 and 12 are the ones that most often stop a KEC agreement. R1
moves five of them from "no answer" to "answer with a caveat"; R3 moves all
twelve to "answer with evidence".

---

## 5. The KEC and commercial annex

Things a partner will ask that are not security controls and that therefore get
missed:

| Item | Position | Action |
| --- | --- | --- |
| **Licence** | AGPLv3 for code, CC-BY-SA for documentation | State it in the schedule before the partner's legal team finds it. AGPLv3 obligations on a hosted deployment are real; the institution should take its own advice |
| **Controller / processor** | Depends on deployment: the deploying institution is controller; the maintainer becomes a processor only if hosting for others | Decide once (RP-0), state in `SECURITY.md` |
| **Data transfer** | A published study may leave the UK; a Zenodo deposition is a transfer | Document the mechanism at R3 or disable the route |
| **Sub-processors** | Reference-database hosts (GitHub releases, PR2), Zenodo, the remote compute host | Register at R3; the remote host is inside the accredited boundary or it is not used for classified work |
| **Export control / dual use** | Bioinformatics methods are not controlled, but the *data* may be | Confirm with the institution's research office before any classified deployment |
| **Publication rights** | The tool's provenance and citation artefacts are designed to be published | A partner agreement must not conflict with the reproducibility claims |
| **Liability and insurance** | No warranty beyond the licence; the remedy programme is the mitigation of record | The residual-risk statement (RP-7) is what an insurer or a contracts team will read |
| **Support expectations** | `SECURITY.md` commits to fixes on `main` and no response time | State it plainly; a partner assuming an SLA is a risk in itself |

---

## 6. Evidence: the register as data, not prose

The engineering plan already requires new estate configuration to be KYAML
(flow style, double-quoted values, two-space indent, `---` header) per the
YAML-POLICY rule the statistics work follows. The remedy register should be
data for the same reason the numeric contracts are: a claim that a human
re-types into a spreadsheet is a claim that drifts.

```kyaml
---
{ schema: "assurance-register/1", generated: "2026-10-25",
  remedies: [
    { id: "R-01", harm: "A result cannot be attributed to a person", cause: "SEC-01",
      disposition: "substitute", rung: "R2", owner: "PI",
      evidence: "test/unit/test_audit.jl", gate: "R2", state: "planned" },
    { id: "R-12", harm: "The interface can be framed and clickjacked", cause: "SEC-10, SEC-11",
      disposition: "eliminate", rung: "R1", owner: "PI",
      evidence: "test/unit/test_server_security.jl", gate: "R1", state: "planned" }
  ],
  gates: [
    { id: "R1", signed_by: ["PI", "ITS"], signed_on: null },
    { id: "R2", signed_by: ["PI", "ITS", "DPO"], signed_on: null },
    { id: "R3", signed_by: ["PI", "RO", "DPO", "RI", "independent"], signed_on: null }
  ] }
```

Two rules for this file if it is adopted:

1. `state` moves only from `planned` → `implemented` → `verified`, and
   `verified` requires the named command to have run in CI on the commit that
   claims it.
2. A gate is `signed_on`-dated or it does not exist. A null date in `gates` is
   the machine-readable version of "we have not claimed this".

A governance check in the style of `scripts/check-governance-contract.sh` can
then fail CI when a remedy is marked `verified` without a corresponding test
file, which is the only way this register stays true after everyone who wrote it
has moved on.

*This sketch is not validated against the KYAML formatter: the tool is not
available in the review environment. It is illustrative of shape, not a
committed artefact.*

---

## 7. Sequencing, critical path and cadence

### 7.1 Order and dependencies

```
RP-0 decide
   │
   ├─► RP-1 contain ──► RP-2 record ──► [GATE R1]
   │                        │
   │                        ├─► RP-3 attribute ─┐
   │                        └─► RP-4 protect ───┤
   │                                            ├─► [GATE R2]
   │                        RP-6a rights (policy)┘
   │                        RP-8a DPIA ──────────┘
   │
   └─► RP-5 distinguish ◄── RP-3 ──► RP-6b scrubber ──► RP-7 prove ──► [GATE R3]
                                                           │
                                                           └─► RP-8b briefing + transfer
```

**Critical path:** RP-2 → RP-3 → RP-5 → RP-7. Everything else can proceed in
parallel or be delayed without moving a gate. That is deliberate: a remedy
programme that stalls should stall in the cheapest place.

**Parallel-safe:** RP-1 before RP-2; RP-4 any time after RP-3 starts; RP-6a and
RP-8a alongside RP-3; RP-0 questions 3–6 need no engineering at all.

### 7.2 Milestones without dates

Calendar dates in a plan written by an agent are fiction. These are
effort-ordered, so they can be rescheduled without invalidating anything:

| Milestone | Reached when | What it buys |
| --- | --- | --- |
| M0 | RP-0 record signed | The programme has an owner |
| M1 | RP-1 merged and green | Six attack paths gone, no friction added |
| M2 | RP-2 merged, chain verifies | Gate R1 claimable |
| M3 | RP-3 and RP-4 merged, DPIA drafted | Gate R2 claimable |
| M4 | RP-5 and RP-7 merged, independent review complete | Gate R3 claimable |
| M5 | RP-8 sustained through one review cycle | The claims survive staff turnover |

### 7.3 Cadence once M2 is passed

| Interval | Activity | Output |
| --- | --- | --- |
| Per pull request | Remedy register updated; evidence command run | `state` transitions only |
| Per release | Re-verify every `verified` remedy's command | Evidence index refreshed |
| Quarterly | Gate review: is each signed gate still supported? | Withdrawal or renewal, recorded |
| Annually | Re-attestation: FDE position, access grants, retention settings, briefing records | Signed annual statement |
| On any incident | Ledger slice pulled, procedure executed, lessons recorded | Incident report that cites ledger evidence, not recollection |

---

## 8. Metrics, honestly chosen

Metrics in security programmes are usually vanity. These are chosen because they
can be *wrong* in a way that is visible:

| Metric | Why this one | Failure it reveals |
| --- | --- | --- |
| Schedule questions answerable with evidence | It is the outcome a partner cares about | A programme building controls nobody asked for |
| Time to answer a DSAR from the ledger | It is a legal clock | An audit trail that exists but cannot be queried |
| Deletions recovered from quarantine | Shows the recovery path works in practice | A two-phase delete that is never actually two-phase |
| Remedies marked `verified` whose command has not run this release | Detects drift in the evidence itself | Documentation theatre |
| Added user actions per release | The hard constraint | A control smuggled in as "just a quick confirm" |
| Gate withdrawals | A gate that never withdraws was never real | Compliance theatre |

The last two are the ones to watch. A programme that only ever adds gates is not
measuring anything.

---

## 9. Stop/go, partial claims, and rollback

**If a package stalls**, the remedy register records it and the gate it blocks is
simply not signed. That is the whole point of the ladder: R1 is a complete,
useful, signable state. A university can run R1 indefinitely and say true things
about itself.

**If a gate must be withdrawn**, the withdrawal is dated, the reason recorded, and
every outward-facing statement that relied on it is revised in the same change.
A claim that outlives its evidence is the one failure this document cannot
forgive.

**If a package is abandoned**, its harms move to R-*accepted* entries with a named
owner and a date, or the gate that depended on it is withdrawn. There is no third
option, because the third option is "nobody noticed".

**Rollback.** Every package is one or more revertible pull requests (proposal §8).
Reverting a package suspends the gate that depended on it in the same change.
Nothing in this plan requires a database migration or an irreversible state.

---

## 10. Risks of the remedy itself

| Risk | Why it is real here | Mitigation |
| --- | --- | --- |
| **Compliance theatre** | Documents accrete faster than controls; this plan adds seven artefacts | The evidence index pairs every claim with a command; a claim without one is withdrawn |
| **Over-claim** | The pressure to say "compliant" in a KEC negotiation is enormous | §3 states what may *not* be said at each gate, in the same table as what may |
| **Scope creep into the science** | Security work is easier to argue about than statistics | Rule 4: same inputs, same bytes; one byte-comparison test per package |
| **Burnout of a sole maintainer** | Eight packages on top of a research codebase | RP-1 and RP-2 are small and self-contained; the critical path has four nodes, not eighteen |
| **The plan outlives its author** | Research software changes hands | The register is data (§6), gates are dated, and the CI check fails rather than remembers |
| **False comfort from a green suite** | CI passing is not a security finding being resolved | `SECURITY.md` already says this; RP-7 repeats it in the pack |
| **Institutional risk parked on one person** | The tool's origin is one researcher's judgement | RP-0 names the DPIA owner and the gate signatories; a gate with one name is not a gate |

---

## 11. Decisions required to start

Carried forward from the proposal, with the remedy-specific consequence of each:

| # | Decision | Blocks | Consequence if unanswered |
| --- | --- | --- | --- |
| 1 | Target rung for the next release: R1 or R2 | RP-0 | Package selection is guesswork; RP-5 may be built before it is enforceable |
| 2 | Publish as a `Proposal:` issue before code | RP-0 | An architectural change lands without the discussion this repository's convention requires |
| 3 | DPIA owner: institution or maintainer | RP-6a, RP-8a | Gate R2 cannot be signed; R3 is unreachable |
| 4 | Classification vocabulary: UK GSC or an institution profile | RP-5 | The attribute is built twice, or built for the wrong audience |
| 5 | Programme name for outward material | RP-7 | The pack cannot be titled, so it cannot be circulated |
| 6 | Author affiliation wording | RP-7 | §5 of the proposal stays internal, weakening the strongest paragraph it has |
| 7 | *New:* who signs each gate | §3 | The whole table is unenforceable; gates become self-certification |
| 8 | *New:* retention window before purge | RP-2 | Quarantine grows forever, or purges by surprise |
| 9 | *New:* is any deployment expected to hold personal data in the next 12 months | RP-6, RP-8a | Either the DPIA is written unnecessarily, or it is written too late |

Decisions 7–9 are the ones a delivery plan never asks and a remedy plan cannot
avoid.

---

## 12. What would make this plan wrong

Stated plainly, so that it can be falsified rather than defended:

1. **If the deployment is already inside an accredited environment** with mTLS, a
   proxy identity, FDE and an audited host, then R-01, R-05 and R-11 are already
   satisfied environmentally and RP-3 and RP-4 shrink to documentation plus
   attestation. The institution's answer to proposal §10 and
   `recon-report.md` §10.5 settles this.
2. **If no deployment will ever hold personal data**, RP-6 and RP-8a are
   unnecessary, R-15 becomes a recorded acceptance, and R2 collapses into R1 plus
   RP-4.
3. **If no third party will ever receive an artefact**, RP-5's dissemination half
   is unnecessary — though marking is still the cheapest possible mitigation for
   the copy that gets emailed anyway.
4. **If the review's static findings are wrong**, the register shrinks. Each row
   cites the grep that would prove it wrong; a correction belongs in the same
   pull request as the finding.
5. **If the programme is judged not worth funding**, the honest output is a
   signed acceptance of R-19, R-02 and R-03 with a date and a name — and the
   withdrawal of any claim that implied otherwise. That outcome is legitimate.
   Silence is not.

---

## 13. Where to read the detail

| Document | What it contains |
| --- | --- |
| [Proposal](../proposals/security-and-integrity-programme.md) | The institutional case: the blind spot in how research software is reviewed, the provenance of the design, the risk table in each owner's terms, and the ladder |
| [Recon report](../security/recon-report.md) | Seventeen findings with file-and-line evidence; twelve existing controls recorded as sound; GDPR article-by-article; HIPAA specification-by-specification; all 33 TOP SECRET behaviours classified; a twenty-command evidence log |
| [Secure-and-private ultraplan](../security/ultraplan-secure-private.md) | The engineering counterpart: eight workstreams, eighteen pull requests, acceptance tests, ledger events, and the controls deliberately not built |
| [Colour-team assessment](../security/colour-teams.md) | White, red, blue, purple, green and gold over CyBOK knowledge areas; twelve red scenarios; the detection matrix; the conflicts and how each resolves |

---

*This plan is a remedy schedule, not a certificate. Each remedy in it is a harm
somebody owns, a mechanism that removes or reduces it, and a command that shows
whether the claim is still true. Where the answer is "we accepted this", the
document asks for a signature rather than silence.*
