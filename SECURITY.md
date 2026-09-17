<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| `main` branch (this fork) | ✅ |
| Fork release tags | ✅ latest only |
| Any older revision | ❌ |

The fork tracks upstream `main`; security fixes land on `main` first and
are not backported to older revisions.

## Reporting a vulnerability

**Preferred:** use GitHub Security Advisories on this repository:

1. Navigate to *Security → Advisories → Report a vulnerability* on
   [hyperpolymath/MetaManifold-WebUI](https://github.com/hyperpolymath/MetaManifold-WebUI/security/advisories/new).
2. Describe the issue privately with reproduction details.
3. You will be credited when the advisory is published, unless you prefer
   anonymity.

**If the issue is in upstream code** (anything also present in
`JoshuaJewell/MetaManifold-WebUI`), please report it there as well — the
fork will coordinate any fix with upstream rather than diverge silently.

**Alternative:** open a regular issue marked in the title as
`[SECURITY-SENSITIVE — move to advisory]`, with no exploit details; a
maintainer will migrate it to a private advisory.

> ⚠️ Do not report exploitable vulnerabilities in public issues, pull
> requests, or discussions.

## What to include

- Observed behaviour with the exact command/request and its output
- Affected component (route file, frontend module, CI workflow…)
- Affected commit(s) (`git rev-parse --short HEAD`)
- Impact assessment (what an attacker could achieve)
- Suggested remediation, if you have one

## Response targets

| Stage | Target |
|---|---|
| Acknowledgement | 7 days |
| Triage and severity assessment | 14 days |
| Fix or documented mitigation | Best effort on `main` |

This is a research-software project without a security team; targets are
honest effort estimates, not SLAs.

## Scope

**In scope:** this repository's Julia server, React frontend, pipeline
orchestration scripts, CI workflows, and container/deployment files.

**Out of scope:** third-party tools we orchestrate (cutadapt, DADA2,
SWARM, vsearch, cd-hit-est, R/vegan — report to those projects), attacks
requiring local shell access, and denial-of-service against deployments
you do not own.

## Safe harbour

Good-faith security research against your own deployment of this software
is expressly authorised. Do not test against deployments you do not
administer.

## Operational guidance

This application reads bioinformatics data and writes to databases on the
host machine. Recommended deployment hygiene:

- Run behind authentication if exposed beyond localhost
- Keep system dependencies (bun, Julia, R) at the versions pinned in
  `docs/reproducibility.md`
- Never commit sequencing data, secrets, or environment files

<sub>Last updated: 2026-09-17 · v1.0</sub>
