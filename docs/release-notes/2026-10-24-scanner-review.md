# Scanner finding review — 2026-10-24

This is a code review of the Hypatia, panic-attack and pons findings reported on
PR #265. It records evidence and code changes; it is **not** a scanner baseline,
suppression list or claim that every finding is clean. Raw scanner reports stay
available to CI.

## Changes made from the reported findings

- The format-probe child supervisor now uses an explicit monotonic deadline
  instead of `while True`. Process-disappearance races are handled as explicit
  `continue` cases. Cleanup also checks whether a direct child is still alive
  when its process group has disappeared, and kills or reports it instead of
  silently discarding that condition.
- The active DADA2 command logger remains because pipeline stages rely on its
  one-string/one-record provenance. Its R-literal encoder now escapes quotes,
  backslashes, line breaks, tabs and control characters, and rejects NUL (which
  R strings cannot represent). Regression tests cover those boundaries.
- The PERMANOVA reference test now binds permutation-block labels as R data.
  It no longer interpolates an R expression string into the test's R program.
- The high-precision property test now requires the **returned candidate** to
  be a `BigFloat` as part of the numerical comparison. The previous assertion
  checked only the independent reference value's type; it did not establish the
  result's type or accuracy.
- The installer now calls Julia's `Base.Libc.geteuid()` abstraction rather than
  making a direct `ccall` for the root check.

## R execution findings: remaining boundary, reviewed

`RCall.reval` executes R source and is treated as an execution boundary. The
pinned panic-attack Julia detector is a content-substring heuristic: it reports
`eval(` or `Meta.parse(` without distinguishing RCall's `reval`, fixed R source,
or parse-only syntax validation. See the pinned detector implementation at
[panic-attack `b689a74`](https://github.com/hyperpolymath/panic-attack/blob/b689a74d2762a1c19839ae3fbd59b7fe5ef920ea/src/assail/analyzer.rs#L4735-L4756).
No inline `panic-attack: accepted` marker was added; these findings remain
visible pending a more precise detector or a separately approved refactor.

The current boundaries were reviewed individually:

| Location | Boundary and evidence |
|---|---|
| `src/analysis/analysis.jl` | R snippets are application-owned source. Matrices, labels and seeds are bound as R variables. The one formula assembled from metadata uses `_permanova_formula_rhs`, which accepts only plain, non-reserved ASCII R identifiers; expression-shaped names are rejected and tested in `test/unit/test_permanova.jl`. |
| `src/pipeline/dada2/context.jl` | `_r_run_logged` is active and therefore retained. Stage call templates are fixed in source; every config-derived string/number is rendered by `_r_lit`. The serializer now escapes quote/backslash and line/control characters and refuses NUL; `test/unit/test_dada2_commands.jl` covers these cases. |
| `src/analysis/differential.jl` | Model programs are source constants. Counts, labels, offsets and validated method selections cross through RCall bindings, not source interpolation. Cleanup expressions use fixed variable names. |
| `src/analysis/ordination.jl` | R receives `ParsedFormula.canonical_rhs`, rebuilt from a strict Julia parser that admits identifiers, `+`, two-way `:`/`*`, and `Condition(...)` only. The parser rejects arbitrary calls and is covered by ordination formula tests. |
| `src/core/provenance.jl` | The package name interpolated into a query is restricted to `[A-Za-z][A-Za-z0-9.]*`; quotes, separators and control characters are rejected before source construction. |
| `scripts/check-julia-syntax.jl` | `Meta.parse` constructs syntax trees only. The script does not evaluate parsed expressions; it explicitly rejects parser errors, incomplete expressions and top-level stray `end`. |
| `test/unit/test_permanova.jl` | The former interpolated permutation expression has been replaced by a bound vector and fixed R control flow. Remaining R calls run the test's fixed reference program. |

The remaining `RCall.reval` sites are required to run the existing pinned R
analysis code. They are not suppressed or claimed to be harmless by virtue of
using R; the input-to-source boundaries above are the reviewed controls.

## FFI finding: intentional low-level measurement boundary

`install.jl` no longer contains a direct foreign call. The three direct libc
calls in `src/core/memory_probe.jl` remain: `open`, `read` and `close` read
`/proc/<pid>/status` into preallocated buffers so the opt-in occupancy probe
does not add Julia allocations to the measurement. The path is built from an
integer child PID, is NUL-terminated, and is kept alive with `GC.@preserve`; no
user-supplied pointer or function name reaches the calls. Read failures are
reported as a missing process sample, and the opened descriptor is closed.

This is a real, deliberately narrow FFI boundary, not a false positive or a
waiver. The panic-attack finding remains reportable; replacing it with allocating
Julia IO would change the measurement the probe exists to make.

## Pons findings: verified cleanup races

The pons findings were on handlers for `ProcessLookupError` and
`ChildProcessError`. These are TOCTOU races between reading `/proc`, signaling,
and reaping a child. The handlers now state the race outcome with explicit
control flow; the direct-child cleanup path fails closed if a child is still
live. The supervisor's cleanup deadline is now visible in the loop condition.
The pinned pons rule only reports empty or Python-`pass`-only handlers; its
[implementation at `32e5567`](https://github.com/hyperpolymath/pons-asinorum/blob/32e55677d8fd1f3010848dee22e822c2f385c2a0/crates/pons-rules/src/t0/swallowed_error.rs)
was reviewed. No pons suppression comments were added.

## Hypatia findings not waived

- The seven reported TypeScript paths were checked against the exact upstream
  snapshot used by `config/hypatia/upstream-typescript-allowlist.txt` and are
  absent from that snapshot. They remain reportable; the upstream exception was
  not broadened.
- The Python files are independent statistical references and format-readiness
  test/probe harnesses. Their language-policy findings are not safety bugs, but
  they are not allowlisted or suppressed. Rewriting the independent oracles
  solely to satisfy the scanner would remove their cross-implementation value.
- The workflow-name finding is addressed by moving the **existing, active** fork
  governance workflow to `.github/workflows/hypatia-scan.yml`; it still runs the
  same governance jobs and scanner, so this does not add a duplicate or no-op
  scan. CodeQL is already run by the configured GitHub App; no second CodeQL
  workflow was added. There is no configured mirror target, so no empty
  `mirror.yml` was added.
- Findings tied to stored code-scanning alerts and any findings in the
  unavailable detailed artifact are not represented as fixed here. The scan
  artifact remains the authoritative evidence for those items.
