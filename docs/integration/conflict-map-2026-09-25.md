<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Fork↔upstream conflict map — measured 2026-09-25

This is the measured state behind "a naive merge of
`hyperpolymath/MetaManifold-WebUI` (this fork) into
`JoshuaJewell/MetaManifold-WebUI` (upstream) is hundreds of files with
conflicts", and how the re‑anchor collapses it. Numbers are exact for the trees
compared and reproducible with `scripts/reanchor.sh plan` and the commands below.

## The histories: shared root, early divergence, long parallel development

```
git merge-base origin/main upstream/main
→ 7884553  "Initial commit"  (2026-01-30)
```

They **do** share the root commit, but they split at the *second* commit and then
developed in parallel for months:

- fork (`origin/main`): **221** commits since the base (last: `17d8c0d`)
- upstream (`upstream/main`): **89** commits since the base (last push 2026-07-21)

Because both sides changed almost everything from a near‑empty base, the
three‑way merge base (the "Initial commit") is nearly useless — almost every file
differs on both sides — so a single `git merge` conflicts on all of them at once.

> Note: an earlier revision of this document claimed the histories were
> *unrelated* (empty merge base). That was an artifact of a **depth‑1 shallow
> clone** hiding the shared root. With full history the root is `7884553`. The
> conflict *count* below is unchanged; only the mechanism (and therefore the fix)
> is different: this is ordinary divergence, so it is fixable by **rebase**, not
> by unrelated‑history surgery.

## The numbers (one‑shot merge)

| | count |
|---|---:|
| Files in fork | 357 |
| Files in upstream | 195 |
| Shared paths (exist in both) | 186 |
| **Conflicting shared paths (same path, different content)** | **159** |
| Fork-only paths (clean additions) | 171 |
| Upstream-only paths (carried in by a merge) | 9 |
| Files upstream changed since the base | 196 |

## The 159 conflicts, by area

| area | files |
|---|---:|
| `frontend/` (TS/React) | 59 |
| `src/` (Julia) | 40 |
| `test/` | 30 |
| `config/` · `bench/` · root files | 32 |

Only **3** are lockfiles (`Manifest.toml`, `frontend/bun.lock`, `renv/activate.R`)
— handled automatically by merge hygiene (see `README.md`). `renv.lock` is
byte‑identical in both. The rest is genuine source divergence that needs a
*decision*.

## The fix: re‑anchor into a granular history (measured)

`git rebase --onto upstream/main 7884553 origin/main` replays the fork's commits
one at a time onto upstream. Git auto‑applies every commit that doesn't collide
and surfaces only the genuine overlaps, per commit. `scripts/reanchor.sh run`
automates it (fork‑wins on content; respect upstream's deletions). **Measured
result:**

```
granular commits on top of upstream : 206
residual conflicts                  : 0
decisions the policy had to make    : 3
  DELETE (upstream): pipelinesteps.txt   [06d85ba Create run_cutadapt.jl.]
  DELETE (upstream): pipelinesteps.txt   [252299e Merge tables logic.]
  DELETE (upstream): pipelinesteps.txt   [fed106b Added dada2 R module.]
files the re-anchored tree keeps that the fork dropped (review) : 7  (all web/dist/* build output)
```

So the "hundreds of files, load of conflicts" becomes: **auto‑apply 55 clean
commits, make 3 trivial decisions (all the same deleted file), review 7 stray
committed build artefacts, and land ~206 reviewable commits.** The resulting
branch also shares a real merge base with upstream, so *future* upstream changes
merge cleanly too.

Reproduce:

```bash
git fetch upstream origin
scripts/reanchor.sh plan      # per-commit classification
scripts/reanchor.sh run       # or: just reanchor  (leaves branch reanchor/onto-upstream)
```
