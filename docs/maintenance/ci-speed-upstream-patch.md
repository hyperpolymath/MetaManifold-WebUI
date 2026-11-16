# CI speed work: what it changed and how to take it upstream

This records the CI speed, fail-early and diagnostics work merged on the fork in
PR #328, with the follow-up in this change. It is a note for whoever carries the
work to `JoshuaJewell/MetaManifold-WebUI`; nothing here has been pushed or posted there.

## What changed

- Precompiled Julia caches keyed on the Julia pin, the R apt pin and `Manifest.toml`.
- Fail-early gates, per-step timing and a classifier for failure causes.
- An Agda pass memo: a pull request reuses an earlier pass when the proofs, the
  checker pins and the invocation are unchanged.
- All eleven Python files replaced by GNU `bc`, `awk` and Julia. No Python tests
  or scripts remain.
- The renv cache save is skipped when a SHA-512 of the cache contents is the same
  before and after the R install.
- `persist-credentials: false` on the four `ci.yml` checkouts that were missing it.
- A weekly, non-required Julia dependency canary (`julia-canary.yml`).

## Measured, cold cache (job timings)

| Step | Before | After |
| --- | --- | --- |
| Julia tests job | 27m58s | 23m38s |
| Instantiate | 3m55s | 31s |
| Validated-statistics step | 2m37s | 49s |
| Full-suite "Run tests" step | 17m52s | 13m28s |
| Statistics standards job | 17m49s | 8m39s |
| Mutation campaign | 11m25s | 5m13s |

"Rebuild RCall" is still about 5m04s because `Pkg.build` precompiles.

Warm-cache timings: not measured yet. They are added below once a second run on
the same cache key has finished.

## Taking it upstream

A patch against upstream `89be534` applied cleanly in a scratch clone. Generate it
from the merge commit `c20ae05` and this change, apply it on a branch of the
upstream repository, and let upstream CI run. No ruleset, required check or job
name changes, and no matrix is added.
