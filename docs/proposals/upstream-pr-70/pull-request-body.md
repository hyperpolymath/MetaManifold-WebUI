<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

<!-- Filled instance of .github/pull_request_template.md, for the pull request
     that carries this package into the fork. Ticked boxes are true as posted. -->

## Change and reason

Adds `docs/proposals/upstream-pr-70/`: four documents that package everything
upstream #70 needs before JoshuaJewell can accept or reject it — the filled
description, the reply to its Codex threads and failing check, the
signing/linearisation/CI-allowlist runbook, and a README tying them together.

Produced here first because the upstream repository is read-only from this
account (pull access only): nothing can be posted to #70 from this token, so the
text is written, reviewed and versioned in the fork and pasted by hand. This is
a documentation-only change — no code, workflow, or configuration file is
touched.

## Validation

- Content checked against the live state: upstream #70's branches and head,
  run `42436605157` (Julia tests pass 20m55s, Agda 37s, REUSE 10s,
  `codecov/patch` pass), the `codex-review-state:v1` quota message, and both
  Codex comments (empty thread list — no review findings exist to resolve).
- Every `uses:` SHA quoted in `runbook.md` §3 was read from the branch's own
  `ci.yml`; `dcarbone/install-jq-action` and `pyTooling/Actions/with-post-step`
  were confirmed as nested dependencies by fetching their `action.yml` files.
- SPDX `CC-BY-SA-4.0` licence and copyright headers on all five files, matching
  the existing `docs/proposals/` convention.
- No Julia, R or bun code paths are touched; no versions apply to a docs-only
  change. The `gate` job classifies this as not relevant, so the expensive jobs
  skip.

## Scope

Left out on purpose, and recorded as such in the documents themselves:

- **The allowlist change is not applied.** This token gets `403 Resource not
  accessible by integration` on `GET`/`PUT .../actions/permissions/selected-actions`;
  `runbook.md` §3 holds the read-before-write script and the UI path for an
  account with admin on the fork.
- **Nothing is posted upstream.** `description.md` and `response.md` are the
  paste-ready texts; posting them, and the re-signing/linearisation of
  `validation/issue-23-native-da`, are manual steps in `runbook.md` §1–2.
- No lockfile or manifest changes; no generated files.

## Contribution checks

- [x] I followed [CONTRIBUTING.md](../CONTRIBUTING.md).
- [x] This branch starts at current upstream main and contains no merges from fork main.
      The **Branch freshness** check reports this within a minute of a push; run it
      yourself with `bash scripts/maintenance/check-pr-freshness.sh --base origin/main`.
- [ ] CI has run and passes.
- [x] Existing licensing, citation and acknowledgement text is unchanged.
