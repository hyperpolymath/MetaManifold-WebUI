<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Upstream PR package: native differential estimators

Status: **written here first, not yet sent.** These are the documents the
upstream pull request
[JoshuaJewell/MetaManifold-WebUI#70](https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/70)
needs, produced and reviewed in this repository before anything is posted. The
upstream repository is read-only from here: the token used has `pull` only, so
its description and comment threads can only be edited by hand or by someone
with write access.

## The four documents

| File | What it is | Where it goes |
|---|---|---|
| `description.md` | The filled pull-request template: change, validation, scope, contribution checks | The body of upstream #70 |
| `response.md` | The answer to the two `chatgpt-codex-connector` comments and the failing `Julia tests` check | A comment on upstream #70 |
| `runbook.md` | The steps still required before #70 meets `CONTRIBUTING.md`: re-signing, linearising, and the fork's CI allowlist | This fork; run by hand |

## State of play

The branch `validation/issue-23-native-da` carries eleven commits adding native
`aldex2` and `ancombc` differential-abundance estimators behind an optional
`CompositionalDA` dependency, with route, config, frontend, test and docs work.

- **`Julia tests` failed** at `Instantiate Julia project`: `Project.toml`
  declared `CompositionalDA`, which is not in the General registry and had no
  `Manifest.toml` entry, so `Pkg.instantiate()` could not resolve the project on
  any checkout. Fixed by three commits that drop the declaration, keep the
  feature behind the existing guarded import, and make the tests branch on
  availability instead of importing the package at the top of the file.
- **CI is green** on the branch with that fix:
  [`run 42436605157`](https://github.com/JoshuaJewell/MetaManifold-WebUI/actions/runs/42436605157)
  — Julia tests 20m55s, Agda proofs 37s, REUSE compliance 10s, `codecov/patch`
  pass.
- **The Codex "❌ Failed" badge is a quota message**, not a review: *"You have
  reached your Codex usage limits for code reviews."* The pull request has no
  review threads and no inline review comments at all.

## Before sending: two blockers

`CONTRIBUTING.md` is checked before the code is read, and #70 does not yet meet
two of its rules. Both are fixed by hand, in this order, following
`runbook.md`:

1. **Every commit is unsigned** (14 of 14; GitHub shows `N`).
2. **The branch contains a merge commit** (`be7792f`) from landing the CI fix
   as a GitHub *merge* rather than a fast-forward. Rule 2 forbids merge commits
   outright.

`description.md` is written for the state *after* those two steps; it ticks the
signed-commit and CI boxes on that assumption.

## Sending it

1. Run `runbook.md` — re-sign, linearise, force-push, confirm `behind_by: 0`.
2. Wait for CI on the rewritten branch to go green again (same content, new
   SHAs).
3. Paste `description.md` into the pull request body, replacing the untouched
   repository template.
4. Post `response.md` as a comment. Re-trigger Codex with `@codex review` only
   once the review quota resets; until then it repeats the same message.

The answer to the maintainer's proposal — what was accepted, what was changed
and what is still open — is `response.md`; `description.md` is the proposal
itself, restated in the shape their template asks for.
