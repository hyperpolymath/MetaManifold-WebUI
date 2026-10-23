<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Governance and security follow-up to PR #227

## Regression review

PR #227 is superseded by merged #234, not a candidate for a conflict merge.
Its four Codex findings were addressed in #229/#234: byte-buffer Newick
slicing, graft `edge_number` access, invalid Faith PD counts and the raw-count
UniFrac overload. #238 corrects PD rooting; #239/#240 preserve placement mass
and fix the independent library-size-normalised weighted UniFrac expectation.
The four old review threads have been answered and resolved, and #227 closed.
No other contributor's branch was rewritten.

## Changes

- Full-history and working-tree secret scanning via a fork-local copy of the standards reusable at
  `c6d78606f3928c22c3b0bdc6f5f5b47b96e05a5d`, with only `contents: read` and
  no inherited secrets. Findings fail the job; no local suppressions added.
- Pinned Scorecard publication on main and weekly/manual runs, not PR code.
- Dependabot for Actions and the bun-managed frontend; a private disclosure
  policy and deployment boundary in `SECURITY.md`.
- A 90-minute limit on the expensive Julia/R test job. Both Julia pipelines
  now preserve failures from the producer **and** the log writer; diagnostic
  collection cannot turn a failed test into success.
- A separate pinned K9 conformance family and artifact in the PR verdict.
  There are currently **zero K9 contracts**: its corpus is grey/inapplicable,
  not a semantic pass inferred from the DEED syntax row. Indeterminate K9
  validation fails closed; L3 signature verification is not claimed.
- Editor settings and a repository-specific AI manifest that defers to
  `CONTRIBUTING.md`, rather than importing incompatible estate toolchains.
- Frontend lockfile refreshed with bun 1.3.10 within existing major-version
  ranges, with minimum Vite 6.4.5 and React Router DOM 6.30.6. This lockfile
  change is intentional: it removes known vulnerable transitive versions,
  including DOMPurify 3.4.16, PostCSS, nanoid, picomatch and Browserslist.
  CI audits high/critical dependencies; no advisories are suppressed.

## Local verification

With bun **1.3.10**:

- `bun install --frozen-lockfile --ignore-scripts`: pass.
- `bun run typecheck`, `bun test src`: pass, **72 tests**, 200 assertions.
- `bun run build`: pass (existing large Plotly bundle warning remains).
- `bun audit --audit-level high`: pass. Full JSON audit fell from 31 advisories
  (1 critical, 13 high, 14 moderate, 3 low) to **2 moderate** React Router
  advisories. This is not a zero-vulnerability claim.
- `bash scripts/check-governance-contract.sh`: 39 assertions.
- `bash scripts/tests/test-governance-contract.sh`: 8 weakening mutations
  rejected (SARIF, K9, scanner privileges/failure policy, Scorecard PR trigger).
- `bash scripts/tests/test-ci-logging.sh`: success and each combination of
  producer/logger failures return the correct status for both CI pipelines.
- Canonical DEED linter from the existing pinned standards commit: pass.
- YAML parses with unique keys; Sonar reliability lint and proof axiom audit
  pass (7 modules, no new axioms). Axiom audit is not Agda typechecking.

Julia, R, Agda and Nickel are not installed in the authoring sandbox; their
runtime/semantic checks are delegated to hosted CI, not reported as local
passes. GitHub log/artifact downloads are restricted by the sandbox's host
allowlist; job/check APIs and the published Hypatia grid remain readable.

## Hosted K9 correction

The first hosted run exposed a bug in the pinned standards wrapper: its
terminal `[ -f corpus.log ] && cp ...` returned 1 for the legitimate empty
corpus, after rendering and archiving the grid. The fork-local reusable now
uses an explicit conditional. It still checks out the validator, contract
and renderer at the same immutable standards SHA; no semantic checks or
ratchet rules were weakened. Three regression cases exercise absent log,
present log and a genuine copy failure. The local reusable only has a
`workflow_call` trigger to prevent duplicate standalone conformance runs.

## Hosted history-scan correction

The first hosted full-history scan failed under the standards wrapper's old
Gitleaks **8.18.4**. Reproducing its legacy rule set with the 8.30.1 engine
produced 211,428 findings: 211,408 AWS-pattern matches in historical sequence
and FASTQ data, 19 generic-key matches in minified bundles/annotation field
names, and one Facebook-pattern match in FASTQ data. For example, the old
AWS rule accepts low-entropy `ACCA`-prefixed DNA and a broader character
alphabet without the current detector's entropy threshold; the
annotation matches are schema labels (`associated_organism`, etc.). This is
not a reason to exempt the data directory or Git history from scanning.

The fork-local scanner reusable now uses **Gitleaks 8.30.1**, verified against
upstream's release-asset SHA256
`551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`.
The estate baseline still comes from the same pinned standards source.
No repository allowlist or historical fingerprint suppression was added;
working-tree, full-history, shell, Rust and AsciiDoc checks remain gating.
The current engine reports no leaks locally, and a synthetic AWS credential
must still trigger its AWS rule. That sensitivity check is also run in CI.
The local binary came from the npm platform package at 8.30.1-post.3; hosted
CI installs the checksum-verified upstream archive, so hosted verification
remains necessary. No actual credential values were published.

## Scanner review findings

Codex review on #243 identified four inherited scanner defects. Rust and
shell findings now report locations without source values; the regression
tests assert the synthetic credential is absent from logs. The AsciiDoc
mirror preserves the scanner exit status, validates the report, and fails
on runtime errors or missing/invalid evidence rather than reporting clean.
The custom shell rules now scan every unique historical shell blob as well
as the working tree, so a deleted credential remains detectable independently
of Gitleaks' built-in rules. Both current and historical findings are blocking.

`bash scripts/tests/test-scanner-boundaries.sh` exercises clean input, a
working-tree shell credential, a committed-then-deleted shell credential,
Rust findings in both scopes, and six AsciiDoc result/error modes. Fixture
repositories are temporary and do not change application Git history.
The custom shell scan also passes on this repository's actual history.

## Remaining findings / decisions

The source report is Hypatia grid run **39982506244**, commit `d69d4f9`.
It is historical evidence, not a freshly executed scan of this change.

- **React Router:** GHSA-wrjc-x8rr-h8h6 and GHSA-337j-9hxr-rhxg still affect
  the v6 dependency according to the registry. The published fixed range is
  v7.18+. Plan a major-version routing/hydration review rather than silently
  migrating or suppressing them. The current UI uses a client-side router;
  that does not justify declaring all advisory paths unreachable.
- **Estate applicability:** the fixed React/TypeScript architecture and the
  independent Python scientific reference oracles conflict with estate
  language-ban heuristics. Do not rewrite them to make a badge green.
- **Scanner discovery:** Hypatia is called by `governance.yml`, not the
  heuristic's expected `hypatia-scan.yml`. CodeQL is already supplied by the
  GitHub App (Actions, JS/TS and Python checks on #227); do not run a second
  scan just to satisfy filename detection. No mirror target is configured;
  adding a no-op `mirror.yml` would manufacture coverage.
- **HTTP identifiers:** W3C SVG/XLink namespace URIs in `figure/export.ts`
  and `TreeView.tsx` are identifiers, not insecure network requests. Replacing
  their `http` scheme breaks namespace identity.
- **CI diagnostics:** the pre-existing `|| true` statements collect failure
  digests *after* capturing the test exit. The final `exit "$status"` still
  fails the job; the logging regression tests guard this boundary.
- **Licensing:** four upstream source files lack SPDX identifiers. Existing
  headers are protected by `CONTRIBUTING.md`; no licence text was changed.
- **Further review:** outbound-egress monitoring on secret-bearing jobs,
  panic-attack's dynamic R evaluation/FFI/input-boundary heuristics and pons's
  loop/unreachable heuristics still need scoped review, not blanket dismissal.
- **Fleet:** seven enrolled bots had no report-back. They remain `not_run`;
  no synthetic reports or success records have been created.
- **Alert permissions:** the connected GitHub integration returns HTTP 403 for
  Dependabot and code-scanning alert listing. No security alerts were dismissed
  or marked fixed through that API. Maintainer-side access is needed to verify
  reconciliation after the next default-branch scan.
- **CodeRabbit:** review capacity and Autofix billing notices require an account
  decision; this change neither purchases credits nor activates billing.


## PR #228 supersession and R source boundaries

The linked CodeRabbit Autofix response is a billing notice, not a code finding;
no credits or paid usage have been enabled. The recorded conflict-resolution
commit `77376ef18b06e01dd2537060064e78e090ceb68e` in #244 has the same tree as
main `d69d4f9910a143911499c596e0648932c834c42e`
(`8f91c388d973c6c4548c1d70d0d7af2e37c622c8`), independently verified with
`git diff --exit-code`. Re-merging #228 would not add its intended fixes. Keep
main's streamed bounded integer-count loading, strict I-JSON validation and
unplaced-read mass semantics rather than restoring the stale versions.

The remaining leaf-PD inconsistency is real, but its implementations and
regressions are already in the **unmerged** #242 and #244. They are not in main
and are not duplicated here. Main's CI run `39982506136` passed. Replacement
#242's integration run `39986326202` subsequently passed all six jobs, including
Julia, Agda and both occupancy checks; its other reported checks were also green
at head `ed24c9c1708734fbc483f78f2bcca22ddb8a3074`. #244's Julia job was still
running at review time. Neither replacement has been merged.

CodeRabbit correctly warned that using R rather than Julia does not by itself
make `RCall.reval` safe. Reviewing those call sites found two source boundaries
that now receive explicit validation:

- PERMANOVA concatenates metadata column names into a formula. Binding the
  resulting string through RCall does not stop `as.formula`/model-frame
  evaluation from interpreting expressions. Formula terms are now restricted
  to plain ASCII R identifiers; expressions, reserved words, special dot terms
  and control characters throw `ArgumentError` before formula construction.
  Non-identifier metadata columns must be renamed before this analysis.
- Provenance package-version queries interpolate a package name into an R
  string literal. Only the R package-name alphabet is accepted before building
  that query; quotes, escapes, path separators and controls are rejected.

Pure-helper regressions do not require an R/vegan runtime, and a reference-suite
case checks the PERMANOVA entry point when R/vegan is available. The new Julia
regressions require hosted CI: Julia and R are not installed in the local
sandbox. These targeted fixes are not a blanket dismissal of the remaining
advisory findings or a complete R-call-site security audit.
