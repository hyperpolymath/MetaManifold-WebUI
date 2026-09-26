<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000046
parent: 0198ba50-0000-7000-8000-000000000040
position: 60
kind: page
tags:
  - theory
  - types
  - epistemics
archived: false
-->

# Epistemic status and receipts

**Status: PARTIAL — the epistemic core is IN PLACE (`src/core/epistemic.jl`);
the Evidence Mode UI is COMING (#7).** What "epistemic receipts" are, the
type theory they shadow, and why a warrant is not a proof.

## The problem this layer addresses

A pipeline that outputs numbers asks its users to believe things: that the
fit converged, that the method's preconditions held, that the number is not
a stub. Most pipelines leave those beliefs implicit — they hand over bare
numbers and let the README do the warranting. When the README is wrong (or
the reader does not read it), nothing in the output says so.

The epistemic layer makes the warrant **travel with the result**. Every
carried value can wear its status — how it is admissible — as a first-class
part of its representation.

## The Agda lineages being shadowed

`src/core/epistemic.jl` states its provenance openly: finite, executable
shadows of three formal type families (developed in the estate's Agda work —
echo-types, epistemic-types, residual-evidence-types). The mapping:

| Formal notion (Agda) | Shape | Julia shadow | Statistical reading |
|---|---|---|---|
| **Echo** | `Echo f y := Σ (x:A), (f x ≡ y)` — a value plus evidence of how it arose (total space of a fibration; `Σ B (Echo f) ≃ A`) | `EchoFiber`, `avec_fibre` / `sans_fibre` | a result with its derivation (method, policy, trace) — vs a bare result |
| **Identity type** | `f x ≡ y` — evidence of sameness, inspectable | equality evidence in validation | "this output matches the config that promised it" (freshness hashes, `run_config.yml`) |
| **Modality `E κ A`** / **FactiveModality** | framed belief; `reflect` | `Modality`, `FactiveModality` | a result admitted under a stated frame (the model, the policy mode) |
| **Warrant (without soundness)** | grounds for belief, *no* soundness proof attached | `Warrant`, `SoundWarrant` (the latter opt-in) | convergence checks, BH decisions, bootstrap floors — reasons to believe, not truth |
| **Residual-evidence triad** | `Candidate`, `Holds`, `Identified` (actual-world-sound) | `Candidate`, `Case`, `Holds`, `Identified` | candidate explanation → survives checks → identified in the actual world |
| **Admissible worlds** | `present_in_every_admissible_world` (and the `some` / `absent` variants) | same names, exported | robustness across genuinely open analysis choices |

**Warrants without soundness** is the load-bearing choice. A convergence
check is not a proof that the estimate is *true*; it is grounds for admitting
the number at all. The formalism refuses to smuggle soundness in — the
statistics agrees (an ML estimate under a wrong model is still wrong), and
so does the user-facing copy ("computed as documented, not reviewed").

## The wire and the UI

- **`avec_fibre` column** ("with fibre") — the Echo idea on the wire: a
  displayed result can carry the fibre of its derivation. `sans_fibre`
  exists for the bare form, so the distinction is representable both ways.
- **Status vocabulary** (`EPISTEMIC_STATUSES`) — includes
  `present_in_every_admissible_world`-family claims; CladeCumulus (#6) will
  colour cladistic clouds by exactly these.
- **The DANGER banner** — the loud edge of the same discipline: a
  configuration that would disable BH or set an out-of-policy advanced flag
  is a *visible type* (banner + structured log), not a silent option.
- **Refusals** ([Maximum Likelihood](Deep-Dives--Maximum-Likelihood)) are
  the degenerate receipt: the warrant failed, and the system says which one.

## Validation semantics

`present_in_every_admissible_world` (exported and used in validation) is a
modal quantification: a claim is admitted only if it survives every
admissible reading of the data's genuine ambiguities (zero policy,
normalisation story, grouping). Its siblings —
`present_in_some_admissible_world`, `absent_in_every_admissible_world` —
give the lattice that CladeCumulus and Evidence Mode will render. This is
Kripke-flavoured: truth relative to worlds, with the "actual world" entering
through the residual-evidence `Holds → Identified` path.

## What is here and what is coming

**IN PLACE:** the module (types, statuses, the `avec_fibre` column, the
validation predicates); the DANGER banner; unsuccessful states as receipts
across the analysis layer; `clade_cumulus.jl` data structures and live
`present_in_every_admissible_world` validation logic (scaffold).

**COMING:** Full Evidence Mode (#7) — the epistemic editor and fibre
visualiser; CladeCumulus's UI (#6) — cumulative frequencies over a cladistic
tree, epistemic colour coding, cloud sizing by residual count,
drag-and-drop re-partitioning with live admissible-world validation.

**Not claimed:** soundness. Nowhere does the system claim a warrant is true.
`SoundWarrant` exists as a distinct type precisely so that soundness is an
extra, stated property — never a default.
