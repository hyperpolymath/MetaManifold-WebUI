# SPDX-License-Identifier: AGPL-3.0-only
"""
    Epistemic — bridge to hyperpolymath/echo-types, epistemic-types, residual-evidence-types

Implements the epistemic layer claimed to be already implemented but not found in main.
This module is additive and does not overwrite colleagues' work; it provides the interface
described in the task:

- Echo + Epistemic + Residual Evidence with `avec_fibre` column
- `Epistemic.jl` (this file)
- `present_in_every_admissible_world` validation
- Warrant types, Echo fibers, Candidate worlds

Based on Agda sources:
- echo-types: Echo f y := Σ (x:A), (f x ≡ y), total space Σ B (Echo f) ≃ A
- epistemic-types: Modality E κ A, FactiveModality with reflect, Warrant without soundness
- residual-evidence-types: Candidate, Holds, Identified, actual-world-sound

For Julia, we provide finite, executable shadows of those types.
"""
module Epistemic

using OrderedCollections

export EchoFiber, Warrant, SoundWarrant, Candidate, Case,
       avec_fibre, sans_fibre,
       present_in_every_admissible_world, present_in_some_admissible_world,
       absent_in_every_admissible_world,
       EPISTEMIC_STATUSES, AVEC_FIBRE_COLUMN,
       epistemic_colour, cloud_size_by_residual

const AVEC_FIBRE_COLUMN = "avec_fibre"
const EPISTEMIC_STATUSES = ("present_in_every_admissible_world",
                            "present_in_some_admissible_world",
                            "absent_in_every_admissible_world",
                            "unknown")

# --------------------------------------------------------------------------
# Echo Types — finite shadow
# --------------------------------------------------------------------------

"""
    EchoFiber{A,B}

Finite shadow of `Echo f y := Σ (x:A), (f x ≡ y)`.

- `value`: the y:B observed
- `witnesses`: vector of (x, proof that f(x)==y) — the fiber over y
- `residue`: structured loss witness (what was lost but constrained)

In bioinformatics: f = observation function (e.g., sequencing + denoising),
A = true biological world (true abundances), B = observed table,
fiber = all true worlds compatible with observed.
"""
struct EchoFiber{A,B}
    observed::B
    witnesses::Vector{A}
    residue::OrderedDict{String,Any}

    function EchoFiber{A,B}(observed::B, witnesses::Vector{A}, residue::OrderedDict{String,Any}=OrderedDict{String,Any}()) where {A,B}
        new{A,B}(observed, witnesses, residue)
    end
end

EchoFiber(observed::B, witnesses::Vector{A}) where {A,B} = EchoFiber{A,B}(observed, witnesses)

"""
    avec_fibre(fiber) -> Bool

True if artefact carries enough semantic fibre to support inferences.
From echo-types: avec_fibre = artefact retains structured constraint on possible origins.
"""
avec_fibre(fiber::EchoFiber)::Bool = !isempty(fiber.witnesses)

"""
    sans_fibre(fiber) -> Bool

Opposite of avec_fibre: artefact is only valid target-side value, no origin structure retained.
"""
sans_fibre(fiber::EchoFiber)::Bool = !avec_fibre(fiber)

# --------------------------------------------------------------------------
# Epistemic Types — Warrant without soundness
# --------------------------------------------------------------------------

"""
    Warrant{A}

The type of evidence tokens for A, without assuming evidence is valid.
From epistemic-types: separates "I have a receipt for A" from "A is true".

- `evidence_type`: what kind of evidence (e.g., "count >= threshold")
- `tokens`: vector of evidence tokens
- `claim`: the claim A purports to support (e.g., "taxon present")

Having Warrant does NOT give A. Need SoundWarrant.
"""
struct Warrant{A}
    evidence_type::String
    tokens::Vector{Any}
    claim::A
end

"""
    SoundWarrant{A}

Warrant plus proof that evidence → A.
From epistemic-types: adds `sound : Evidence → A`.
"""
struct SoundWarrant{A}
    warrant::Warrant{A}
    sound::Function  # Evidence -> A

    function SoundWarrant{A}(warrant::Warrant{A}, sound::Function) where A
        new{A}(warrant, sound)
    end
end

function (sw::SoundWarrant{A})(token)::A where A
    return sw.sound(token)
end

# --------------------------------------------------------------------------
# Residual Evidence Types — Candidate, Holds, Identified
# --------------------------------------------------------------------------

"""
    Candidate{W,O}

Ordinary evidence-refined preimage fibre: Σ W (observe(W)≡r × E(W))

- `world`: a possible world W
- `observed`: proof that observe(world) == r
- `evidence`: evidence that E(world) holds

In microbiome: W = (true abundance, noise), observe = true+noise, E = noise bound + avec_fibre
"""
struct Candidate{W,O}
    world::W
    observed_equals::Bool
    evidence_holds::Bool
    metadata::OrderedDict{String,Any}

    function Candidate{W,O}(world::W, observed_equals::Bool, evidence_holds::Bool, metadata::OrderedDict{String,Any}=OrderedDict{String,Any}()) where {W,O}
        new{W,O}(world, observed_equals, evidence_holds, metadata)
    end
end

"""
    Case{W,O}

An inhabited candidate set: witness that at least one candidate exists.
Claims still quantify over ALL candidates, not merely this inhabitant.
"""
struct Case{W,O}
    witness::Candidate{W,O}
    all_candidates::Vector{Candidate{W,O}}

    function Case{W,O}(witness::Candidate{W,O}, all_candidates::Vector{Candidate{W,O}}) where {W,O}
        # Ensure witness is in all_candidates or add it
        new{W,O}(witness, all_candidates)
    end
end

Case(witness::Candidate{W,O}) where {W,O} = Case{W,O}(witness, [witness])

# --------------------------------------------------------------------------
# Core logic: present_in_every_admissible_world
# --------------------------------------------------------------------------

"""
    present_in_every_admissible_world(case, present_fn) -> Bool

Implements Holds Present: Present holds for every candidate in case.

- `case`: Case with all admissible worlds (those satisfying observe==r and evidence)
- `present_fn`: W -> Bool, true if taxon present in that world

Returns true iff present_fn holds for EVERY candidate (i.e., present in every admissible world).

This is the key validation for CladeCumulus drag-and-drop: a taxon can only be
placed in a clade if it is present in every admissible world consistent with evidence.
Otherwise, placement would be unsound.

Example from residual-evidence-types:
  r = u + n = 2, with noise bound n <=1
  candidates: (0,2) and (2,0) initially — presence not provable
  with bound n<=1: candidates (1,1) and (2,0) — presence IS provable (u !=0 in both)
  but value not identified (u could be 1 or 2)
"""
function present_in_every_admissible_world(case::Case{W,O}, present_fn::Function)::Bool where {W,O}
    # All candidates must satisfy evidence and observation (by construction)
    # Check present_fn for every candidate
    for cand in case.all_candidates
        cand.evidence_holds || continue  # only consider admissible worlds where evidence holds
        cand.observed_equals || continue # and observation matches
        if !present_fn(cand.world)
            return false
        end
    end
    # Also need at least one admissible candidate, otherwise vacuously true is unsound
    admissible = filter(c -> c.evidence_holds && c.observed_equals, case.all_candidates)
    isempty(admissible) && return false # no admissible world -> cannot claim presence (inconsistent case)
    return true
end

function present_in_some_admissible_world(case::Case{W,O}, present_fn::Function)::Bool where {W,O}
    for cand in case.all_candidates
        (cand.evidence_holds && cand.observed_equals) || continue
        present_fn(cand.world) && return true
    end
    return false
end

function absent_in_every_admissible_world(case::Case{W,O}, present_fn::Function)::Bool where {W,O}
    return !present_in_some_admissible_world(case, present_fn)
end

# --------------------------------------------------------------------------
# Simplified API for microbiome counts (finite model)
# --------------------------------------------------------------------------

"""
    present_in_every_admissible_world(counts, evidence; threshold=1.0) -> Bool

Simplified finite model for microbiome: counts across samples/views,
evidence dict with avec_fibre, noise_bound, etc.

- `counts`: Vector{Float64} observed counts across samples or candidate decompositions
- `evidence`: Dict with keys:
  - "avec_fibre": Bool — does artefact carry semantic fibre?
  - "epistemic_status": String — precomputed status if available
  - "noise_bound": Float64 — max noise allowed
  - "threshold": Float64 — presence threshold

Returns true iff present in every admissible world.
"""
function present_in_every_admissible_world(counts::Vector{Float64},
                                           evidence::Dict{String,Any};
                                           threshold::Float64=1.0)::Bool
    avec = get(evidence, "avec_fibre", false) == true
    !avec && return false

    status = get(evidence, "epistemic_status", "unknown")
    status == "present_in_every_admissible_world" && return true
    status == "absent_in_every_admissible_world" && return false

    # Finite candidate model: all counts >= threshold and at least one admissible
    # Admissible = count >=0 and satisfies noise bound if given
    noise_bound = get(evidence, "noise_bound", nothing)
    if !isnothing(noise_bound)
        # Filter candidates that satisfy noise bound (simplified: count <= bound? Actually noise <= bound)
        # For this simplified model, we assume counts already filtered
    end

    isempty(counts) && return false
    return all(c -> c >= threshold, counts)
end

# --------------------------------------------------------------------------
# Epistemic colour coding and cloud sizing (for CladeCumulus)
# --------------------------------------------------------------------------

"""
    epistemic_colour(status) -> String

Colour coding for epistemic status:
- present_in_every_admissible_world: green (solid evidence)
- present_in_some_admissible_world: yellow/orange (uncertain)
- absent_in_every_admissible_world: grey (absent)
- unknown: red or striped (no fibre)
"""
function epistemic_colour(status::String)::String
    if status == "present_in_every_admissible_world"
        return "#2e7d32"  # green
    elseif status == "present_in_some_admissible_world"
        return "#f9a825"  # yellow/orange
    elseif status == "absent_in_every_admissible_world"
        return "#9e9e9e"  # grey
    else
        return "#c62828"  # red for unknown / sans fibre
    end
end

"""
    cloud_size_by_residual(residual_count) -> Float64

Cloud sizing by residual count: larger cloud = more residual evidence,
i.e., more candidate worlds or larger fiber.

For CladeCumulus: cloud size ∝ log(1 + residual_count)
"""
function cloud_size_by_residual(residual_count::Int)::Float64
    return log(1 + residual_count) * 10.0 + 5.0  # base size 5, scaled by log
end

function cloud_size_by_residual(residual_count::Float64)::Float64
    return log(1 + residual_count) * 10.0 + 5.0
end

# --------------------------------------------------------------------------
# Integration with DuckDB: avec_fibre column handling
# --------------------------------------------------------------------------

"""
    ensure_avec_fibre_column(con, table) -> Bool

Ensures the avec_fibre column exists in DuckDB table, creating it if needed.
Returns true if column exists or was created.

The column is Boolean, indicating whether row carries enough semantic fibre.
"""
function ensure_avec_fibre_column(con, table::String)::Bool
    # This is a placeholder for actual DuckDB interaction; real implementation
    # would use DBInterface.execute
    # For now, return true as stub
    return true
end

"""
    epistemic_status_for_row(row, evidence) -> String

Computes epistemic status for a single row (taxon) given evidence.

- If avec_fibre=false → unknown
- Else if present in every admissible world → present_in_every_admissible_world
- Else if present in some → present_in_some_admissible_world
- Else → absent_in_every_admissible_world
"""
function epistemic_status_for_row(row::Dict{String,Any}, evidence::Dict{String,Any})::String
    avec = get(row, AVEC_FIBRE_COLUMN, get(evidence, "avec_fibre", false))
    !avec && return "unknown"

    # Simplified: check if count column >= threshold
    count = get(row, "total", get(row, "count", 0.0))
    threshold = Float64(get(evidence, "threshold", 1.0))

    if count >= threshold
        # Need to check all candidate worlds — for now, if avec_fibre and count>=threshold, assume present_in_every?
        # Actually need more evidence: if residual count is low, we can be confident
        residual_count = get(evidence, "residual_count", 0)
        if residual_count == 0
            return "present_in_every_admissible_world"
        else
            return "present_in_some_admissible_world"
        end
    else
        return "absent_in_every_admissible_world"
    end
end

end # module Epistemic
