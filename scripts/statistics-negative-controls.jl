#!/usr/bin/env julia
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Negative controls for the exact statistics layer (issue #1).
#
# A test suite that only ever sees correct values cannot tell a working
# validation from one that accepts everything. Every check below is the same
# validation the unit tests apply to the real implementation; each is also
# applied to a deliberately wrong implementation (a mutant), and the record
# shows which mutants were caught.
#
# The mutations are chosen to be the mistakes that actually happen in this
# domain rather than arbitrary bit flips:
#
#   * computing an exact statistic through binary64;
#   * dividing by n-1 instead of n;
#   * assuming sampling with replacement in a rarefaction expectation;
#   * adding a pseudocount so a zero denominator never occurs;
#   * rounding a fractional count instead of refusing it;
#   * trusting a float count above 2^53;
#   * ignoring the requested precision and using a fixed one.
#
# Run:
#
#     julia --project=. scripts/statistics-negative-controls.jl
#
# It exits non-zero if any mutant escapes. The unit suite includes this file and
# asserts the same thing, so the evidence is enforced in CI rather than quoted.

using MetaManifold.ExactNumeric
using MetaManifold.ExactStatistics

## ---------------------------------------------------------------------------
## Mutants
## ---------------------------------------------------------------------------

"""Simpson's index computed in binary64 instead of exactly."""
mutant_simpson_binary64(counts) =
    Float64(1 - sum((Float64(c) / Float64(sum(counts)))^2 for c in counts))

"""Simpson's index with a pseudocount, so a zero-read sample never divides by zero."""
mutant_simpson_pseudocount(counts) = simpson_index(BigInt.(counts) .+ 1)

"""A mean dividing by n-1 (a sample standard deviation habit applied to a mean)."""
mutant_mean_off_by_one(total, n) =
    n <= 1 ? Float64(total) : Float64(total) / Float64(n - 1)

"""Expected richness assuming reads are sampled *with* replacement."""
function mutant_expected_richness_with_replacement(counts, depth)
    total = sum(BigInt.(counts))
    s = zero(Rational{BigInt})
    for c in counts
        c == 0 && continue
        s += 1 - (one(Rational{BigInt}) - BigInt(c) // total)^depth
    end
    return s
end

"""A proportion with a pseudocount, so a zero total becomes 1/1."""
mutant_proportion_pseudocount(count, total) = BigInt(count + 1) // BigInt(total + 1)

"""A count conversion that rounds instead of refusing a fractional value."""
function mutant_count_rounds(x)
    x isa AbstractFloat && return BigInt(round(Int, x))
    return BigInt(x)
end

"""A count conversion that trusts a float above 2^53."""
function mutant_count_trusts_large_floats(x)
    x isa AbstractFloat && return BigInt(x)
    return BigInt(x)
end

"""Shannon's index computed at a fixed 256 bits whatever was requested."""
mutant_shannon_fixed_precision(counts) =
    shannon_index(counts, NumericPolicy(mode = "bigfloat", precision_bits = 256))

## ---------------------------------------------------------------------------
## The checks
## ---------------------------------------------------------------------------

const _EXACT_FULL = NumericPolicy(mode = "exact", max_digits = 100_000)

const NEGATIVE_CONTROL_CHECKS = [
    (name     = "Simpson computed through binary64",
     real     = simpson_index,
     mutant   = mutant_simpson_binary64,
     validate = f -> f(BigInt[1, 2]) isa Rational && f(BigInt[1, 2]) == 4 // 9),

    (name     = "Simpson with a pseudocount",
     real     = simpson_index,
     mutant   = mutant_simpson_pseudocount,
     validate = f -> f(BigInt[1, 2]) == 4 // 9),

    (name     = "mean per feature dividing by n-1",
     real     = (total, n) -> exact_ratio(total, n; policy = _EXACT_FULL),
     mutant   = mutant_mean_off_by_one,
     validate = f -> f(30, 3) == 10),

    (name     = "expected richness assuming sampling with replacement",
     real     = (counts, depth) -> expected_richness(counts, depth; policy = _EXACT_FULL),
     mutant   = mutant_expected_richness_with_replacement,
     validate = f -> f(BigInt[2, 3], 2) == 8 // 5),

    (name     = "proportion with a pseudocount",
     real     = proportion_value,
     mutant   = mutant_proportion_pseudocount,
     validate = f -> f(1, 3) == 1 // 3),

    (name     = "fractional count rounded instead of refused",
     real     = exact_count,
     mutant   = mutant_count_rounds,
     validate = f -> try
         f(1.5)
         false
     catch e
         e isa InvalidNumericInput
     end),

    (name     = "float count above 2^53 trusted",
     real     = exact_count,
     mutant   = mutant_count_trusts_large_floats,
     validate = f -> try
         f(Float64(2)^53)
         false
     catch e
         e isa InvalidNumericInput
     end),

    (name     = "Shannon computed at a fixed precision",
     real     = counts -> shannon_index(counts, NumericPolicy(mode = "bigfloat",
                                                             precision_bits = 512)),
     mutant   = mutant_shannon_fixed_precision,
     validate = f -> precision(f(BigInt[90, 10])) == 512),
]

"""Run every negative control, printing the evidence, and return whether all passed."""
function run_negative_controls(io::IO = stdout)
    println(io, "statistics negative controls (issue #1)")
    println(io, "  ", rpad("check", 54), " real    mutant")
    ok = true
    for control in NEGATIVE_CONTROL_CHECKS
        real_passed = try
            control.validate(control.real) === true
        catch e
            println(io, "  real implementation threw in '", control.name, "': ",
                    sprint(showerror, e))
            false
        end
        mutant_rejected = try
            control.validate(control.mutant) === false
        catch e
            # A mutant that throws is caught by a check that expects a value; it
            # only counts as rejected if the check was itself an expectation of
            # refusal, which `validate` returns false for on its own.
            true
        end
        ok &= real_passed && mutant_rejected
        println(io, "  ", rpad(control.name, 54), " ",
                rpad(real_passed ? "pass" : "FAIL", 7), " ",
                mutant_rejected ? "caught" : "ESCAPED")
    end
    println(io, ok ? "all mutants caught" : "at least one mutant escaped")
    return ok
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(run_negative_controls() ? 0 : 1)
end
