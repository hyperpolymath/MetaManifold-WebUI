<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Formal verification plan — evidence mode (issue #7)

**Status: adopted 2026-09-26.** Companion to
[`verification-plan.md`](verification-plan.md) (issues #20, #21), same prover and
guardrails: Agda, `--safe --without-K`, no postulates, negative controls in
`proofs/agda/reject/`. This document fixes what the evidence library proves,
what it deliberately does not, and how it is tied to the code the server and
the Evidence Mode UI run.

## 1. The gap being closed

The standalone reference explorer (in `residual-evidence-types`) computes
presence verdicts for the signed finite model in separately tested JavaScript,
and its own footer admits there is **no proved extraction correspondence**
between that script and the Agda naturals example shipped beside it. Evidence
Mode (issue #7) turns those verdicts into first-class UI state — avec_fibre
edits, the fibre visualizer, the residual explorer's noise-bound slider — so
the correspondence can no longer be folklore: this library establishes the
signed finite model's decision procedures as *proved correct*, and the golden
vectors pin the same answers across every implementation.

## 2. Layering

| Layer | Content | Status |
|-------|---------|--------|
| **L0 abstract semantics** | `Candidate observe r E = Σ W ((observe w ≡ r) × E w)`; a `Case` carries one consistency witness while `Holds` quantifies over **all** candidates; `Identified` = unique query value across candidates; `actual-world-sound` (a warranted claim about candidates says nothing about reality until the actual world is shown admissible); `Echo`/`AvecFibre` (artefact carries semantic fibre ⇔ its echo fibre is inhabited) and the total-space factorisation; `Warrant`/`Epi`/`SoundWarrant` and `epi-does-not-give` — a warrant token is not truth. | Proved, generic (any `W`, `O`, `E`). |
| **L1 signed finite model** | `signed-integer-v1`: values in [−6, 6] as ℕ offsets, so every predicate is decidable on ℕ and the model is *executable inside Agda*; observation views (exact / sign / magnitude), admissibility (domain bound, noise bound, optional zero assumption); enumeration `candidates = filter cand? allWorlds`. | Proved: `candidates-sound` (listed ⇒ satisfies the specification) and `candidates-complete` (satisfies ∧ b ≤ 6 ⇒ listed). |
| **L2 decision procedures** | `decide`, `verdict₂`, `result` — the exact computation the server routes and the residual explorer run, with the four semantics theorems below. | Proved; plus `finitely-refute-identification` and the five reference presets as computed, proved terms. |
| **L3 implementation seam** | The Julia routes and the TypeScript UI. | Not proved. Pinned by the golden vectors (§4). |

## 3. The four verdict theorems (Decision.agda)

For `cs = candidates view r₀ b z` with `b ≤ 6`:

| Computed verdict | Proved meaning |
|---|---|
| `entailed` | `FHolds … Present` — every admissible candidate has u ≠ 0 |
| `refuted` | `FHolds … Absent` — every admissible candidate has u = 0 |
| `unresolved` | `¬FHolds … Present` **and** `¬FHolds … Absent` (explicit witnesses of each kind) |
| `inconsistent` | `¬ FCase` — no admissible candidate exists. An empty candidate set does **not** make every claim vacuously true: there is no inhabited case at all, so no claim is issued. |

Identification is *not* a verdict: presence without uniqueness is exactly the
"Present, value unknown" preset, and `present-without-identification` proves no
value is identified there. The negative control
`reject/IdentificationWithoutUniqueness.agda` is the UI bug Evidence Mode
exists to prevent — reporting an identified value from a mere presence verdict
— as a term that must fail to type-check.

## 4. Golden vectors — the theorem-to-test map

`proofs/vectors/evidence_vectors.json` (regenerate:
`python3 scripts/gen_evidence_vectors.py`) holds 546 cases: 13 residuals ×
7 noise bounds × 3 views × 2 zero-assumptions, covering all four verdicts and
both identification outcomes. The durable encoding of the semantics is the
generator; Agda pins it as follows:

| Vector field | Agda anchor |
|---|---|
| `candidate_count` | `length (candidates …)` |
| `presence` | `decide (candidates …)` + the four theorems |
| `identified_values` | `values (candidates …)`; singleton ⇔ identified |
| `first_candidates` | `candidates-sound` / `candidates-complete` |

Follow-up stacks consume the same file from Julia (`test/unit`) and bun
(`frontend/tests`), so Agda, Julia and TypeScript are bound to one truth
rather than three agreeing-by-accident implementations.

## 5. What is deliberately **not** proved

- **The server and UI code** (L3): pinned by golden-vector tests, not proofs.
- **Beyond the grid**: the model is finite by design (|values| ≤ 6, bounds ≤ 6).
  Infinity is not approximated here; it is out of scope.
- **Function extensionality**: `Echo.agda` states both fibre encodings and the
  total-space factorisation without funext, keeping the suite's assumptions at
  zero (the ILR plan's §1 guardrails).
- **A general extraction**: `epi-does-not-give` proves there *cannot* be one —
  the reason warrant tokens must be checked against their receipts in code
  rather than trusted.

## 6. Module map

```
proofs/agda/MetaManifold/Evidence/
  Prelude.agda    stdlib-free prelude (only Agda.Builtin.*): ⊥/¬_, ⊎, ×,
                  ∈ as a recursive proposition, subst/J, if/filter, _∸_, dist
  Residual.agda   L0: Candidate/Case/Holds/Identified, actual-world-sound,
                  different-candidates-refute-identification, no-free-weakening
  Echo.agda       L0: Echo fibres, AvecFibre, sans-fibre, total-space factorisation
  Warrant.agda    L0: Warrant/Epi/SoundWarrant, epi-does-not-give
  Signed.agda     L1: the signed finite model; enumeration sound + complete
  Decision.agda   L2: verdicts computed and proved; presets as proved terms
proofs/agda/reject/
  IdentificationWithoutUniqueness.agda   must fail: presence ≠ identification
proofs/vectors/
  evidence_vectors.json                  the L3 pin (§4)
```

The `Evidence.*` modules import only `Agda.Builtin.*` — no stdlib — so the
whole evidence library type-checks under any Agda ≥ 2.6.4.3 even where the
standard library is unavailable; the estate pin (2.6.4.3 + stdlib 2.1) remains
the CI toolchain for the suite as a whole.
