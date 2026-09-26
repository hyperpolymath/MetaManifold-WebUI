<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000043
parent: 0198ba50-0000-7000-8000-000000000040
position: 30
kind: page
tags:
  - theory
  - statistics
  - numerics
archived: false
-->

# Exact arithmetic

**Status: IN PLACE** (descriptive layer). Where exactness lives, what it
buys, and the line it must not cross. Contracts: the repository's
`docs/statistics/numeric-contracts.md`; code: `src/analysis/numeric_policy.jl`,
`src/analysis/exact_summaries.jl`.

## The three kinds of number

Most statistics are not exact, and no policy makes them so. What a policy
can do is stop three different claims from wearing one representation:

| Kind | What it means | May be called a fact? |
|---|---|---|
| **exact** | an integer count, or a rational built from counts; no rounding in its history | yes — as a count or proportion |
| **approximate** | any floating value, **including arbitrary precision** | no — it is a number |
| **rounded** | an approximation cut to N digits for display | no — it is a rendering |

The sentence the whole layer turns on: **higher precision is not exactness.**
`BigFloat` at 4096 bits rounds; it merely rounds further away. The only
exact arithmetic here is integer and rational.

## The policy as a type

`numeric_policy(; mode, precision_bits, max_denominator_bits, round_digits)`
builds an immutable `NumericPolicySpec`, validated at construction:

| Field | Modes / limits | Default |
|---|---|---|
| `mode` | `:ordinary`, `:exact_counts`, `:high_precision` | `:ordinary` |
| `precision_bits` | 2 … 1 000 000 | 53 (Float64's significand) |
| `max_denominator_bits` | ≥ 32 | 4096 |
| `round_digits` | ≥ 0 | 6 |

`:ordinary` is Float64 throughout and is the only mode under which
previously saved analyses are unchanged (the backward-compatibility line).
The load-bearing design: **nothing switches mode on its own.** A caller that
needs `:exact_counts` and is handed `:ordinary` *fails through `assert_mode`*
— it does not receive a Float64 that looks like the exact answer. That is
the "no coercion `Approximate → Exact`" rule from
[Type Theory Meets Statistics](Deep-Dives--Type-Theory-Meets-Statistics)
made executable.

## What exactness buys in practice

`exact_summaries.jl` (catalogue item 1) computes counts and proportions at
exact precision:

- **Counts as integers without a ceiling.** Read counts beyond 2⁵³−1 — where
  every float silently loses integers — stay exact. (This was not
  hypothetical: the boundary audit in issue #52 *measured* where Float64
  stops carrying consecutive integers.)
- **Proportions as rationals of counts.** 2/3 stays 2/3. A proportion
  supplied as text (`"2/3"`, `"4/6"`) is exact; one supplied as a float is
  accepted **only as an approximation and labelled as one** wherever shown.
- **Refusals as facts.** A float claiming exactness is refused; a negative
  count is refused; a total-zero proportion is refused with a name, not
  rendered as 0.

Independent reference: the suite compares value-by-value against Python's
`fractions.Fraction` (skipping loudly by name if `python3` is absent) and
plants hand-derived known answers.

## Two defects the conditions document caught

Worth recording because they show why conditions precede implementation:

1. `to_display` printed a rendering labelled *6dp* — and then printed eighty
   digits after the point. That is the rounded/exact boundary leaking; the
   document ruled, the code changed.
2. Exact rationals rendered as Julia's `2//3` — implementation syntax leaking
   into a human's display. Again: document right, file wrong.

## The line exactness must not cross

**No inference is exact just because its inputs are.** The descriptive layer
claims facts; a p-value, an interval, or an MLE is approximate by
construction (a tail mass or an optimiser output), and the policy does not
pretend otherwise. What does *not* exist yet, and is easy to overread into
this layer:

- **Exact statistical tests** (Fisher's exact, exact NB, permutation
  PERMANOVA) — issue #3, **COMING**. "Exact tests" there will mean the tail
  mass is enumerated/permuted rather than asymptotically approximated — a
  claim about the *reference distribution*, still living in the
  approximate/reporting column for display purposes. The naming collision is
  deliberate and worth meditating on: "exact test" ≠ "exact number".
- Small-n validity: today's honest default for tiny samples is the exact
  descriptive summary plus "no valid inferential test computed" — the
  catalogue endorses exactly this default.

## Why rationals and not decimals

Decimals (fixed-point, arbitrary or not) are exact only for dyadic-friendly
fractions and become a new rounding story otherwise; rationals of integers
are the free field over ℤ and carry no rounding history at all. The
denominator budget (`max_denominator_bits`) exists so that accumulated
products cannot grow unbounded — at the budget the policy *refuses or
degrades explicitly*, never silently simplifies.
