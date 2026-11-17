# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E1: exact Phred expected-error arithmetic in Q(theta), theta = 10^(-1/10).
#
# 10^(-Q/10) = 10^(-a) * theta^b  with Q = 10a + b, 0 <= b <= 9.
# theta is a root of 10 x^10 - 1, irreducible over Q (x^10 - 10 is Eisenstein at 2),
# so 1, theta, ..., theta^9 are linearly independent over Q.  An expected-error sum
# EE = sum_i 10^(-Q_i/10) is therefore ONE element of Q(theta): ten rational coefficients.
#
# Comparison with a rational threshold T:  P(x) = (C0 - T) + C1 x + ... + C9 x^9.
#   - all coefficients zero  -> EE == T exactly
#   - otherwise P(theta) != 0 (linear independence), and since C1..C9 >= 0, P is
#     monotone non-decreasing on x > 0, so a rational enclosure lo < theta < hi gives
#     P(lo) <= P(theta) <= P(hi) with no interval arithmetic.  Bisect until signs agree.
using Random, Printf

const R = Rational{BigInt}

"EE as ten exact rational coefficients of theta^0..theta^9."
function ee_exact(q::AbstractVector{<:Integer})
    c = zeros(R, 10)
    for Q in q
        a, b = divrem(Int(Q), 10)
        c[b + 1] += R(1, big(10)^a)
    end
    c
end

horner(c, x) = foldr((ck, acc) -> ck + x * acc, c)

"Sign of EE - T, exact.  Returns (-1 | 0 | +1, bisection steps used)."
function cmp_exact(c::Vector{R}, T::R)
    p = copy(c); p[1] -= T
    all(iszero, p) && return (0, 0)
    @assert all(>=(0), @view p[2:end])
    if all(iszero, @view p[2:end])          # purely rational: no theta needed
        return (Int(sign(p[1])), 0)
    end
    lo, hi = R(0), R(1)                      # 0 < theta < 1
    steps = 0
    while true
        slo, shi = sign(horner(p, lo)), sign(horner(p, hi))
        slo == shi && slo != 0 && return (Int(slo), steps)
        mid = (lo + hi) / 2
        if 10 * mid^10 < 1; lo = mid else hi = mid end   # theta^10 = 1/10
        steps += 1
        steps > 4000 && error("no separation: contradicts linear independence")
    end
end

ee_float(q) = sum(10.0^(-Q / 10) for Q in q)             # what a C/R double loop does
function ee_big(q; prec = 512)
    setprecision(BigFloat, prec) do
        sum(BigFloat(10)^(-BigFloat(Q) / 10) for Q in q)
    end
end

println("== 1. A filter decision that double precision gets wrong ==")
q = fill(10, 20)                                         # twenty bases at Q10: EE is exactly 2
T = R(2)
@printf("float EE = %.17g ;  float says EE > 2 : %s\n", ee_float(q), ee_float(q) > 2.0)
println("exact  EE vs 2 : sign = ", cmp_exact(ee_exact(q), T)[1], "  (0 means exactly equal, so the read is kept under EE > maxEE)")

println("\n== 2. Order dependence of the double-precision sum ==")
rng = MersenneTwister(20261116)
function order_dependent(rng, n, len, qs)
    k = 0
    for _ in 1:n
        q = rand(rng, qs, len)
        e1 = ee_float(q); e2 = ee_float(sort(q)); e3 = ee_float(reverse(sort(q)))
        k += !(e1 == e2 == e3)
    end
    k
end
for (name, qs) in (("full range Q0..41", 0:41), ("binned {2,12,23,37}", [2, 12, 23, 37]))
    k = order_dependent(rng, 20_000, 250, qs)
    @printf("%-22s reads whose float EE changes with base order: %d / 20000 (%.1f%%)\n", name, k, 100k / 20000)
end
println("exact coefficients are order-independent by construction (rational addition is associative).")

println("\n== 3. Agreement of exact sign with 512-bit BigFloat, and float disagreements ==")
function agree(rng, n, len, qs, Ts)
    bad_exact = 0; bad_float = 0; mingap = big(Inf); maxsteps = 0
    for _ in 1:n
        q = rand(rng, qs, len)
        c = ee_exact(q); eb = ee_big(q); ef = ee_float(q)
        for T in Ts
            s, st = cmp_exact(c, R(T)); maxsteps = max(maxsteps, st)
            sb = Int(sign(eb - T)); sf = Int(sign(ef - T))
            bad_exact += (s != sb); bad_float += (s != sf)
            mingap = min(mingap, abs(eb - T))
        end
    end
    (bad_exact, bad_float, Float64(mingap), maxsteps)
end
for (name, qs, len) in (("Q0..41, len 250", 0:41, 250), ("binned, len 250", [2, 12, 23, 37], 250),
                        ("Q30..41, len 150", 30:41, 150), ("near-threshold: Q8..12, len 20", 8:12, 20))
    be, bf, g, st = agree(rng, 5_000, len, qs, (1, 2, 5))
    @printf("%-32s exact!=BigFloat: %d  float!=exact: %d  min|EE-T|: %.3g  max bisection steps: %d\n", name, be, bf, g, st)
end

println("\n== 4. Adversarial ties: reads built to sit exactly on the threshold ==")
function ties(rng, n)
    flips = 0; exact_ties = 0
    for _ in 1:n
        # multiples of ten only -> EE rational; pick counts so EE == 2 exactly
        k10 = rand(rng, 0:20); k20 = 10 * (20 - k10)       # k10*0.1 + k20*0.01 = 2
        q = shuffle(rng, vcat(fill(10, k10), fill(20, k20)))
        s, _ = cmp_exact(ee_exact(q), R(2)); exact_ties += (s == 0)
        flips += (ee_float(q) > 2.0)
    end
    (exact_ties, flips)
end
et, fl = ties(rng, 2_000)
@printf("constructed reads with EE exactly 2: %d / 2000 ; float wrongly reports EE > 2 for %d of them (%.1f%%)\n", et, fl, 100fl / 2000)

println("\n== 5. Cost ==")
qs = [rand(rng, 0:41, 250) for _ in 1:20_000]
ee_float(qs[1]); cmp_exact(ee_exact(qs[1]), R(2))
tf = @elapsed for q in qs; ee_float(q) > 2.0; end
te = @elapsed for q in qs; cmp_exact(ee_exact(q), R(2)); end
@printf("20000 reads x 250 bases: float %.3f s, exact %.3f s (ratio %.0fx); exact = %.1f microseconds per read\n", tf, te, te / tf, 1e6te / 20000)
