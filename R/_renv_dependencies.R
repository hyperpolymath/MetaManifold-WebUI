# Renv dependency discovery file.
#
# Why this block is `if (FALSE)` and must stay:
# renv records packages by scanning the project's R files for library() calls
# ("snapshot.type": "implicit" in renv/settings.json). Nothing in this
# repository sources this file; it exists only so that renv::snapshot() keeps
# these packages in renv.lock. The guard stops the calls from ever running if
# the file is sourced by accident, while still being visible to the scanner.
# Removing the guard or the block would drop these packages from the next
# snapshot. SonarCloud reports the block as a useless `if (FALSE)` (rule
# S1145); that finding does not apply to a renv discovery file.

if (FALSE) {
    library(dada2)
    library(vegan)
    # Retain while installer and CI explicitly verify this package.
    library(tibble)
    library(MASS)
    library(glmGamPoi)
}
