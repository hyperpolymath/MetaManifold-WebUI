<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Proof status

The per-theorem ledger for `proofs/agda/`, kept as the estate PROOF-POLICY
requires
([metadatastician/standards `3-practice/PROOF-POLICY.adoc`](https://github.com/metadatastician/standards/blob/main/3-practice/PROOF-POLICY.adoc),
read at `9bdf864`). What each theorem says, and what it does not cover, is in
[`agda/README.md`](agda/README.md). This file records only the three things a
record carries under that policy, and never one in another's field:

- **status**: how one leg was discharged (§5): `PROVEN`, `PROVEN-WITH-AXIOMS`,
  `TESTED`, `ASSUMED`, `OPEN`;
- **correspondence**: how far statements in different provers are tied
  together (§2.2);
- **PWG**: the Proof Witness Grade (§8), derived from the receipts below and
  never asserted.

## Classification (§1)

A statement that would be true of any implementation is **theory**. Its source
of truth is Agda, it owes a Rocq leg and a Lean leg (§2), and it is graded on
the PWG ladder. A statement about one function, fixture or interface of this
repository is **engineering**. It carries status tokens only and is not graded
(§8.1).

## Receipt

| Field | Value |
|---|---|
| Checker | Agda 2.6.4.3 |
| Standard library | agda-stdlib v2.1, commit `97bc55e47367c562b3032bf104f2a00b19716f88` |
| Invocation | `agda --safe --without-K --cubical-compatible MetaManifold/All.agda` (§2.1), `LC_ALL=C.UTF-8` |
| Flags in force | `--safe --without-K --cubical-compatible`, in every module's `OPTIONS` pragma and in `metamanifold.agda-lib` |
| Import cone | the 7 modules reachable from `MetaManifold.All` (Prelude, BenjaminiHochberg, Scaling, Permanova, Significance, CladeCumulus, All), agda-stdlib 2.1, Agda builtins |
| Input digest | `75b605292a94d426281a0b1487852b42a170be0281e9c93bca66c8aff6ad1a42`: SHA-256 over `sha256sum` of every `.agda` and `.agda-lib` file under `proofs/agda`, sorted by path in the C locale |
| Result | accepted: exit 0, 7 modules checked, 0 errors, 158 `UnsupportedIndexedMatch` warnings (see [`agda/README.md`](agda/README.md)) |
| Axioms | none. `--safe` refuses postulates, and `proofs/tests/axiom-audit.sh` is clean (no postulate, hole, trusted primitive, check-disabling pragma, full `--cubical` or unreached module) |
| Run | 2026-11-09T13:28:46Z, Claude Code cloud session, on this branch's tree |
| CI | the "Agda proofs" job runs the same invocation on every pull request touching `proofs/`, from Debian trixie `agda-bin=2.6.4.3-1+b2`, `agda-stdlib=2.1-4` in a digest-pinned container |

The input digest identifies the receipt. Recompute it with:

```sh
(find proofs/agda -name '*.agda' -o -name '*.agda-lib') | LC_ALL=C sort | xargs sha256sum | sha256sum
```

A receipt whose digest no longer matches is superseded. Any grade below
falls back until a new receipt is recorded (§8.4).

### Toolchain deviation (§6)

| Field | Value |
|---|---|
| Leg | the Agda receipt above (session run) |
| Tool | Agda 2.6.4.3, built from Hackage source with GHC 9.4.7 and cabal-install 3.8.1 (Ubuntu 24.04); binary SHA-256 `34cfe62c367122433d14abe09cccd5d52ac38b9e2044ccfc611f2ddca966b4c0` |
| Why not the CI container's packages | the session's network could not reach `deb.debian.org`. Cabal 3.8.1 could not verify Hackage's current TUF root signatures, so the index was fetched over HTTPS with TUF verification off |
| State | `open` until the CI job, which uses the pinned Debian packages, passes on this tree. The CI result then replaces this session receipt |

## Theory: PWG ladder

Every row is `PROVEN` in Agda under the receipt above. The Rocq and Lean legs
are not started, so the correspondence state of each is `AGDA-VERIFIED`, and
the derived grade is `PWG-3`. That is a description of the artefact, not a
discharge: each row still owes both recheck legs (§8.4).

| Theorem | Module | Agda | Rocq leg | Lean leg | PWG |
|---|---|---|---|---|---|
| `bh-nonneg` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `bh-dominates-p` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `bh-at-most-one` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `bh-monotone` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `bh-envelope` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `stepUp-envelope` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `bh-length` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `monotone-in-family-size` | BenjaminiHochberg | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `rankFactor-≥1` | Prelude | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `total-positive` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `proportions-sum-to-1` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `proportions-bounded` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `centre-positive` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `centre-monotone` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `ratio-positive` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `median-positive` | Scaling | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `minP-attained` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `p-floor` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `p-at-most-one` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `below-floor-unreachable` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `minP-anti` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `minP-63` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `no-p-at-1%-with-63` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `Labels.never-exchanged` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `Labels.exchanged` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `Labels.untestable⇔fixed` | Permanova | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `every⇒some` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `every⇒not-absent` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `cumulative-conserves-tips` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `child≤parent` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `faithPD-mono` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `faithPD-bounded` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `sharedPD≤unionPD` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |
| `unifracNumerator≤Denominator` | CladeCumulus | `PROVEN` | `OPEN` | `OPEN` | `PWG-3` |

PWG count: 34 of 34 theory theorems at `PWG-3`. None at `PWG-2i`, `PWG-2ii`
or `PWG-1`, and none `ungraded`.

The BH theorems are about the procedure: the model `bhAdjust` follows the
shape of `bh_adjust`, but each statement holds for the BH step-up procedure as
such. Their hypothesis `All Valid ps` (finite, in `[0, 1]`) is an assumption,
not a theorem. It is met in `differential_abundance` because both `nb_glm`
paths reject a non-finite p-value or one outside `[0, 1]` before reporting.
That link is argued from the code (`ASSUMED`), not proved. In this tree both
`dispersion` settings share that check (`src/analysis/differential.jl`, after
`summary(da_fit, dispersion = 1)`).

## Engineering: status tokens only

| Theorem | Module | What it is about | Status |
|---|---|---|---|
| `Varies.varies-false⇔Constant` | Permanova | the model of `_varies_within_any_block` | `PROVEN` |
| `Varies.withheld⇔never-exchanged` | Permanova | that model and the withholding rule | `PROVEN` |
| `Varies.tested⇔exchanged` | Permanova | that model and the withholding rule | `PROVEN` |
| `Fixtures.constant-in-blocks`, `Fixtures.varies-in-a-block` | Permanova | two cases from `test/unit/test_permanova.jl`, by evaluation | `PROVEN` |
| `Fixtures.fixture-group-withheld`, `Fixtures.fixture-run-tested` | Permanova | the twelve-sample test fixture | `PROVEN` |
| `validateMove-sound` | CladeCumulus | this repository's clade-move validator | `PROVEN` |
| `unrun-status-not-computed`, `computed-status` | Significance | a proposed publication interface (experimental, no refinement to Julia) | `PROVEN` |

That the Agda models follow the Julia functions is argued in
[`agda/README.md`](agda/README.md), not formalised: `ASSUMED`.

Open obligation (§3): `Significance` states an *interface* property in Agda.
Under §1 an interface contract belongs in Idris2, and §3 moves it there when
the module is next touched unless a §4 exception is recorded. `OPEN`.

## Claims from the glmGamPoi work (`analysis.differential.dispersion`)

These are claims about code and statistics, not theorems. They are recorded so
nothing reads as proved that is not.

They describe the implementation merged **upstream** in
JoshuaJewell/MetaManifold-WebUI#62 (`08eaa8c`): `dispersion: glm_nb |
glmGamPoi`, where glmGamPoi reports `test_de`'s quasi-likelihood F-test. This
fork's `main` still carries the earlier design from #181: `dispersion: ml |
glmGamPoi`, where glmGamPoi fixes `theta = 1 / dispersion_trend` in a per-taxon
`MASS::negative.binomial` Wald test. That design calls no `test_de` and parses
no contrast text, so the first two rows below do not arise for it. Bringing
the fork's implementation into line with upstream's is an open item, not done
here.

| Claim | Evidence | Status |
|---|---|---|
| Passing the `test_de` contrast as numeric weights gives the same rows as the coefficient name, for every label | `test/unit/test_differential.jl` "Condition labels never change the fits or reach R as code": labels with `-`, `/` and R code, under both dispersions, against the `A`/`B` rows (`rtol = 1e-10`). Upstream CI on R 4.5 and glmGamPoi 1.22.0 | `TESTED`: the four label sets in the test, the `effect` fixture |
| Label text never reaches R as code | the same test's `exists(...)` check. glmGamPoi 1.22.0 `parse_contrast` evaluates text contrasts and returns numeric ones unchanged (source read) | `TESTED` |
| `theta` is `1 / overdispersions`, the per-taxon estimate before shrinkage. The fit and the F-test use the trend and the shrunken QL dispersion | glmGamPoi 1.22.0 `glm_gp_impl` and `test_de` (source read). An experiment that perturbs `overdispersions` and observes `pval`, `f_statistic` and `lfc` unchanged and `lfc_se` changed | `TESTED`: one fixture |
| Under the null, glmGamPoi's QL F-test holds about nominal size, and `glm_nb`'s Wald test exceeds it at small n | simulation, 4 and 12 per group (hyperpolymath/MetaManifold-WebUI#193), replicated at 1,000 simulations by the `bench/null_calibration` bench (#262) | `TESTED`: the simulated designs only. A statistical observation, not a theorem |

## Upstream

Upstream JoshuaJewell/MetaManifold-WebUI carries five of these modules
(`Prelude`, `BenjaminiHochberg`, `Scaling`, `Permanova`, `All`), identical to
this tree apart from the `OPTIONS` line and comment headers. Upstream checks
them with `--safe --without-K` only. No upstream row is graded until upstream
adopts the §2.1 invocation. That is Joshua's decision.
