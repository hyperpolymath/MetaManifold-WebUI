<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Proposal: a security and integrity programme for institutional and commercial use

Status: proposal for decision. Written against `d6e8671` on `main`.
The evidence behind every claim below is in
[the recon report](../security/recon-report.md); the delivery plan is
[the secure-and-private ultraplan](../security/ultraplan-secure-private.md);
the adversarial read is [the colour-team assessment](../security/colour-teams.md);
and the remedy schedule — which harm each control removes, who signs for it, and
what may be claimed at each gate — is
[the remedy ultraplan](security-and-integrity-ultraplan.md).

---

## Summary

MetaManifold is a research tool for amplicon metabarcoding, and it is a good one:
the statistics are exact rather than approximate, the provenance is
content-addressed, and the path-traversal defences are better than most
commercial products. That is precisely why the gap this proposal addresses is
worth writing down.

**It has no identity, no audit trail, no encryption at rest, and no way to mark
what it produces.** Any process on the host can delete a study. Any request that
reaches the port can rewrite the reference database the science then depends on.
Any export leaves unlabelled. Those are not statistical defects and no amount of
methodological review will surface them — which is exactly why they survive in
research software for years, in this lab and in a hundred others.

This proposal asks for a decision on a bounded programme that closes them,
without adding a single step to the analyst's working day. It is written for the
people who carry the institutional risk rather than the ones who run the
pipeline: research office, data protection officer, research integrity officer,
IT security, and the industrial or public-sector partner performing due
diligence before a knowledge-exchange agreement.

---

## 1. The blind spot this addresses

Research software is reviewed at the level of detail that its authors care
about, and that is nearly always the method. This repository shows the pattern
in its own issue history: proposals here argue about tie handling in a rank test,
parity tolerances against an R oracle, and whether dispersion shrinkage is
stable at small *n*. Those arguments are correct to have. They are also
unrepresentative of what an institution actually needs to be able to say about
the tool afterwards.

The same community that will spend three weeks on a dispersion prior will run
the resulting table through software that cannot tell you who deleted last
month's run, whether the export carried a patient code, or whether the reference
database changed between two analyses of the same samples.

The asymmetry is structural, and it is not a criticism of any one project:

| What a methods review examines | What a reputational, regulatory or contractual review examines |
| --- | --- |
| Estimator correctness, parity with a reference implementation | Who could have altered the result, and can that be shown? |
| Tolerances, convergence, edge cases | Where the data lives, who can read it, what protects it at rest |
| Reproducibility of the numbers | Reproducibility of the *decision*: approvals, releases, deletions |
| Software licence and citation | Handling, retention, transfer, and deletion with evidence |
| Test coverage of the algorithm | Test coverage of the authorisation boundary |

Everything in the left column is done well here. Everything in the right column
is, at `d6e8671`, absent — and absent in the same way in most tools a university
would deploy tomorrow.

The point of this proposal is not that MetaManifold is unusually unsafe. It is
that MetaManifold is unusually *well placed* to fix the pattern, because the
engineering discipline needed is already demonstrated in the parts of the
codebase nobody outside the project will ever look at.

---

## 2. What is actually there, and what is actually missing

This is the paragraph to read if you read only one. It is measured, not
aspirational: each row can be reproduced with a command in the recon report's
evidence log.

**Present and sound** (twelve controls, all cited to a file and line in the
report): entity-name validation before any name reaches a path; `realpath`
containment on every file-serving route; an Origin allowlist that also defeats
DNS rebinding, with unit tests for the refusal cases; Oxygen's docs and metrics
disabled; parameterised SQL with an explicit identifier guard; shell-quoting
plus metacharacter gating plus remote-target validation; a strict AST parser
that refuses arbitrary call expressions in R formulas; upload size caps and a
sandboxing CSP on uploaded bytes; SHA-256 and size verification of every
reference database; content-addressed analyses that refuse a tampered record;
secret hygiene with a redaction path; and CI with SHA-pinned actions, least
privilege, full-history secret scanning and a signed-commit policy.

**Absent** (four absences, from which every serious finding follows):

| Absence | The one-line consequence | Grep that proves it |
| --- | --- | --- |
| No identity | any process, page or person that reaches the port has the operator's full authority, including deletion | `grep -rniE 'authorization\|session\|login' src/` finds only the outbound Zenodo client |
| No audit trail | after a deletion there is no record of what, by whom, when, or whether it worked | `access_log=nothing` at `src/server/server.jl:498`; deletion is recursive `rm` |
| No encryption at rest | a shared host, a backup, a sync client or a stolen disk yields the whole dataset | `grep -rniE 'encrypt\|cipher' src/` → no matches |
| No classification model | every artefact the tool emits is unmarked and unscoped | `grep -rniE 'top secret\|need.to.know\|disseminat' src/ config/ frontend/src/` → no matches |

Two further findings matter to a partner's questionnaire rather than to a
statistician, and both are one-request exploits rather than theoretical:
**`POST …/doi/publish` will publish study files to Zenodo** once the deployment
enables DOIs, with `confirm: true` as the only gate; and
**`PUT /api/v1/databases` accepts an `http://` URI with no checksum**, after
which the pipeline classifies against content chosen by whoever made that
request.

---

## 3. Who this is for, and what each of them asks

| Audience | The question they actually ask | What answers it here |
| --- | --- | --- |
| Research office / faculty | "If this goes wrong, can we show we took it seriously before it did?" | Audit ledger, two-phase delete, published dossier, DPIA input |
| Data protection officer | "Lawful basis, minimisation, retention, subject rights, breach reconstruction in 72 hours?" | Privacy workstream, retention policy, DSAR and erasure evidence |
| Research integrity officer | "Can a result be attributed and shown unaltered?" | Content-addressed records (present) + actor attribution (absent) |
| IT security | "Where does it run, what protects it, what leaves it?" | Bind refusal, transport position, egress gates, at-rest position |
| Industry / KEC partner | "Encryption, access control, audit, deletion certification, sub-processors?" | The same table, answerable from repository artefacts |
| Ethics committee | "Who bears the risk of this data, and is that documented?" | Classification attribute, marking, DPIA, handling policy |
| Funder / journal | "Is the analysis reproducible and the material handled correctly?" | Provenance (present) + marking and scrubber (absent) |

That last column is the whole proposal in one sentence: **it should be possible
to answer a partner's security questionnaire from the repository, not from the
memory of whoever set the machine up.**

---

## 4. What is proposed

Four commitments, each substituting a mechanism rather than adding a task:

| Absence | Commitment | Mechanism | Added user actions |
| --- | --- | --- | --- |
| No identity | Every request has a recorded principal, asserted by the local proxy or the operating system — never a password database maintained by this project | One middleware plus a per-study access file | **0** |
| No audit | Every state change and every release of material is written to an append-only, hash-chained ledger | New `src/core/audit.jl` reusing the canonical-JSON and SHA-256 primitives already in the tree | **0** |
| No encryption at rest | Data sits inside a whole-disk-encrypted volume with restrictive modes; anything that leaves is envelope-encrypted | Filesystem substitution plus creation modes | **0** (once, at install) |
| No classification | Every artefact carries its classification, a copy number, a dissemination list and a manifest | One export choke point plus an inherited attribute | **≤2 decisions per study, ever** |

Deletion becomes two-phase: the item disappears from the interface immediately,
exactly as today, and its removal is recorded and recoverable before it is
purged. That single change satisfies three interested parties at once — the
adversary needs two recorded requests, the auditor gets an event, and the
analyst gets no new dialog to dismiss.

### The ladder, so that partial delivery is still a truthful claim

| Rung | What an institution may then say | Timeframe |
| --- | --- | --- |
| **R1** | "Safe to hold OFFICIAL-tier research data on a managed workstation; deletions and releases are recorded" | First two workstreams |
| **R2** | "Safe to hold sensitive personal data; identity, retention and subject rights are evidenced" | Adds privacy and identity |
| **R3** | "Candidate for deployment inside an accredited SECRET environment; exports are marked and releases are gated" | Adds classification and assurance |
| **R4** | TOP SECRET | **Not offered here.** It is an accreditation of a system inside an accredited environment, not a property of an application |

No rung above R1 is claimed by this proposal, and none should be cited in a
partner conversation until its exit criteria are signed off.

---

## 5. Where the design comes from

MetaManifold was designed by **Joshua Jewell**, a leading Royal Veterinary
College ethicist and welfare specialist, formerly a member of the **BIOCEV**
laboratory in Prague, Czechia, with **Charles University**, and an associate of
**Vladimír Hampl**.

That provenance is not decoration, and it explains the shape of the tool. Ethics
and animal-welfare review is a discipline built around three questions that map
directly onto data governance: *who bears the risk of this decision, who cannot
consent to it, and what evidence will I be able to show that I weighed it
properly?* The same habit produces a tool whose outputs are content-addressed
and immutable, whose configuration is hashed so that a silent change invalidates
the downstream stages, whose reference databases are checksum-verified before
and after download, and whose publication path is disabled unless deliberately
configured.

The instinct was right from the outset; what was missing was the part of the
field that has no welfare tradition to borrow from — identity, audit and
encryption — and the vocabulary of institutional risk. This programme supplies
that without asking the author to become a security vendor, and without asking
users to change how they work.

Practically, that means the tool was built for **proper ethical and commercial
use from the beginning**, not retrofitted with a compliance veneer: the licence
is AGPLv3 for code and CC-BY-SA for documentation, the citation file is
maintained, the provenance record is designed to be published, and the
deployment posture is local-first and offline-capable rather than
cloud-dependent. Institutions should still take their own advice on AGPLv3
obligations; this proposal does not change the licence.

---

## 6. Integrity (measured, not aspirational)

Following the house convention for proposals in this project: state what is
verified, state what is *not* there, and do not dress a plan as a result.

**Verified today.** The twelve controls in §2, each with a file-and-line
reference and a reproducing command. Two of them — the Origin allowlist and the
DNS-rebinding refusal — have regression tests that assert the refusal cases, not
just the happy path.

**Not present today.** The four absences, the two one-request exploits, and the
supporting evidence artefacts an assessor expects (threat model, DPIA, retention
schedule, incident procedure, classification policy). None of these exists in
the repository at `d6e8671`.

**Not claimed.** No penetration test has been performed. The review behind this
proposal is *static*: it was produced without a Julia, R or bun runtime, on a
shallow clone, and no request was ever sent to a running server. Two findings
are explicitly reasoning-only until tests exist. A green CI run is not a claim
that a security finding is resolved, and the repository already says so in
`SECURITY.md`. Any statement that the tool is "GDPR compliant", "HIPAA
compliant" or "TOP SECRET ready" today would be false, and would be the first
thing a diligent partner dismantles.

**What the programme would make verifiable.** For each rung, a named command
whose result is retained in CI and in an artifact, so that the claim is
reproducible by the institution rather than trusted by it.

---

## 7. The risk, in the terms the institution owns it

| Risk | Who owns it | Answer at `d6e8671` | After W1 | After W2 | After W4 |
| --- | --- | --- | --- | --- | --- |
| A result cannot be attributed to a person or a moment | Principal investigator, research integrity | none | none | ledger records the actor and the artefact hashes | same, plus classification context |
| Data deleted by mistake, or by someone who should not have been able to | Group lead, research office | unrecoverable, unattributable | unchanged | quarantine + recorded purge | unchanged |
| Personal data on a shared or stolen machine | DPO, institution as controller | plaintext, world-readable by default | restrictive modes | FDE position recorded | unchanged |
| A subject access request or an erasure request | DPO | no mechanism, no evidence | unchanged | DSAR manifest + erasure evidence | same |
| Material released to a third country platform in error | Research office, contracts | one request, irreversible | one request, irreversible | recorded, still irreversible | gated on classification and recorded |
| A partner's security questionnaire | KEC / commercial team | unanswerable | answerable in part | mostly answerable | answerable with evidence |
| Reference data silently substituted | Research integrity | possible in one request | refused unless https + checksum | logged | logged |
| Denial of service during a deadline | Group lead | trivially achievable | capped | capped and recorded | same |
| Handling instructions missing from an exported table | Whoever receives it | nothing on the artefact | unchanged | unchanged | marking, copy number, manifest |

The last row is the one that travels. A spreadsheet leaves the institution with
a name on it; a table exported by this tool currently leaves with nothing. No
policy document survives contact with a shared drive, but a banner in cell A1
does.

---

## 8. Cost, sequence, and friction

- **Scope:** eight workstreams, eighteen revertible pull requests. Two of them
  (headers, size caps) remove six live attack paths and touch no analysis code.
- **Effort:** four small, three medium, one large. The large one is identity,
  because it changes every route's assumptions; it is the only item with real
  regression risk, and it is sequenced after the ledger so that its records are
  meaningful when it lands.
- **Friction:** zero added user actions across the whole programme, with at most
  two one-off decisions per study. The plan rejects confirmation dialogs,
  per-session passwords and per-export classification dropdowns on human-factors
  grounds, and substitutes mechanisms that cost nothing in the routine path.
- **Invariants preserved:** no change to the numeric or statistical logic; the
  same outputs byte-for-byte for the same inputs; no new TypeScript application
  logic; JCS/I-JSON at the boundary; new configuration as KYAML. The
  repository's own manifest rules stand.
- **First step:** one pull request. Security headers on every response, request
  and job caps, refusal to bind a non-loopback address without documented TLS
  termination, and hard refusals in the database-document route. It is small, it
  is additive, it cannot regress the science, and it changes the answer to "may
  this box sit on a lab network?" from *no* to *it depends*.

---

## 9. Out of scope

- Any claim of certification, accreditation or compliance for any rung.
- A rewrite in another language, or any change to the analytical methods.
- A home-grown identity provider, password store or cryptographic construction.
- Physical, personnel and network-accreditation controls, which belong to the
  host institution and cannot be evidenced from a repository.
- TOP SECRET guidance held at a higher classification. The Tier 3 material is
  available from the Government Security Group through an organisation's own
  security team, with the NCSC consulted where there is a business need; this
  project neither holds nor reproduces it.

---

## 10. Questions for the owner

1. **Which rung is the target for the next release** — R1 (safe on a managed
   workstation, deletions and releases recorded) or straight to R2 (sensitive
   personal data)? R1 is two workstreams and no route-level risk; R2 is the full
   identity and privacy programme.
2. **Should this be published as a "Proposal:" issue** in the project's own form
   before any code lands? The repository's convention is that an architectural
   decision is discussed in an issue first, and this one is architectural.
3. **Who owns the DPIA** — the deploying institution as controller, or this
   project as maintainer? Either way `SECURITY.md` should say which, because a
   partner will ask on page one.
4. **Which classification vocabulary should the attribute carry?** UK Government
   Security Classifications (OFFICIAL / OFFICIAL-SENSITIVE / SECRET / TOP
   SECRET) is the right shape for UK institutions and for the Tier 3 behaviours
   in the report, but most users are not UK government. A small institution
   profile in configuration may be better than a hard-coded scheme.
5. **Is the name "secure and private" right for outward-facing material**, or
   should the programme be described as "research integrity and assurance",
   which is the term a research office is more likely to fund?
6. **May the author's affiliations be stated** as in §5 in any published
   version, with the wording the author prefers?

---

## 11. Where to read the detail

| Document | What it contains |
| --- | --- |
| [recon report](../security/recon-report.md) | Seventeen findings with file-and-line evidence, the twelve existing controls, GDPR article-by-article, HIPAA specification-by-specification, and all 33 TOP SECRET behaviours classified as application-level, inherited from the environment, or with no software expression; plus a twenty-command evidence log and an explicit statement of what the review could not run |
| [ultraplan — secure and private](../security/ultraplan-secure-private.md) | The eight workstreams and eighteen pull requests, each with its files, ledger events, acceptance tests, standards clauses closed and friction cost; the four-rung ladder; and the list of controls deliberately *not* built |
| [colour-team assessment](../security/colour-teams.md) | White, red, blue, purple, green and gold teams over CyBOK knowledge areas; twelve red scenarios with preconditions; a detection matrix showing eight of ten red scenarios would be invisible today; and the conflicts between teams with how each resolves |
| [remedy ultraplan](security-and-integrity-ultraplan.md) | The remedy schedule: twenty remedies keyed to the findings, nine packages, three signable gates with what may and may not be said at each, a twelve-question partner answer pack, the KEC and commercial annex, and the decisions needed to start |
| [security dossier index](../security/README.md) | The reading order and the three sentences that matter |

---

## 12. How this will be judged

Three tests, all falsifiable:

1. **The questionnaire test.** A partner's standard security schedule should be
   answerable from repository artefacts, with a command and a result, without
   interviewing the operator.
2. **The DPO test.** A data protection officer should be able to read the DPIA
   input, the retention policy and a DSAR manifest, and identify in each one the
   evidence the regulation actually requires.
3. **The analyst test.** An analyst who works exactly as they do today should
   notice no difference in their day, except that a mistake is recoverable and a
   release is recorded.

If the third test fails, the programme has failed regardless of the first two.
That is why the friction budget is a hard constraint and not a preference.

---

*This proposal is an argument about governance, not a claim about compliance.
It is written to be challenged: if a finding here is wrong, the command that
proves it wrong belongs in the same pull request as the correction.*
