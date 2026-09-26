<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000018
parent: 0198ba50-0000-7000-8000-000000000010
position: 80
kind: page
tags:
  - users
  - support
  - guide
archived: false
-->

# Troubleshooting

**Status: IN PLACE.** Failure modes with known causes, and what each refusal
actually means. Also see `SECURITY.md` for reporting, and `CONTRIBUTING.md`
for bug-report shape.

## Installation and startup

| Symptom | Cause | Fix |
|---|---|---|
| `install.sh` stops at "R not found" | R is the one documented system dependency (absent from the mise registry) | install R ≥ 4.0, re-run `install.sh`; `renv` restores pinned packages via `.Rprofile` |
| Tool download fails | flaky network or TLS interception | re-run — the fetcher retries and names TLS failures explicitly; check `config/defaults/tool_versions.yml` sha256s if it persists |
| Port already in use | default is 8080 | set `JULIA_METAMANIFOLD_PORT` |
| Frontend missing / blank | first-run build did not complete | `bash start.sh` rebuilds; dev toolchain users: `just setup-full` |
| `just ci` fails on a fresh clone | a lane missing its tool (Julia lanes without Julia, e2e without browsers) | fail-loud by design — install the named tool or run the individual lanes (`just` lists all) |

## Pipeline runs

| Symptom | Cause | Fix |
|---|---|---|
| A stage is marked stale after an edit | config change at a finer cascade level | intended: the tooltip lists exactly which keys changed and at which level; re-run the flagged stages |
| cutadapt discards everything | wrong primer pair selected, or `discard_untrimmed: true` with non-matching primers | check `cutadapt.primer_pairs` against `primers.yml`; IUPAC codes matter |
| Merging collapses in paired mode | `trunc_len` too short for the amplicon to overlap | DADA2 needs ~20 bp overlap after truncation: `trunc_len F + R ≥ amplicon + min_overlap` |
| Taxonomy step is slow / memory-heavy | `assignTaxonomy()` with large databases | raise `dada2.taxonomy.multithread` within memory, or use the SSH offload (`dada2.remote`) |
| Remote taxonomy fails | SSH authorisation is the operator's responsibility | verify `host`, `identity_file`, `staging_dir` and `rscript` manually as the same user |
| OTU lane produces tiny clusters | `swarm.min_abundance` / `differences` at odds with depth | defaults (`min_abundance: 2`, `differences: 1`) are sane; deep data can raise `differences` to 2 with justification |
| vsearch taxonomy hits everything at `identity: 0.75` | that floor is deliberately permissive for exploratory work | raise `vsearch.identity` per assay validation; the consensus rank still demands classifier agreement |

## Analysis and refusals (these are features)

| What you see | What it means | What to do |
|---|---|---|
| An **unsuccessful state** instead of estimates | a precondition failed: non-convergence, non-identifiable design, boundary pathology, wrong response type | read the named state; adjust the design/method per `docs/statistics/method-conditions/`; do not fish |
| "Not Implemented" for a method | the method or its R package is genuinely absent from `renv.lock` | it is refused rather than faked (by design); the method you want may be **COMING** — see [Status and Roadmap](Status-and-Roadmap) |
| Significance "unknown" | R was busy / unavailable when the test was requested | re-run; an empty result is never silently "not significant" (#31's rule) |
| DANGER banner on analysis config | someone attempted to disable BH correction or set an out-of-policy advanced parameter | BH is mandatory; the banner logs the attempt. Advanced flags (custom pseudocount, epsilon, zero policy) require the documented justification |
| A requested normalisation was "not applied" | the method name or mode did not survive validation (silent substitution is forbidden) | fix the spelling/mode in config; methods compare case-insensitively since #62 |
| Zero-depth samples disappeared | they are healed/removed **before** transforms by design (#58) | expected; `docs/statistics/behaviour-change-zero-depth-samples.md` describes the change |

## Results and views

| Symptom | Cause | Fix |
|---|---|---|
| Table edits lost after re-annotation | curation is stored separately, but re-annotation with different `max_rank` reshapes rows | re-apply saved presets; contamination flags survive (they key to rank+taxon) |
| Consensus rank very coarse | the classifiers disagree below that rank | often a reference-release mismatch — put both database formats on the same release |
| Composition mostly "unresolved" | quality filter is capping placeholders, or the filter library does not match your taxa | edit the filter library on the Compositions page; loosen the unresolved cap for exploration |
| `run_config.yml` differs from what I set in a UI | finer-level override wins in the cascade | the cascade is instance → study → group → run; check the finer level, and `GET .../config/overrides` lists downstream overrides |

## Getting help

- Bug reports: use the repository's issue templates (they ask for scope:
  fork vs upstream science). The upstream science lane belongs to
  JoshuaJewell/MetaManifold-WebUI; application behaviour to this fork.
- Security: `SECURITY.md`.
- "Is this a bug or a refusal?" — if the output names an unsuccessful state,
  it is the software working. If it produced a number you do not trust,
  that *is* a bug worth filing.
