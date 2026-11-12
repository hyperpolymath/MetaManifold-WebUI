<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Upstream package: issue #22, MN/DM regression through MGLM

Status: **built, tested and pushed to this fork; not yet sent upstream.**

On [JoshuaJewell/MetaManifold-WebUI#22](https://github.com/JoshuaJewell/MetaManifold-WebUI/issues/22)
the upstream owner ruled that multinomial and Dirichlet-multinomial regression
come in as "MGLM through RCall, in line with CONTRIBUTING". He later closed the
issue as not planned. This directory holds what the upstream pull request
needs. Upstream is read-only from the session that built it, so a person posts
each item by hand.

## The two parts

1. **The upstream branch.** `upstream/issue-22-mglm` in this fork: one
   commit, `37c9ffa`, on upstream `main` at `89be534` (`behind_by` 0 when
   pushed). GitHub shows it Verified, signed by the HoTT-stuff account. It
   adds the two methods through `MGLM::MGLMreg.fit`, MGLM 0.2.3 in
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
| `comment-to-joshua.md` | A comment on upstream #22, posted first |
| `pull-request-body.md` | The body of the upstream pull request, only if he wants it |
| `0001-mglm-compositional-regression.patch` | The upstream commit as a patch. `git am` it onto upstream `89be534`; the result has the same tree as `37c9ffa`, and needs signing again |

## Sending it (owner's order, 2026-11-12: comment first)

1. Fill the bracketed line in `comment-to-joshua.md` with the person who
   answers for the code. Then post the comment on #22 from the account that
   will submit.
2. Wait for his answer. If he says no, stop.
3. If he says yes, check that `upstream/issue-22-mglm` is still 0 commits
   behind his `main` (CONTRIBUTING item 1). If `main` moved, rebase it and
   sign again.
4. Open the pull request from `hyperpolymath:upstream/issue-22-mglm` to
   `JoshuaJewell:main` with `pull-request-body.md` as its body. Fill its
   bracketed line too.
5. When its CI is green, tick the last two boxes in the body.

## What the two backends share, and what they do not

- **Multinomial.** It is the same model in both backends. The fork's tests
  check that MGLM reproduces the Julia fit (estimates to 1e-6, standard errors
  to a relative 1e-6) and the closed form (to 1e-8).
- **Dirichlet-multinomial.** These are different models. The Julia model has
  one concentration shared by both groups. MGLM puts a log link on every
  taxon's Dirichlet parameter, so each group has its own concentration. The
  two are therefore not compared, and the docs say which one runs.
