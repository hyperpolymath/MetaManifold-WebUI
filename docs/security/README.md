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
| [`ultraplan.md`](ultraplan.md) | The plan to close the gaps, ordered by rung on a capability ladder, under a hard **zero-friction** rule (eliminate, substitute, or notify — never "ask the user to be careful"). Each workstream names its files, its ledger events, its acceptance tests and its PR decomposition. |

## Read in this order

1. `recon-report.md` §1 (executive summary) and §5 (standards matrices).
2. `colour-teams.md` §7 (conflicts) and §8 (heat map) — this is the argument for
   the plan's ordering.
3. `ultraplan.md` §1 (the four rules) and §5 (PR order).
4. `recon-report.md` §9 to re-run the evidence yourself.

## The three sentences that matter

1. The scientific code is well built; the **architecture** has no identity, no
   audit, no encryption and no classification, and every serious finding follows
   from one of those four.
2. **TOP SECRET is an accreditation of a system, not a property of an
   application.** The achievable statement today is a *rung* on a ladder, not a
   classification.
3. The first PR (`ultraplan.md` W1) removes six live attack paths with security
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
