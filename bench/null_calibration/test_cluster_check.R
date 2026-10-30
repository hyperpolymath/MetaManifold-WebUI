#!/usr/bin/env Rscript
# SPDX-License-Identifier: AGPL-3.0-only
# Base R regression and planted-error controls for cluster_check.R.
source("bench/null_calibration/cluster_check.R")

must_fail <- function(expr, pattern) {
  err <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  stopifnot(!is.null(err), grepl(pattern, err, fixed = TRUE))
}
from_text <- function(text) read_cluster_csv(textConnection(text))
header <- "sim,test,taxon,status,pvalue,true_log2fc\n"
run_rows <- function(records, alpha = 0.05, min_clusters = 2L) {
  analyse_rows(from_text(paste0(header, records)), alpha, min_clusters)
}

# Correlated taxa are one dataset each; cluster-aware SE is 0.5 here.
x <- run_rows(paste0("1,wald,1,ok,0.01,0\n1,wald,2,ok,0.02,0\n",
                    "2,wald,1,ok,0.60,0\n2,wald,2,ok,0.90,0\n"))
stopifnot(x$n_sims == 2L, x$n_pvalues == 4, x$n_rejected == 2,
          abs(x$rate - 0.5) < 1e-12, abs(x$cluster_se - 0.5) < 1e-12,
          x$cluster_95_lo == 0, x$cluster_95_hi == 1)

# Unequal group sizes distinguish pooled K/N from the average cluster rate.
x <- run_rows(paste0("1,wald,1,ok,0.01,0\n",
                    "2,wald,1,ok,0.6,0\n2,wald,2,ok,0.9,0\n",
                    "2,wald,3,ok,0.7,0\n"))
stopifnot(x$n_sims == 2L, x$n_pvalues == 4, x$n_rejected == 1,
          abs(x$rate - 0.25) < 1e-12)

# Failures and nonnull inputs do not contribute to the rejection denominator.
x <- run_rows(paste0("1,m,1,ok,0.01,0\n1,m,2,failed,,0\n",
                    "2,m,1,ok,0.02,1\n2,m,2,boundary,0.90,0\n"))
stopifnot(x$n_sims == 2L, x$n_pvalues == 2, x$n_rejected == 1)

must_fail(from_text("sim,test,status,pvalue,true_log2fc\n1,m,ok,0.01,0\n"),
          "taxon")
must_fail(run_rows("1,m,,ok,0.01,0\n"), "missing taxon")
must_fail(run_rows("1,m,1,ok,0.01,0\n1,m,1,ok,0.02,0\n"), "duplicated")
for (val in c("NaN", "Inf", "-Inf", "missing")) {
  must_fail(run_rows(paste0("1,m,1,ok,0.01,", val, "\n")), "true_log2fc")
}
must_fail(run_rows("1,m,1,ok,,0\n"), "invalid p-value")
must_fail(run_rows("1,m,1,ok,0.01,1\n"), "no null observations")
must_fail(run_rows(""), "no method records")
must_fail(run_rows(paste0("1,m,1,ok,0.01,0\n2,m,1,ok,0.03,0\n",
                          "1,other,1,ok,0.04,1\n")), "no null observations")
must_fail(run_rows("1,m,1,ok,0.01,0\n", min_clusters = 30), "independent simulation clusters")
must_fail(run_rows("1,m,1,ok,0.01,0\n", alpha = 1), "alpha")
must_fail(run_rows("1,m,1,ok,0.01,0\n", min_clusters = 1), "at least two")

# Machine-readable result carries non-default alpha.
tmp <- tempfile(fileext = ".csv")
writeLines(c(sub("\n$", "", header), "1,m,1,ok,0.08,0", "2,m,1,ok,0.5,0"), tmp)
x <- cluster_check(tmp, alpha = 0.1, min_clusters = 2L)
stopifnot(x$alpha == 0.1, x$n_rejected == 1L)
unlink(tmp)
cat("cluster_check.R: planted-valid and planted-invalid tests PASS\n")
