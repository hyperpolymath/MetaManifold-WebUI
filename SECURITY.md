<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Security policy

## Reporting a vulnerability

For vulnerabilities in this fork, use [GitHub private vulnerability
reporting](https://github.com/hyperpolymath/MetaManifold-WebUI/security/advisories/new).
If private reporting is unavailable, contact the fork maintainer at
**j.d.a.jewell@open.ac.uk**. Do not open a public issue containing exploit
instructions, credentials, private sequence data, or patient identifiers.

Include the affected commit, deployment configuration, reproduction steps,
expected and observed behaviour, and likely impact. Use synthetic or
appropriately de-identified examples. Never send production credentials.

For defects shared with the upstream project, coordinate disclosure with
[JoshuaJewell/MetaManifold-WebUI](https://github.com/JoshuaJewell/MetaManifold-WebUI)
as well; this fork cannot make support commitments on its behalf.

## Supported versions and deployment boundary

Security fixes target the current `main` branch of this fork. Older commits
and downstream deployments must be updated; no backport or response-time
commitment is implied.

Treat the Julia server as a trusted local analysis service, not a public,
multi-tenant hosting boundary. Do not expose it directly to the internet.
Remote deployments need an authenticated, TLS-terminating reverse proxy and
appropriate access controls for the server's files, tools and analysis data.
Keep DOI publication disabled unless deliberately configured; Zenodo tokens
belong in server-side environment variables, never frontend code or Git.

## Automated checks and their limits

CI runs application tests and proof checks. The fork governance workflow
reports DEED syntax, K9 conformance coverage, and advisory Hypatia findings.
The Secret Scanner workflow checks the working tree and Git history; the
Scorecard workflow assesses repository security practices. Dependency update
PRs still require review and passing tests.

A green workflow is not a claim that all security findings are resolved.
Missing tools, inaccessible GitHub alert APIs, absent fleet report-backs and
unverified K9 L3 signatures must remain visible as missing or inapplicable
evidence.

## Security dossier

`docs/security/` holds a full static review of the request surface, the data
handling, and the deployment assumptions: findings with file-and-line
evidence, a mapping against GDPR, the HIPAA Security Rule and the UK
Government Security Classifications TOP SECRET (Tier 3) baseline behaviours, a
CyBOK-referenced colour-team exercise, and a phased plan
(`docs/security/ultraplan-secure-private.md`) with a zero-friction rule: each exposure is
eliminated, substituted or notified, never pushed back onto the user as an extra
step.

Start at [`docs/security/README.md`](docs/security/README.md). The dossier is a
gap analysis and a plan. It is explicitly not an accreditation, and it does not
claim that any control it describes has been implemented.
