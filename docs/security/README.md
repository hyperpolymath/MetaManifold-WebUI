<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Security dossier

A read-first set for anyone who has to decide whether this tool may hold data
belonging to other people, and what it would take for it to hold the most
sensitive material in the country.

| Document | Answers |
| --- | --- |
| [`recon-report.md`](recon-report.md) | What the system is, what protects it today, what does not, and how that scores against GDPR, the HIPAA Security Rule, and the UK TOP SECRET (Tier 3) baseline behaviours. Every finding cites a file and line, and every absence claim has the grep that proves it. |
| [`colour-teams.md`](colour-teams.md) | The CyBOK-referenced colour-team exercise: white (governance), red (adversary), blue (detection), purple (validation), green (build/crypto), gold (human/insider) — including where the teams disagree and how each conflict resolves. |
| [`../proposals/security-and-integrity-programme.md`](../proposals/security-and-integrity-programme.md) | The case for doing any of this at all, written for the people who carry institutional risk rather than the ones who run the pipeline: research office, DPO, research integrity, IT security, and an industry or KEC partner doing due diligence. |
| [`../proposals/security-and-integrity-ultraplan.md`](../proposals/security-and-integrity-ultraplan.md) | The remedy schedule for the same programme: twenty remedies keyed to the findings, nine independently fundable packages, three gates that state what may and may not be claimed at each, a partner answer pack, and the signature points an assessor will ask for. |
| [`ultraplan-secure-private.md`](ultraplan-secure-private.md) | The plan to close the gaps, ordered by rung on a capability ladder, under a hard **zero-friction** rule (eliminate, substitute, or notify — never "ask the user to be careful"). Each workstream names its files, its ledger events, its acceptance tests and its PR decomposition. |

## Read in this order

If you are deciding whether to fund or deploy any of this, start at
[the proposal](../proposals/security-and-integrity-programme.md), then
[the remedy ultraplan](../proposals/security-and-integrity-ultraplan.md) §3
(what may and may not be claimed) and §4 (the partner answer pack).

If you are implementing or reviewing it:

1. `recon-report.md` §1 (executive summary) and §5 (standards matrices).
2. `colour-teams.md` §7 (conflicts) and §8 (heat map) — this is the argument for
   the plan's ordering.
3. `ultraplan-secure-private.md` §1 (the four rules) and §5 (PR order).
4. `../proposals/security-and-integrity-ultraplan.md` §1 (the remedy register)
   and §2 (the packages), for who owns each harm.
5. `recon-report.md` §9 to re-run the evidence yourself.

## The three sentences that matter

1. The scientific code is well built; the **architecture** has no identity, no
   audit, no encryption and no classification, and every serious finding follows
   from one of those four.
2. **TOP SECRET is an accreditation of a system, not a property of an
   application.** The achievable statement today is a *rung* on a ladder, not a
   classification.
3. The first PR (`ultraplan-secure-private.md` W1) removes six live attack paths with security
   headers, size caps and refusals, adds no user friction, and does not touch a
   single line of analysis code.

## Provenance of this dossier

Written against `main` at `d6e8671`. The review was **static**: no Julia, R or
bun runtime was available, the clone is shallow, and no request was sent to a
running server. `recon-report.md` §0.3 lists what that means for each claim, and
§10 lists what is explicitly *not* claimed. Do not cite this dossier as a
penetration test, an accreditation, or a clean bill of health.

Corrections are welcome as ordinary pull requests: if a finding is wrong, the
grep that proves it wrong belongs in the same commit.
