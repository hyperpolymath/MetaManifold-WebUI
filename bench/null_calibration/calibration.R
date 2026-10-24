#!/usr/bin/env Rscript
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Null-calibration and power bench for the nb_glm tests in
# src/analysis/differential.jl (fork issue #193). This is a bench, not a unit
# test: it is slow and stochastic, and it never runs in CI by default.
#
# What it measures, on the SAME simulated datasets (paired comparison):
#   wald_ml      - the production default: the real `_FIT_R` block extracted
#                  from differential.jl, da_use_gp = FALSE (MASS::glm.nb per
#                  taxon, Wald test at fixed scale 1).
#   wald_trend   - the production glmGamPoi option ON THIS BRANCH: the same
#                  `_FIT_R` block with da_use_gp = TRUE (glm_gp dispersion
#                  trend plugged into a fixed-theta Wald fit). This is NOT
#                  glmGamPoi's quasi-likelihood test. Needs glmGamPoi.
#   lrt          - MASS::glm.nb likelihood-ratio test, full (~ group) against
#                  intercept-only, each fit estimating its own theta;
#                  2 * (logLik(full) - logLik(null)) against chisq(1).
#                  Bench-only candidate fix; production does not use it.
#   ql_f         - quasi-likelihood F test on the SAME full glm.nb fit that
#                  lrt makes: phi = Pearson X^2 / residual df, and
#                  F = (beta / se)^2 / phi against F(1, residual df). This is
#                  edgeR's QL idea without empirical-Bayes shrinkage, so it
#                  propagates the per-taxon dispersion estimate instead of
#                  treating theta as known. Bench-only candidate; production
#                  does not use it, and it is NOT glmGamPoi's test_de.
#   glmgampoi_ql - glmGamPoi's own quasi-likelihood F-test (glm_gp + test_de),
#                  as on the upstream PR 62 branch. Needs glmGamPoi.
#   edger_ql     - edgeR's quasi-likelihood F-test as an outside reference
#                  only. Needs edgeR. Not a dependency of the app.
#
# Tests whose package is unavailable are skipped LOUDLY (a line on stdout and
# in the provenance file), never silently replaced by another test.
#
# Usage (from the repo root, with the pinned R library restored):
#   Rscript bench/null_calibration/calibration.R --mode=quick
#   Rscript bench/null_calibration/calibration.R --mode=full     # hours; see README
#   Rscript bench/null_calibration/calibration.R --truth=power --log2fc=1 \
#       --n-per=4,12 --sims=200
# Any --key=value below overrides the mode defaults. Under WebR (no Rscript
# argv), settings may instead come from the NB_CALIB_ARGS environment
# variable as one space-separated string; see webr_run.mjs.
#
# Output: one appended CSV per cell under --out (default
# bench/null_calibration/results/raw), so an interrupted long run keeps the
# simulations it finished. summarise.R aggregates them.

## ---------------------------------------------------------------- settings

parse_args <- function(argv) {
  out <- list()
  for (a in argv) {
    if (!grepl("^--[a-z0-9-]+=", a)) stop("unrecognised argument '", a, "' (want --key=value)")
    kv <- strsplit(sub("^--", "", a), "=", fixed = TRUE)[[1]]
    out[[kv[1]]] <- paste(kv[-1], collapse = "=")
  }
  out
}

argv <- commandArgs(trailingOnly = TRUE)
if (length(argv) == 0 && nzchar(Sys.getenv("NB_CALIB_ARGS"))) {
  argv <- strsplit(trimws(Sys.getenv("NB_CALIB_ARGS")), "\\s+")[[1]]
}
args <- parse_args(argv)

mode <- if (!is.null(args$mode)) args$mode else "quick"
defaults <- switch(mode,
  quick = list(`n-per` = "4", sims = "10", taxa = "20", shapes = "original",
               offsets = "tss", tests = "wald_ml,lrt,ql_f", truth = "null",
               log2fc = "1", seed = "20261020"),
  full  = list(`n-per` = "3,4,6,8,12,20", sims = "1000", taxa = "40",
               shapes = "original,constant,sparse,unequal_lib",
               offsets = "tss,rle",
               tests = "wald_ml,lrt,ql_f,wald_trend,glmgampoi_ql,edger_ql",
               truth = "null", log2fc = "1", seed = "20261020"),
  stop("unknown --mode '", mode, "' (want quick or full, plus overrides)")
)
for (k in names(defaults)) if (is.null(args[[k]])) args[[k]] <- defaults[[k]]
if (is.null(args$out)) args$out <- file.path("bench", "null_calibration", "results", "raw")
if (is.null(args[["differential-jl"]])) {
  args[["differential-jl"]] <- file.path("src", "analysis", "differential.jl")
}

csv_ints <- function(s) as.integer(strsplit(s, ",", fixed = TRUE)[[1]])
csv_strs <- function(s) trimws(strsplit(s, ",", fixed = TRUE)[[1]])

n_pers   <- csv_ints(args[["n-per"]])
n_sims   <- as.integer(args$sims)
n_taxa   <- as.integer(args$taxa)
shapes   <- csv_strs(args$shapes)
offsets  <- csv_strs(args$offsets)
want     <- csv_strs(args$tests)
truth    <- args$truth
lfc      <- as.numeric(args$log2fc)
seed0    <- as.integer(args$seed)
out_dir  <- args$out
stopifnot(truth %in% c("null", "power"))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

## ------------------------------------------------------------ MASS access
# Normally MASS is installed and the extracted production block runs
# byte-identical. In a minimal R with no MASS but with MASS's pure-R
# negbin.R already sourced (glm.nb is pure R; MASS 7.3-65 negbin.R makes no
# .C/.Call/.Fortran call), the block's `MASS::` prefixes are stripped as a
# single mechanical substitution and that fact is recorded in the
# provenance. The functions executed are still MASS's own source.

have_mass_ns <- requireNamespace("MASS", quietly = TRUE)
mass_mode <- if (have_mass_ns) {
  paste0("installed MASS ", as.character(packageVersion("MASS")))
} else if (exists("glm.nb", envir = globalenv())) {
  "sourced negbin.R (MASS:: stripped from the extracted block; see header)"
} else {
  stop("MASS is not available and glm.nb is not sourced: restore renv.lock first")
}
glm_nb <- if (have_mass_ns) MASS::glm.nb else get("glm.nb", envir = globalenv())

# Digests of the two inputs that decide the numbers, so a committed result can
# be tied to the exact bench and the exact production block that produced it.
file_md5 <- function(path) unname(tools::md5sum(path))
script_path <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1])
if (is.na(script_path) || !file.exists(script_path)) {
  # sourced (WebR) rather than --file=: the driver runs from /work.
  candidate <- file.path(getwd(), "calibration.R")
  script_path <- if (file.exists(candidate)) candidate else NA_character_
}
script_md5 <- if (is.na(script_path)) NA_character_ else file_md5(script_path)

have_gp <- requireNamespace("glmGamPoi", quietly = TRUE)
have_edger <- requireNamespace("edgeR", quietly = TRUE)

## ------------------------------------------------------- production block

extract_fit_r <- function(path) {
  lines <- readLines(path, warn = FALSE)
  start <- grep('const _FIT_R = raw"""', lines, fixed = TRUE)
  if (length(start) != 1) stop("could not find exactly one _FIT_R block in ", path)
  rest <- lines[(start + 1):length(lines)]
  end <- which(rest == '"""')[1]
  if (is.na(end)) stop("_FIT_R block in ", path, " is not terminated")
  block <- paste(rest[seq_len(end - 1)], collapse = "\n")
  if (!grepl("da_result", block, fixed = TRUE) || !grepl("glm.nb", block, fixed = TRUE)) {
    stop("extracted _FIT_R does not look like the production fit loop")
  }
  block
}

fit_code <- extract_fit_r(args[["differential-jl"]])
fit_tmp <- tempfile()
writeLines(fit_code, fit_tmp)
fit_md5 <- file_md5(fit_tmp)
unlink(fit_tmp)
if (!have_mass_ns) fit_code <- gsub("MASS::", "", fit_code, fixed = TRUE)

# Every da_* global fit_nb sets or the block creates on the current branch
# (mirrors the cleanup list in differential.jl's fit_nb).
DA_VARS <- c("da_counts", "da_group", "da_levels", "da_offset", "da_theta_upper",
             "da_theta_lower", "da_use_gp", "da_g", "da_term", "da_n", "da_result",
             "da_phi", "da_gp_failed", "da_gp", "da_j", "da_y", "da_warns",
             "da_fit", "da_co", "da_row", "da_theta", "da_absent")

run_block <- function(counts, offset, use_gp, n_per) {
  g <- globalenv()
  assign("da_counts", counts, g)
  assign("da_group", rep(c("A", "B"), each = n_per), g)
  assign("da_levels", c("A", "B"), g)
  assign("da_offset", offset, g)
  assign("da_theta_upper", 1e7, g)
  assign("da_theta_lower", 1e-8, g)
  assign("da_use_gp", use_gp, g)
  on.exit(rm(list = intersect(ls(g), DA_VARS), envir = g))
  suppressWarnings(eval(parse(text = fit_code), envir = g))
  res <- get("da_result", envir = g)
  res
}

## ---------------------------------------------------------------- offsets
# Mirror src/analysis/differential.jl exactly: factors centred to geometric
# mean 1, offset = log(factor). RLE refuses (returns NULL) when no taxon is
# present in every sample, as rle_factors does; the refusal is recorded,
# never replaced by TSS.

geomean <- function(x) exp(mean(log(x)))

make_offset <- function(counts, method) {
  if (method == "tss") {
    lib <- rowSums(counts)
    if (any(lib <= 0)) return(NULL)
    return(log(lib / geomean(lib)))
  }
  if (method == "rle") {
    shared <- which(colSums(counts > 0) == nrow(counts))
    if (length(shared) == 0) return(NULL)
    sub <- counts[, shared, drop = FALSE]
    gm <- apply(sub, 2, geomean)
    raw <- apply(sub, 1, function(row) median(row / gm))
    return(log(raw / geomean(raw)))
  }
  stop("unknown offset method '", method, "'")
}

## ------------------------------------------------------------- simulation
# One dataset: samples x taxa integer counts plus the true log2 fold change
# per taxon (all zero under the null). Taxon parameters are redrawn per
# dataset, as in the #193 script. The data-generating library sizes are
# realisations, not observed library sizes: offsets are computed from the
# simulated counts afterwards, as production computes them from data.

simulate <- function(shape, n_per, n_taxa, truth, lfc) {
  n <- 2 * n_per
  mu <- switch(shape,
    original    = exp(runif(n_taxa, log(2), log(500))),
    constant    = exp(runif(n_taxa, log(2), log(500))),
    sparse      = exp(rnorm(n_taxa, mean = log(3), sd = 1.6)),
    unequal_lib = exp(runif(n_taxa, log(2), log(500))),
    stop("unknown shape '", shape, "'")
  )
  disp <- if (shape == "constant") rep(0.5, n_taxa) else 0.05 + 2 / sqrt(mu)
  lib <- exp(rnorm(n, 0, 0.3))
  if (shape == "unequal_lib") lib[(n_per + 1):n] <- lib[(n_per + 1):n] * 2.5
  true_lfc <- rep(0, n_taxa)
  if (truth == "power") {
    n_de <- max(1L, round(0.25 * n_taxa))
    de <- seq_len(n_de)
    true_lfc[de] <- rep(c(lfc, -lfc), length.out = n_de)
  }
  y <- vapply(seq_len(n_taxa), function(j) {
    m <- mu[j] * lib
    if (true_lfc[j] != 0) m[(n_per + 1):n] <- m[(n_per + 1):n] * 2^true_lfc[j]
    as.integer(rnbinom(n, mu = m, size = 1 / disp[j]))
  }, integer(n))
  storage.mode(y) <- "integer"
  # The #193 script's filter, kept so the replication is faithful: a taxon
  # needs reads in at least 2 samples and non-constant counts to be tested.
  keep <- colSums(y > 0) >= 2 & apply(y, 2, function(v) length(unique(v)) > 1)
  list(counts = y[, keep, drop = FALSE], true_lfc = true_lfc[keep],
       zero_frac = mean(y == 0))
}

## ------------------------------------------------------------ bench tests

# Production's per-taxon screens, applied to the bench-only tests so every
# test faces the same family: constant counts, and complete separation (no
# reads in any sample of one group). Returns "" when fittable.
screen <- function(yv, g) {
  if (length(unique(yv)) < 2L) return("constant counts")
  if (all(yv[g == "A"] == 0) || all(yv[g == "B"] == 0)) return("complete separation")
  ""
}

# Both model-preserving candidates are computed from ONE full glm.nb fit and,
# for lrt only, one intercept-only fit, so the two tests see identical fits and
# neither gets an easier dataset. ql_f uses the full fit's Pearson dispersion:
#   phi = sum(Pearson residuals^2) / residual df
#   F   = (beta / se)^2 / phi   against F(1, residual df)
# which is a quasi-likelihood F test with a tagwise (not empirical-Bayes)
# dispersion estimate. It is deliberately not described as edgeR's or
# glmGamPoi's QL test: both shrink phi across taxa, which this does not.
fit_nb_candidates <- function(counts, offset, n_per, want) {
  g <- factor(rep(c("A", "B"), each = n_per), levels = c("A", "B"))
  blank <- function() {
    out <- data.frame(status = "failed", pvalue = NA_real_)
    out <- out[rep(1, ncol(counts)), , drop = FALSE]
    rownames(out) <- NULL
    out
  }
  out <- setNames(lapply(want, function(t) blank()), want)
  one <- function(formula) {
    warns <- character(0)
    fit <- tryCatch(
      withCallingHandlers(glm_nb(formula, control = glm.control(maxit = 100)),
        warning = function(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") }),
      error = function(e) e)
    list(fit = fit, warns = warns)
  }
  bad_fit <- function(r) {
    inherits(r$fit, "error") || !isTRUE(r$fit[["converged"]]) ||
      !is.null(r$fit[["th.warn"]]) ||
      any(grepl("iteration limit|alternation limit|did not converge|NaNs produced", r$warns))
  }
  off <- offset
  for (j in seq_len(ncol(counts))) {
    yv <- counts[, j]
    if (nzchar(screen(yv, g))) next
    # glm.nb looks its variables up in the formula's environment; yv, g and
    # off all live in this frame (one()'s enclosing environment), which is
    # where these formulas are created.
    full <- one(yv ~ g + offset(off))
    if (bad_fit(full)) next
    if ("lrt" %in% want) {
      null <- one(yv ~ 1 + offset(off))
      if (!bad_fit(null)) {
        lr <- 2 * (as.numeric(logLik(full$fit)) - as.numeric(logLik(null$fit)))
        if (is.finite(lr) && lr >= 0) {
          p <- pchisq(lr, df = 1, lower.tail = FALSE)
          if (is.finite(p)) {
            out$lrt$status[j] <- "ok"
            out$lrt$pvalue[j] <- p
          }
        }
      }
    }
    if ("ql_f" %in% want) {
      co <- summary(full$fit, dispersion = 1)[["coefficients"]]
      idx <- match("gB", rownames(co))
      if (is.na(idx)) idx <- grep("^g", rownames(co))[1]
      dfr <- df.residual(full$fit)
      phi <- if (is.na(dfr) || dfr < 1) NA_real_ else
        sum(residuals(full$fit, type = "pearson")^2) / dfr
      if (!is.na(idx) && is.finite(phi) && phi > 0) {
        est <- co[idx, 1]
        se <- co[idx, 2]
        if (is.finite(est) && is.finite(se) && se > 0) {
          fstat <- (est / se)^2 / phi
          p <- pf(fstat, df1 = 1, df2 = dfr, lower.tail = FALSE)
          if (is.finite(p)) {
            out$ql_f$status[j] <- "ok"
            out$ql_f$pvalue[j] <- p
          }
        }
      }
    }
  }
  out
}

# Stable test identifiers are constants because they are used by the
# availability, failure-reporting, and result-assembly paths.
TEST_GLMGAMPOI_QL <- "glmgampoi_ql"
TEST_EDGER_QL <- "edger_ql"

# Both package tests return a data.frame whose p-value column is named by the
# package: glmGamPoi's test_de returns "pval", edgeR's topTags table returns
# "PValue". Resolve it case-insensitively; a missing column is an error in this
# file, not a data outcome.
loud_failure <- function(out, test, message) {
  cat("  ", test, "failed for every taxon: ", message, "\n", sep = "")
  out$note <- message
  out
}

p_value_column <- function(tbl, caller) {
  wanted <- c("pvalue", "p.value", "pval", "p_value")
  hit <- match(wanted, tolower(names(tbl)))
  hit <- hit[!is.na(hit)]
  if (length(hit) == 0) {
    stop(caller, " returned no p-value column; got: ", paste(names(tbl), collapse = ", "))
  }
  names(tbl)[hit[1]]
}

package_fit_result <- function(res, test, caller, screens, n_taxa, row_error) {
  out <- data.frame(status = rep("failed", n_taxa), pvalue = NA_real_,
                    note = NA_character_)
  if (inherits(res, "error")) {
    return(loud_failure(out, test, conditionMessage(res)))
  }
  pcol <- p_value_column(res, caller)
  if (length(res[[pcol]]) != n_taxa) {
    return(loud_failure(out, test, row_error))
  }
  p <- as.numeric(res[[pcol]])
  ok <- !screens & is.finite(p) & p >= 0 & p <= 1
  out$status[ok] <- "ok"
  out$pvalue[ok] <- p[ok]
  out
}

fit_glmgampoi_ql <- function(counts, offset, n_per) {
  g <- factor(rep(c("A", "B"), each = n_per), levels = c("A", "B"))
  screens <- vapply(seq_len(ncol(counts)),
                    function(j) nzchar(screen(counts[, j], g)), logical(1))
  res <- tryCatch(suppressWarnings({
    gp <- glmGamPoi::glm_gp(t(counts), design = model.matrix(~ g),
                            size_factors = exp(offset),
                            overdispersion_shrinkage = TRUE)
    # Numeric contrast weights on the design columns ((Intercept), gB):
    # test_de parses a TEXT contrast as R code, so bench and production alike
    # must never hand it a label.
    #
    # No sort_by argument. test_de's sort_by names a COLUMN to sort by, or
    # NULL for input order; the string "none" is neither, so passing it makes
    # test_de error on every call. Rows then keep input order, which is what
    # the taxon-by-taxon comparison below assumes.
    glmGamPoi::test_de(gp, contrast = c(0, 1))
  }), error = function(e) e)
  package_fit_result(res, TEST_GLMGAMPOI_QL, "glmGamPoi::test_de", screens,
                    ncol(counts), "test_de returned the wrong number of rows")
}

fit_edger_ql <- function(counts, offset, n_per) {
  g <- factor(rep(c("A", "B"), each = n_per), levels = c("A", "B"))
  screens <- vapply(seq_len(ncol(counts)),
                    function(j) nzchar(screen(counts[, j], g)), logical(1))
  res <- tryCatch(suppressWarnings({
    y <- edgeR::DGEList(counts = t(counts), group = g)
    # Feed edgeR the bench offset rather than its own normalisation, so all
    # tests see the same library-size handling: effective library size
    # proportional to exp(offset).
    y$samples$lib.size <- exp(offset) * geomean(rowSums(counts))
    y$samples$norm.factors <- 1
    design <- model.matrix(~ g)
    y <- edgeR::estimateDisp(y, design)
    fit <- edgeR::glmQLFit(y, design)
    qlf <- edgeR::glmQLFTest(fit, coef = 2)
    edgeR::topTags(qlf, n = Inf, sort.by = "none")$table
  }), error = function(e) e)
  package_fit_result(res, TEST_EDGER_QL, "edgeR::topTags", screens,
                    ncol(counts), "topTags returned the wrong number of rows")
}

RESULT_COLUMNS <- c("truth", "shape", "offset", "n_per", "taxa", "sim",
                    "taxon", "true_log2fc", "test", "status", "pvalue", "note")

report_cell_failures <- function(results_file, cell) {
  if (!file.exists(results_file)) return(invisible(NULL))
  cell_rows <- tryCatch(read.csv(results_file, stringsAsFactors = FALSE,
                                 check.names = FALSE, fill = FALSE),
                        error = function(e) e)
  if (inherits(cell_rows, "error")) {
    stop("cell ", cell, " has an unreadable result CSV (",
         conditionMessage(cell_rows), ")", call. = FALSE)
  }
  if (!identical(names(cell_rows), RESULT_COLUMNS)) {
    stop("cell ", cell, " has an incompatible result CSV schema", call. = FALSE)
  }
  if (nrow(cell_rows) == 0) return(invisible(NULL))
  for (test_name in unique(cell_rows$test)) {
    test_rows <- cell_rows[cell_rows$test == test_name, , drop = FALSE]
    if (any(!is.na(test_rows$pvalue))) next
    reasons <- if ("note" %in% names(test_rows)) {
      unique(stats::na.omit(test_rows$note))
    } else {
      character(0)
    }
    reason <- if (length(reasons)) paste0(": ", paste(reasons, collapse = "; ")) else ""
    cat(sprintf("WARNING %s: test %s produced no p-value in this cell%s\n",
                cell, test_name, reason))
  }
  invisible(NULL)
}

validate_resume_cell <- function(results_file, provenance_file, cell, cell_key) {
  if (!file.exists(results_file)) return(integer(0))
  prev <- tryCatch(read.csv(results_file, stringsAsFactors = FALSE,
                            check.names = FALSE, fill = FALSE),
                   error = function(e) e)
  if (inherits(prev, "error")) {
    stop("cell ", cell, " has an unreadable CSV (", conditionMessage(prev),
         "); delete ", results_file, " and ", provenance_file,
         " before rerunning", call. = FALSE)
  }
  if (!identical(names(prev), RESULT_COLUMNS)) {
    stop("cell ", cell, " has an incompatible CSV schema; expected ",
         paste(RESULT_COLUMNS, collapse = ", "), " but found ",
         paste(names(prev), collapse = ", "), "; delete ", results_file,
         " and ", provenance_file, " before rerunning", call. = FALSE)
  }
  if (!file.exists(provenance_file)) {
    stop("cell ", cell, " has rows but no provenance file; delete ",
         results_file, " before rerunning", call. = FALSE)
  }
  old_key <- tryCatch(
    grep("^cell key:", readLines(provenance_file, warn = FALSE), value = TRUE),
    error = function(e) e)
  if (inherits(old_key, "error")) {
    stop("cell ", cell, " has unreadable provenance (", conditionMessage(old_key),
         "); delete ", results_file, " and ", provenance_file,
         " before rerunning", call. = FALSE)
  }
  if (length(old_key) != 1L) {
    stop("cell ", cell, " provenance must contain exactly one cell key; delete ",
         results_file, " and ", provenance_file, " before rerunning", call. = FALSE)
  }
  old_key_value <- trimws(sub("^cell key:[ ]*", "", old_key[1]))
  if (!identical(old_key_value, as.character(cell_key))) {
    stop("cell ", cell, " has a mismatched cell key (found ", old_key_value,
         ", expected ", cell_key, "); delete ", results_file, " and ",
         provenance_file, " before rerunning", call. = FALSE)
  }
  unique(as.integer(prev$sim[!is.na(prev$sim)]))
}

write_cell_rows <- function(rows, results_file, header_done) {
  if (!identical(names(rows), RESULT_COLUMNS)) {
    stop("cell result rows do not match the expected CSV schema", call. = FALSE)
  }
  # Package error messages can contain commas, quotes, or newlines. Use RFC-style
  # double-quote escaping so R and the workflow's CSV reader preserve each field.
  write.table(rows, results_file, sep = ",", row.names = FALSE,
              col.names = !header_done, append = header_done, quote = TRUE,
              qmethod = "double")
}

## ------------------------------------------------------------------- main

enabled <- want
for (t in want) {
  if (t %in% c("wald_trend", TEST_GLMGAMPOI_QL) && !have_gp) {
    cat("SKIPPED test", t, ": glmGamPoi is not available in this R library\n")
    enabled <- setdiff(enabled, t)
  }
  if (t == TEST_EDGER_QL && !have_edger) {
    cat("SKIPPED test edger_ql: edgeR is not available in this R library\n")
    enabled <- setdiff(enabled, t)
  }
}
if (length(enabled) == 0) stop("no requested test can run in this R library")

# A cell's datasets must not depend on which cells were requested in this
# invocation, or in what order. The per-sim seed is therefore hashed from the
# cell's identity string (previously it used the cell's index, so splitting a
# grid across processes silently changed every dataset).
stable_key <- function(x) {
  h <- 0
  for (ch in utf8ToInt(x)) h <- (h * 131 + ch) %% 1000003
  h
}

for (shape in shapes) for (off_m in offsets) for (n_per in n_pers) {
  # The taxa count is part of the cell identity: reruns append to a cell's
  # CSV, so two settings must never share a file by accident.
  cell <- sprintf("%s_%s_%s_n%d_t%d%s", truth, shape, off_m, n_per, n_taxa,
                  if (truth == "power") sprintf("_lfc%s", lfc) else "")
  f <- file.path(out_dir, paste0("pvalues_", cell, ".csv"))
  prov <- file.path(out_dir, paste0("provenance_", cell, ".txt"))
  provenance_lines <- c(
    paste("cell:", cell), paste("date:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    paste("args:", paste(argv, collapse = " ")),
    paste("seed0:", seed0), paste("cell key:", stable_key(cell)),
    paste("executor:", if (nzchar(Sys.getenv("NB_EXECUTOR")))
             Sys.getenv("NB_EXECUTOR") else R.version.string),
    paste("calibration.R md5:", script_md5),
    paste("_FIT_R md5:", fit_md5),
    paste("MASS:", mass_mode),
    paste("glmGamPoi:", if (have_gp) as.character(packageVersion("glmGamPoi")) else "absent"),
    paste("edgeR:", if (have_edger) as.character(packageVersion("edgeR")) else "absent"),
    paste("tests run:", paste(enabled, collapse = ",")),
    capture.output(sessionInfo())
  )
  cat(sprintf("cell %s: %d sims x %d taxa, tests %s\n",
              cell, n_sims, n_taxa, paste(enabled, collapse = "+")))
  header_done <- file.exists(f)
  # Validate the existing schema and provenance before refreshing its record or
  # appending rows; unknown files cannot safely be resumed.
  done_sims <- validate_resume_cell(f, prov, cell, stable_key(cell))
  writeLines(provenance_lines, prov)
  skipped_sims <- 0L
  refused_offsets <- 0L
  if (length(done_sims)) cat(sprintf("  resuming: %d sims already present\n", length(done_sims)))
  for (s in setdiff(seq_len(n_sims), done_sims)) {
    # One seed per (cell, sim): cells can run in any order, in parallel
    # processes, and reproduce dataset-for-dataset.
    set.seed(as.integer((seed0 + stable_key(cell) * 1000003 + s) %% 2147483647))
    sim <- simulate(shape, n_per, n_taxa, truth, lfc)
    counts <- sim$counts
    if (ncol(counts) < 5) { skipped_sims <- skipped_sims + 1L; next }
    offset <- make_offset(counts, off_m)
    if (is.null(offset)) { refused_offsets <- refused_offsets + 1L; next }
    fits <- list()
    if ("wald_ml" %in% enabled) {
      r <- run_block(counts, offset, FALSE, n_per)
      fits$wald_ml <- data.frame(status = r$status, pvalue = r$pvalue)
    }
    if ("wald_trend" %in% enabled) {
      r <- run_block(counts, offset, TRUE, n_per)
      fits$wald_trend <- data.frame(status = r$status, pvalue = r$pvalue)
    }
    nb_want <- intersect(c("lrt", "ql_f"), enabled)
    if (length(nb_want) > 0) {
      nb <- fit_nb_candidates(counts, offset, n_per, nb_want)
      for (t in names(nb)) fits[[t]] <- nb[[t]]
    }
    if (TEST_GLMGAMPOI_QL %in% enabled) {
      fits[[TEST_GLMGAMPOI_QL]] <- fit_glmgampoi_ql(counts, offset, n_per)
    }
    if (TEST_EDGER_QL %in% enabled) {
      fits[[TEST_EDGER_QL]] <- fit_edger_ql(counts, offset, n_per)
    }
    rows <- do.call(rbind, lapply(names(fits), function(t) {
      f <- fits[[t]]
      note <- if ("note" %in% names(f)) f$note else rep(NA_character_, nrow(f))
      data.frame(truth = truth, shape = shape, offset = off_m, n_per = n_per,
                 taxa = n_taxa, sim = s, taxon = seq_len(ncol(counts)),
                 true_log2fc = sim$true_lfc, test = t,
                 status = f$status, pvalue = f$pvalue, note = note,
                 stringsAsFactors = FALSE)
    }))
    write_cell_rows(rows, f, header_done)
    header_done <- TRUE
    if (s %% 25 == 0) { cat(sprintf("  %s sim %d/%d\n", cell, s, n_sims)); flush.console() }
  }
  cat(sprintf("cell %s done: %d sims skipped (<5 testable taxa), %d offsets refused\n",
              cell, skipped_sims, refused_offsets))
  # A requested test with no usable p-value is a broken package path, not a
  # data outcome. Report the reason without adding control-flow nesting here.
  report_cell_failures(f, cell)
}
cat("calibration run complete\n")
