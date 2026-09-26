<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000040
parent: null
position: 40
kind: page
tags:
  - theory
  - statistics
  - overview
archived: false
-->

# Deep dives

This is where the mathematics and the engineering receipts live — the
material that would otherwise make the README long and the EXPLAINME
unreadable. The repository's
[EXPLAINME.adoc](https://github.com/hyperpolymath/MetaManifold-WebUI/blob/main/EXPLAINME.adoc)
maps README claims to code and points here for the reasoning; this section is
the reasoning.

Written for readers comfortable with statistics at graduate level and
curious about the type-theoretic discipline around it. Academic and lab
readers alike: the user-facing contracts are
[Analysis and Statistics Today](Users--Analysis-and-Statistics-Today); this
section is *why those contracts are shaped that way*.

## The seven dives

| Dive | Question it answers | Status of its subject |
|---|---|---|
| [Design Progression](Deep-Dives--Design-Progression) | How did we get from raw R/Python scripts to this, and what did each layer add? | historical + IN PLACE |
| [Type Theory Meets Statistics](Deep-Dives--Type-Theory-Meets-Statistics) | What do types have to do with honest statistics? | IN PLACE (the discipline) |
| [Exact Arithmetic](Deep-Dives--Exact-Arithmetic) | When is a number exact, and what does that buy? | IN PLACE (descriptive layer) |
| [Maximum Likelihood](Deep-Dives--Maximum-Likelihood) | How does estimation work here, and what are "unsuccessful states"? | PARTIAL (review pending) |
| [Compositional Statistics](Deep-Dives--Compositional-Statistics) | Why offsets instead of normalising counts away? | IN PLACE (offsets); COMING (compositional methods) |
| [Epistemic Status](Deep-Dives--Epistemic-Status) | What are "epistemic receipts", Σ-types, and warrants without soundness? | IN PLACE (core); COMING (Evidence Mode UI) |
| [Advanced Functionality](Deep-Dives--Advanced-Functionality) | What is the exact/compositional/occupancy/ordination suite, and why is it late? | COMING / BLOCKED |

## The thread through all seven

A statistical result is only as good as the **type of claim** its numbers can
carry. Most of the engineering here is making that notion executable:

- exact / approximate / rounded are *different types of claim* and must not
  wear the same representation ([Exact Arithmetic](Deep-Dives--Exact-Arithmetic));
- a fit is either warranted (converged, identified, within bounds) or it is
  an *unsuccessful state* — there is no third outcome called "a number"
  ([Maximum Likelihood](Deep-Dives--Maximum-Likelihood));
- depth is a modelled quantity (an offset), not a dial to normalise away
  ([Compositional Statistics](Deep-Dives--Compositional-Statistics));
- and every carried result travels with its *warrant* — the reason it is
  admissible — without anyone claiming the warrant is the truth
  ([Epistemic Status](Deep-Dives--Epistemic-Status)).

That thread is why the deep dives are one section and not seven essays.
