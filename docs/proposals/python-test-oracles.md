<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Proposal: where the no-new-Python rule stops

Status: **needs an owner decision.** Nothing here is applied; the rule in
`.github/workflows/language-policy.yml` is unchanged.

## The question

`scripts/check-no-new-python.sh` refuses *any* added or modified `.py` file,
with no exceptions. That is the estate rule, and this fork states it twice:
in `.coderabbit.yaml` ("prohibits NEW Python files ... with no exceptions") and
through the workflow above.

Two of the open upstream PRs add Python files that are not application code
(#69 adds all four; #68 and #70 add none):

| PR | file | what it is |
| --- | --- | --- |
| #69 | `test/references/exact_summary_reference.py` | `fractions.Fraction` oracle for exact summaries |
| #69 | `test/references/check_high_precision_references.py` | `decimal` oracle for MPFR results |
| #69 | `test/references/check_biological_reference.py` | independent check of a real counts CSV |
| #69 | `test/references/test_biological_checker.py` | tests for the checker above |

Each exists to be *independent of Julia*: the point of an oracle is that it
shares no implementation with the code it checks. `CONTRIBUTING.md` upstream
asks that "tests compare computed values with known references", and #69's
`docs/statistics/validation-evidence.md` cites these files as the evidence.

The policy is coherent for the repository's own code. It is not obviously
coherent for a cross-language oracle, where a Julia replacement would be a
second copy of the thing under test and therefore evidence of nothing.

## Options

**A. Keep "no exceptions" and do not merge #69 here.**
The rule stays exactly as written. #69 can still be proposed upstream, where no
such rule exists, and the fork simply does not carry it. Cost: the fork never
has the validated-statistics work it is currently proposing to upstream, even
after Joshua merges it — which is the opposite of the fork's purpose.

**B. Scope the rule to first-party code, and name the exception in the policy.**
Amend the script so `test/references/**` may add `.py` when the file (a) is an
independent oracle or its test, (b) is not imported by any Julia, R or frontend
code, and (c) is named in the PR description. The workflow keeps refusing
Python everywhere else. Cost: an exception exists, and exceptions drift; it
needs a positive test so that a new `.py` outside the directory still fails.

**C. Keep the rule and let the oracles live upstream only.**
The fork merges #69's Julia, R and TypeScript changes but drops the four Python
files and every Julia test that invokes them. Cost: those tests then either
disappear here or silently stop checking anything, which is worse than either
other option.

## Recommendation

**B**, with the narrowest possible scope: `test/references/` only, oracle files
only, and a planted-negative test in `scripts/tests/test-no-new-python.sh` that
proves a `.py` anywhere else is still refused. It keeps the estate rule's
intent — no new Python *implementation* — while not refusing the one category
where Python's independence is the whole reason it is there.

This is the owner's call, not mine. If the answer is A or C, PR #69's Python
files should be removed from whatever lands here, and that has to be recorded so
a future reader does not assume the oracle evidence exists.

## What does not need a decision

The `TypeScript` position already recorded in `.coderabbit.yaml` — permitted
because it is upstream's frontend and there is one UI stack — needs no change.
#69 adds TypeScript only inside `frontend/`, in that same stack.
