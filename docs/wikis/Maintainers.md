<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000020
parent: null
position: 20
kind: page
tags:
  - maintainers
  - overview
archived: false
-->

# Maintainers

This section has **two tracks**, because "maintaining the platform" means two
different jobs with two different risk registers:

- **[Operator track](Maintainers--Operator-Track)** — you run MetaManifold
  *for people*: installs, reference databases, toolchain updates, backups,
  capacity, the day something refuses at 09:00 before a batch is due. Lab
  IT, platform engineers, self-hosting PIs.
- **[Steward track](Maintainers--Steward-Track)** — you maintain the
  *repository*: CI gates, reviews and merges, releases, the relationship with
  the upstream origin design, and the estate's compliance machinery. Repo
  maintainers, OSS stewards, the hyperpolymath estate.

A small deployment (one lab machine, one maintainer) may wear both hats —
read both tracks; the risk registers are simply separate.

Shared across both:

- **[Releases and Distribution](Maintainers--Releases-and-Distribution)** —
  what a "release" is today (honest answer: tags + source) and the **COMING**
  standalone archives, WSL2 validation and coordinated updater.
- **[Compliance and Estate](Maintainers--Compliance-and-Estate)** — RSR and
  standards alignment, the licence split (AGPL upstream / MPL+CC-BY-SA
  fork), SPDX gates, and the autolink/settings elaboration.

## What is here now vs what is coming (maintainer view)

**IN PLACE:** pinned dual-lane toolchain (mise + Guix, sha256 pipeline
tools); CI (hygiene, pinned tools, commit gate, Dependabot auto-merge-on-green);
the `Justfile` command surface; the compliance record in `docs/compliance/`;
single-user local serving.

**COMING:** standalone offline release builders (policy exists in
`packaging/`, no builder), WSL2 validation, the coordinated signed updater,
multiuser/authenticated deployment, coverage gate (deliberately deferred to a
recorded baseline), OpenSSF enrolment (badges only after), the DOM test lane
decision.

**BLOCKED / held:** nothing on the maintainer side is blocked; the analysis
layer's independent review (#1) is the estate-level gate that keeps
statistical claims at PARTIAL. Board:
[Status and Roadmap](Status-and-Roadmap).
