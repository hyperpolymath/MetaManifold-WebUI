<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
## Summary

<!-- What this PR does and why. Link issues with "Closes #N". -->

## Base check

- [ ] Base is `hyperpolymath/MetaManifold-WebUI:main` (not the upstream
      parent; application changes go to `JoshuaJewell/MetaManifold-WebUI`)

## Changes

<!-- List the key changes. -->

-

## Engineering checklist

### Required

- [ ] `bun run check` passes (`frontend/`: typecheck 0 errors, tests,
      benchmarks)
- [ ] `scripts/check-spdx.sh` / `check-format.sh` / `check-lint.sh` pass
      (advisory in CI — does not block merge)
- [ ] Conventional commit subjects (see `CONTRIBUTING.md`; advisory in CI)
- [ ] New source files carry the correct SPDX header (`NOTICE` explains
      the authorship rule)
- [ ] No secrets, credentials, `.env`, or sequencing data included
- [ ] No application-logic changes hidden inside alignment/tooling PRs

### As applicable

- [ ] `CHANGELOG.md` updated for user/developer-visible changes
- [ ] `docs/types/architecture.md` updated if type boundaries moved
- [ ] `docs/testing/coverage.md` updated if test coverage moved
- [ ] New dependencies reviewed for licence compatibility
- [ ] `docs/reproducibility.md` updated if environment requirements changed

## Testing

<!-- How you verified these changes. Include `bun run check` output tail for
     engineering PRs. -->
