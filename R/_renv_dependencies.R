# SPDX-License-Identifier: AGPL-3.0-only
# Renv dependency discovery file.
#
# renv finds dependencies by parsing every .R file and collecting the
# library()/require() calls it sees, so these four names must appear literally
# in a file that is never actually executed for its effect.
#
# The conventional idiom for that is `if (FALSE) { ... }`, but a condition that
# is a constant is dead code to every static analyser (SonarCloud rdre:S1145),
# and silencing the rule would be hiding a true observation. A function that is
# defined and never called says the same thing without the dead branch: renv
# parses the whole file either way.
#
# Verified 2026-09-21 with renv::dependencies() against both forms: each returns
# exactly dada2, dplyr, tibble, vegan.
.renv_dependencies <- function() {
    library(dada2)
    library(vegan)
    library(dplyr)
    library(tibble)
}
