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
               offsets = "tss", tests = "wald_ml,lrt", truth = "null",
               log2fc = "1", seed = "20261020"),
  full  = list(`n-per` = "3,4,6,8,12,20", sims = "1000", taxa = "40",
               shapes = "original,constant,sparse,unequal_lib",
               offsets = "tss,rle",
               tests = "wald_ml,wald_trend,lrt,glmgampoi_ql,edger_ql",
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

fit_lrt <- function(counts, offset, n_per) {
  g <- factor(rep(c("A", "B"), each = n_per), levels = c("A", "B"))
  out <- data.frame(status = "failed", pvalue = NA_real_)
  out <- out[rep(1, ncol(counts)), , drop = FALSE]
  rownames(out) <- NULL
  one <- function(formula, yv) {
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
    full <- one(yv ~ g + offset(off), yv)
    if (bad_fit(full)) next
    null <- one(yv ~ 1 + offset(off), yv)
    if (bad_fit(null)) next
    lr <- 2 * (as.numeric(logLik(full$fit)) - as.numeric(logLik(null$fit)))
    if (!is.finite(lr) || lr < 0) next
    p <- pchisq(lr, df = 1, lower.tail = FALSE)
    if (!is.finite(p)) next
    out$status[j] <- "ok"
    out$pvalue[j] <- p
  }
  out
}

fit_glmgampoi_ql <- function(counts, offset, n_per) {
  g <- factor(rep(c("A", "B"), each = n_per), levels = c("A", "B"))
  out <- data.frame(status = rep("failed", ncol(counts)), pvalue = NA_real_)
  screens <- vapply(seq_len(ncol(counts)),
                    function(j) nzchar(screen(counts[, j], g)), logical(1))
  res <- tryCatch(suppressWarnings({
    gp <- glmGamPoi::glm_gp(t(counts), design = model.matrix(~ g),
                            size_factors = exp(offset),
                            overdispersion_shrinkage = TRUE)
    # Numeric contrast weights on the design columns ((Intercept), gB):
    # test_de parses a TEXT contrast as R code, so bench and production
    # alike must never hand it a label.
    glmGamPoi::test_de(gp, contrast = c(0, 1), sort_by = "none")
  }), error = function(e) e)
  if (inherits(res, "error")) return(out)
  pcol <- intersect(c("pval", "pvalue", "p_value"), names(res))[1]
  if (is.na(pcol) || length(res[[pcol]]) != ncol(counts)) return(out)
  p <- as.numeric(res[[pcol]])
  ok <- !screens & is.finite(p) & p >= 0 & p <= 1
  out$status[ok] <- "ok"
  out$pvalue[ok] <- p[ok]
  out
}

fit_edger_ql <- function(counts, offset, n_per) {
  g <- factor(rep(c("A", "B"), each = n_per), levels = c("A", "B"))
  out <- data.frame(status = rep("failed", ncol(counts)), pvalue = NA_real_)
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
  if (inherits(res, "error")) return(out)
  pcol <- intersect(c("pvalue", "p.value", "pvalue"), names(res))[1]
  if (is.na(pcol) || length(res[[pcol]]) != ncol(counts)) return(out)
  p <- as.numeric(res[[pcol]])
  ok <- !screens & is.finite(p) & p >= 0 & p <= 1
  out$status[ok] <- "ok"
  out$pvalue[ok] <- p[ok]
  out
}

## ------------------------------------------------------------------- main

enabled <- want
for (t in want) {
  if (t %in% c("wald_trend", "glmgampoi_ql") && !have_gp) {
    cat("SKIPPED test", t, ": glmGamPoi is not available in this R library\n")
    enabled <- setdiff(enabled, t)
  }
  if (t == "edger_ql" && !have_edger) {
    cat("SKIPPED test edger_ql: edgeR is not available in this R library\n")
    enabled <- setdiff(enabled, t)
  }
}
if (length(enabled) == 0) stop("no requested test can run in this R library")

cell_index <- 0L
for (shape in shapes) for (off_m in offsets) for (n_per in n_pers) {
  cell_index <- cell_index + 1L
  # The taxa count is part of the cell identity: reruns append to a cell's
  # CSV, so two settings must never share a file by accident.
  cell <- sprintf("%s_%s_%s_n%d_t%d%s", truth, shape, off_m, n_per, n_taxa,
                  if (truth == "power") sprintf("_lfc%s", lfc) else "")
  f <- file.path(out_dir, paste0("pvalues_", cell, ".csv"))
  prov <- file.path(out_dir, paste0("provenance_", cell, ".txt"))
  writeLines(c(
    paste("cell:", cell), paste("date:", format(Sys.time(), tz = "UTC", usetz = TRUE)),
    paste("args:", paste(argv, collapse = " ")),
    paste("MASS:", mass_mode),
    paste("glmGamPoi:", if (have_gp) as.character(packageVersion("glmGamPoi")) else "absent"),
    paste("edgeR:", if (have_edger) as.character(packageVersion("edgeR")) else "absent"),
    paste("tests run:", paste(enabled, collapse = ",")),
    capture.output(sessionInfo())
  ), prov)
  cat(sprintf("cell %s: %d sims x %d taxa, tests %s\n",
              cell, n_sims, n_taxa, paste(enabled, collapse = "+")))
  header_done <- file.exists(f)
  skipped_sims <- 0L
  refused_offsets <- 0L
  for (s in seq_len(n_sims)) {
    # One seed per (cell, sim): cells can run in any order, in parallel
    # processes, and reproduce dataset-for-dataset.
    set.seed(seed0 + cell_index * 1000003L + s)
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
    if ("lrt" %in% enabled) fits$lrt <- fit_lrt(counts, offset, n_per)
    if ("glmgampoi_ql" %in% enabled) fits$glmgampoi_ql <- fit_glmgampoi_ql(counts, offset, n_per)
    if ("edger_ql" %in% enabled) fits$edger_ql <- fit_edger_ql(counts, offset, n_per)
    rows <- do.call(rbind, lapply(names(fits), function(t) {
      data.frame(truth = truth, shape = shape, offset = off_m, n_per = n_per,
                 taxa = n_taxa, sim = s, taxon = seq_len(ncol(counts)),
                 true_log2fc = sim$true_lfc, test = t,
                 status = fits[[t]]$status, pvalue = fits[[t]]$pvalue,
                 stringsAsFactors = FALSE)
    }))
    write.table(rows, f, sep = ",", row.names = FALSE,
                col.names = !header_done, append = header_done, quote = FALSE)
    header_done <- TRUE
    if (s %% 25 == 0) { cat(sprintf("  %s sim %d/%d\n", cell, s, n_sims)); flush.console() }
  }
  cat(sprintf("cell %s done: %d sims skipped (<5 testable taxa), %d offsets refused\n",
              cell, skipped_sims, refused_offsets))
}
cat("calibration run complete\n")
