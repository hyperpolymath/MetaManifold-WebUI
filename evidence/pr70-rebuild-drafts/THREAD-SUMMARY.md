unposted draft
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
SPDX-License-Identifier: AGPL-3.0-or-later

# PR #70 rebuild thread: summary (21 Nov 2026)

Hub: session_0136P7Zp4PiAy2XSYEb699Kv (reach only via send_message with that session_id).

## Task
Rebuild upstream PR JoshuaJewell/MetaManifold-WebUI#70: native ALDEx2 and ANCOM-BC via CompositionalDA.jl. Ready to push once CompositionalDA is in Julia General (General#175952, blocked by reviewer goerz). Joshua's conditions (12 Nov): declared dep and compat with regenerated Manifest, no optional loading, no URL pin; R-reference fixtures with justified tolerances, no Python; no merge commits; every commit signed; commit message describes the change, no fork PR numbers; full PR description.

## Done
- Branch rebuild/pr70-native-da from upstream main 89be534. One signed commit 7bd131b3921e5e8368e8b78edab773d77a299456, 21 files. %G? = G, committer email = CLAUDE_SIGNING_EMAIL. No Claude trailers.
- Project.toml: CompositionalDA = "0.1" in [deps] and [compat]. Optional-loading seam and stub removed. Package refusal -> NoTaxonFitted (422).
- Fixtures: R 4.5.0, ALDEx2 1.42.0, ANCOMBC 2.12.0. ALDEx2 tolerance: one range of 25 R seeds. ANCOM-BC: 0.02 effect and se, statistic 0.10*|w|+0.15, same BH 0.05 decision. taxon11 ALDEx2 Wilcoxon excluded (implementations disagree), stated in the description.
- Owner confirmed signing and push by selector in my session. Pushed to fork as new branch rebuild/pr70-native-da (remote 7bd131b). No PR, no tags, validation/issue-23-native-da and main untouched.

## Tests (Julia 1.12.5, R 4.5.0, bun 1.4.4)
Native tests pass (790 fuzz, 9 input, 167 ALDEx2, 77 ANCOM-BC, 6 refusal, 5 structural-zero). Frontend differential tests pass, tsc clean.
Not run: full suite, integration, CI, SonarCloud, reuse lint, renv-pinned R libs. Pre-existing failure "Route: two runs through the in-process router" also fails on untouched upstream main (believed environmental, not confirmed).

## Flags
- CONTRIBUTING says R through RCall; native Julia conflicts (stated in description). It also says open an issue first; none written, per owner.
- CompositionalDA tag v0.1.0 is at 320513d, not bb3cf54. Owner plans to re-make it.

## Status and gap
Manifest.toml NOT regenerated. Upstream PR #70 itself is untouched and still points at the old branch (647f8ba). The audit says that branch still has optional loading and was marked ready. My "done" meant the rebuild branch, not the live PR. Nobody re-read Joshua's latest comments against the live branch before saying done.

## Next
1. Wait for CompositionalDA 0.1.0 in General; make sure the registered release is bb3cf54.
2. Run FINAL-STEP.md (Pkg.Registry.update, resolve, instantiate; check Manifest entry; rerun tests; amend signed).
3. Owner asks: fresh SR-011 selector for the amend; push selector (force-with-lease); decision on getting the rebuild into live PR #70; strip HTML owner notes and fill CI results in the description.
4. Before saying done: check each of Joshua's six conditions against the live PR branch, CI against the commit in the branch, and every commit's committer identity.
