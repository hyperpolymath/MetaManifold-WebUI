<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Upstream package: issue #22, MN/DM regression through MGLM

Status: **built and tested; not yet sent upstream.**

On [JoshuaJewell/MetaManifold-WebUI#22](https://github.com/JoshuaJewell/MetaManifold-WebUI/issues/22)
the upstream owner ruled that multinomial and Dirichlet-multinomial regression
come in as "MGLM through RCall, in line with CONTRIBUTING". He later closed the
issue as not planned. This directory holds what the upstream pull request
needs. Upstream is read-only from the session that built it, so a person posts
each item by hand.

## The two parts

1. **The upstream branch.** One signed commit, `1fa1d55`, on upstream `main`
   at `89be534`: the two methods through `MGLM::MGLMreg.fit`, MGLM 0.2.3 in
   `renv.lock`, and tests against a closed form and an independent optimiser.
   It contains none of this fork's own code.
2. **This fork.** The same MGLM code is in `src/analysis/differential.jl` here,
   behind `analysis.differential.mn_backend: mglm`. The default stays `julia`,
   this fork's own `CompositionalModels`. Merging the upstream branch itself
   would also bring in upstream's other commits that this fork does not have,
   which is the separate sync in `notes/upstream-sync.md`.

## The documents

| File | Where it goes |
|---|---|
| `pull-request-body.md` | The body of the upstream pull request |
| `comment-to-joshua.md` | A comment on upstream #22, after the pull request's CI is green |

## Sending it

1. Push the upstream branch to this fork under its own name.
2. Check that GitHub shows the commit as Verified, and that `behind_by` is 0
   (CONTRIBUTING, items 1 and 3).
3. Open the pull request against `JoshuaJewell/MetaManifold-WebUI:main` with
   `pull-request-body.md` as its body.
4. When its CI is green, tick the last two boxes, then post
   `comment-to-joshua.md` on #22 with the pull request number filled in.

## What the two backends share, and what they do not

- **Multinomial.** It is the same model in both backends. The fork's tests
  check that MGLM reproduces the Julia fit (estimates to 1e-6, standard errors
  to a relative 1e-6) and the closed form (to 1e-8).
- **Dirichlet-multinomial.** These are different models. The Julia model has
  one concentration shared by both groups. MGLM puts a log link on every
  taxon's Dirichlet parameter, so each group has its own concentration. The
  two are therefore not compared, and the docs say which one runs.
