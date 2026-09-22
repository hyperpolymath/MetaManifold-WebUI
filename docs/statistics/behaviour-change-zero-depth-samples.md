<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Behaviour change — zero-depth samples in the relative-abundance transform

**Status: decided and implemented on 2026-09-22.** This note exists because the change
alters results that saved analyses were computed from, which is not a thing to do quietly.

## What changed

A sample with **no reads at all** (a *zero-depth* sample: every count zero) used to reach
the transform stage inside `prepare_analysis_table`. Every transform divides by a sample
total, so such a sample poisoned whichever transform ran. All-zero samples are now healed
**before** the transform instead of after it.

## Why it had to change

The pipeline wrote a value where the truth is that no value exists:

| Transform | What a zero-depth sample produced |
| --- | --- |
| `relative` | `0.0` for every feature — the claim *"this feature's relative abundance is exactly 0"* about a sample whose relative abundances do not exist. `0/0` is undefined; `0.0` is a value. |
| `rarefy` | `min_lib = minimum(lib_sizes)` is `0`, so **every** sample was scaled by `0/lib`. The result was a prepared table of zeros for all samples, reported as success. |
| `clr` | `log(0) = -Inf`, which centring turns into `NaN`, which the later NaN/Inf healing replaced with `epsilon` — a wrong number presented as a healed one. |

Healing afterwards could not repair any of it. Under `drop_policy=drop` the affected
columns were discarded, but only after the damage was computed; under
`drop_policy=impute` the imputed counts were assigned while `prepared` kept the values
computed from the empty column, so **`prepared` and `filtered_counts` described different
data** — the one inconsistency a pipeline must never have.

This is a case of the principle stated in `method-conditions/exact-descriptive-summaries.md`:
reporting `0` for a zero-depth sample's relative abundance is a lie told with a straight
face, and no downstream check can catch it, because `0.0` is an ordinary number.

## Who is affected

Runs whose input contains a zero-depth sample can have different prepared
results when healing moves before the transform:

| `drop_policy` | Behaviour before | Behaviour now |
| --- | --- | --- |
| `drop` | `rarefy` included the zero-depth sample, so retained columns were scaled to zero before the sample was dropped | sample dropped before `rarefy` — **prepared result changes for `rarefy`** |
| `refuse` | refused | refused, earlier — **same refusal** |
| `impute` | counts were transformed before healing, so `prepared` could retain values for the unhealed zero-depth column | counts imputed, transform sees the imputed counts — **prepared output can change** |

For a zero-depth input, `drop_policy=impute` can change prepared output for
`none`, `relative`, `tss`, `css`, `rss`, `size_factors`, `presence_absence`, or
`rarefy`. `drop_policy=drop` changes prepared output for `rarefy`. Successful
`clr` and `ilr` runs using pseudocount replacement retain equal log-ratio values
for the zero-depth column. Analyses whose inputs had no zero-depth sample are
unchanged — the healing step returns immediately when
there is nothing to heal.

## What to do

Re-run the affected analysis. The previous numbers for a zero-depth sample were not
measurements of a quantity that exists, so there is no correction to apply: the
computation itself was refusing to say "undefined" and saying "zero" instead.

If you are unsure whether an analysis is affected, check its diagnostics for an
`Imputed ... all-zero samples` healing entry. A run that contains one, under a relative,
rarefy or clr transform, is affected.

## What deliberately did NOT change

- **All-zero *taxa* are still healed after the transform.** The asymmetry is intentional.
  A zero-count taxon in a sample that *has* reads has a relative abundance of exactly
  `0.0` — that value is true, so there is no lie to remove — while moving the drop earlier
  would change the geometric mean that CLR centres on, altering results for analyses that
  were already correct. Fixing a defect is not a licence to change the numbers around it.
- **The legacy path is otherwise byte-identical.** The exact-precision layer
  (`exact_summaries.jl`) is a separate, opt-in module that nothing in the pipeline calls;
  this change does not touch it.
- **No method is switched silently.** The healing is recorded in `healings`, surfaced in
  diagnostics and the manifest, and raises the DANGER self-healing banner as before.

## Provenance

The repository owner (`@hyperpolymath`) authorised this change on 2026-09-22, choosing
"fix it now, change the results" over leaving the defect documented or hiding it behind an
opt-in flag, with this note as the accompanying migration record. This is an explicit,
narrow exception to the standing instruction that existing pipeline algorithms and
previously saved analyses not be silently changed: the change is not silent, and the
results it changes were wrong.
