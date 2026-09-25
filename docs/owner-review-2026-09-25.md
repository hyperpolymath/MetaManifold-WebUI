<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# NOTE TO JOSHUA: OWNER REVIEW (25 SEPTEMBER 2026)

# HELLO JOSHUA! PLEASE READ THIS FIRST.

This document is written for you, Joshua Jewell, owner and creator of **MetaManifold-WebUI**.
It explains what has been happening on the **hyperpolymath** fork of your repository, what was changed, why it was changed, and what choices you have now.
It is written in plain, friendly English so that anyone—including a smart 14-year-old—can follow along without getting lost in technical jargon.

---

## 1. WORD GLOSSARY

Before we start, here are nine simple words you will see throughout this note:

- **Project (or Codebase):** The collection of computer files, scripts, and notes that make up MetaManifold-WebUI.
- **Fork:** A copy of your original project created under a different account (`hyperpolymath`) where new work, bug fixes, and testing happen without changing your original files.
- **Commit:** A saved snapshot of changes to files, like saving a new draft of a document with a note explaining what was updated.
- **Pull Request (PR):** An invitation to take changes made on a branch or fork and add them back into a main project.
- **Merge:** Accepting a Pull Request and combining its saved changes into the project's main branch.
- **Issue:** A post on GitHub used to report a bug, request a new feature, or ask a question.
- **Open vs. Closed:** An "Open" issue is something currently being tracked or planned. A "Closed" issue means the specific discussion or fix is finished.
- **Test:** A short automated check that runs the code with sample data and verifies that the output matches known mathematics.
- **CI (Continuous Integration):** A robot in the cloud (GitHub Actions) that automatically runs every test whenever code is pushed, showing a green checkmark if all tests pass or a red X if something broke.

---

## 2. WHAT HAPPENED IN FIVE SENTENCES

1. You built MetaManifold-WebUI as a visual workbench for microbiome analysis, with the original code last updated on 21 July 2026.
2. The team on the `hyperpolymath` fork set up strict tests and discovered that some analysis screens were showing realistic-looking fake numbers rather than running real statistical calculations.
3. We removed all invented numbers, connected real statistical models (`MASS::glm.nb` and linear regressions), and added exact offset calculations for library size and normalisation (TSS, CSS, TMM, and RLE).
4. Whenever a method or package was missing from the locked environment, the software was taught to say "Not Implemented" and refuse to guess, protecting researchers from publishing false biology.
5. All original code remains safe and untouched in your repository, and four pull requests are ready and waiting for your review.

---

## 3. NINE THINGS THAT NEED EXPLANATION

### 1. Copy-vs-Original Divergence
Your original project (`JoshuaJewell/MetaManifold-WebUI`) has stayed exactly as you left it on 21 July 2026. Meanwhile, on the `hyperpolymath` fork, dozens of improvements, automated tests, mathematical verifications, and safety checks were added. This means the fork has moved ahead significantly while keeping your core vision intact.

### 2. Four Pull Requests Waiting Since September
Four pull requests were opened against your upstream repository in September 2026:
- PR #7: Stipple and Vue interface migration.
- PR #8: Fix for the 1x1 matrix edge case.
- PR #10: Baseline benchmarks and CI setup.
- PR #11: Pinned download retries for reliable setup.
These are ready whenever you want to inspect or merge them.

### 3. Old Screens Invented Numbers — Deleted, With a Guard Test
Earlier versions of the execution harness had placeholder code that computed p-values from `hash(taxon_id)`. Because the numbers came from the letters in the microbe's name and not from the sequencing counts, they looked believable but were completely meaningless. We deleted that placeholder code completely, replaced it with real statistical models, and added a test that fails automatically if fake numbers are ever reintroduced.

### 4. One Capital Letter Reddened CI ("tss" vs "TSS")
During work on normalisation offsets, the configuration saved the method name in lowercase (`"tss"`), while the compatibility list checked for uppercase (`"TSS"`). That single mismatched letter caused valid runs to be rejected and turned CI red. We fixed both sides to compare in lowercase, and CI now accepts all standard spellings.

### 5. Closed Does Not Mean Done For Deferred Notes
When issues on the fork were closed after reaching milestone boundaries, that did not mean every conceivable feature was built. Deferred ideas (such as phylogenetic tree calculations or complex multinomial models) are carefully recorded in `docs/milestones/02-deferred-issues.md` so that future researchers know exactly what remains for future versions.

### 6. Two Issues Must Stay Open
Two issues must never be closed prematurely:
- **Issue #1 (The Julia Statistics Layer):** The overarching umbrella for exact, validated biological statistics.
- **Issue #2 (The Symbolic Mathematics Engine):** Kept with a large **BLOCKED** sign. Symbolic formula manipulation must wait until the core numerical statistics are proven solid on real biological data.

### 7. Refusals Are a Feature, Not a Failure
If a user asks for an algorithm that is not installed or inputs data that violates mathematical rules (like asking for log of zero or running a negative binomial model with no offset), the software now halts immediately with an explicit error. Saying "No, this cannot be computed safely" protects scientists from writing erroneous papers.

### 8. The Locked Package List (`renv.lock`)
To ensure anyone in the world gets the exact same results today and five years from now, all R packages are pinned in `renv.lock`. Packages not in the lockfile (such as `metagenomeSeq` or `glmGamPoi`) are not used or faked. When requested, the software clearly states that the package is absent from the lockfile rather than guessing.

### 9. Nothing Was Deleted From Your Original Project
Not a single file, commit, or branch on `JoshuaJewell/MetaManifold-WebUI` was overwritten or lost. Your repository remains 100% intact, exactly where you left it on 21 July 2026.

---

## 4. FIVE-MINUTE PR-REVIEW WALKTHROUGH

When you have five minutes to review the pull requests sent to your repository, follow this quick checklist:

1. **Check PR #11 ("Ci/retry pinned downloads"):**
   - Look at `.github/workflows/ci.yml`.
   - It simply adds retry logic so that temporary network glitches during package downloads do not fail the build. Safe and straightforward.
2. **Check PR #8 ("Fix/38 drop the 1x1 matrix"):**
   - Look at the test and matrix manipulation lines.
   - It prevents single-element matrices from crashing array operations.
3. **Check PR #10 ("Feat/baseline benchmarks ci"):**
   - Look at `frontend/bench/` and the benchmark script.
   - It records runtimes so future pull requests can check if they made the UI slower.
4. **Check PR #7 ("Stipple/Vue migration"):**
   - This is the largest PR. It modernises the reactive UI components and brings frontend dependencies into lockfile compliance.
   - Run the frontend tests with `bun test` to confirm everything stays green.

---

## 5. FOUR OPTIONS FOR THE FUTURE OF THE FORK

Here are four ways you can proceed, depending on your time and goals:

- **Option A (Full Merge & Reconnection):**
  Review and merge the open PRs into your repository, then fast-forward your main branch to incorporate the verified statistics and test suite from `hyperpolymath`.
- **Option B (Selective Cherry-Picking):**
  Accept the infrastructure and bug-fix PRs (#8, #10, #11), while keeping statistical and UI changes in the fork until you have time to examine them in depth.
- **Option C (Dual-Track / Research Fork):**
  Leave your original repository as the historical v1 milestone, and let `hyperpolymath/MetaManifold-WebUI` serve as the active development engine for papers and production deployments.
- **Option D (Handover / Archive Notice):**
  Add a short note in your README pointing researchers to the `hyperpolymath` fork for active maintenance, while you retain full credit as the original creator and architect.

Whatever you decide, thank you for creating MetaManifold! Your work gave this entire effort its foundation.
