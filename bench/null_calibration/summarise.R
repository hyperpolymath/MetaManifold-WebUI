#!/usr/bin/env Rscript
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Aggregate calibration.R's per-cell p-value CSVs into the #193 summary
# tables. Base R only, so it runs anywhere calibration.R's output lands.
#
#   Rscript bench/null_calibration/summarise.R \
#       --results=bench/null_calibration/results/raw \
#       --out=bench/null_calibration/results
#
# Writes calibration_summary.csv (one row per cell x test: rejection rates
# at alpha = 0.01/0.05/0.10 with Wilson 95% intervals, Kolmogorov-Smirnov D
# and p against Uniform(0,1), fit-failure share) and, when power cells are
# present, power_summary.csv (raw and BH power on truly-changed taxa, and
# the Benjamini-Hochberg false discovery rate at 0.05 averaged per dataset).
#
# A "test" here is one taxon in one simulated dataset that produced a
# p-value (production's BH family: status ok or boundary). Failures are
# counted separately and never enter a rate's denominator silently: every
# row reports both n_pvalues and n_failed.

argv <- commandArgs(trailingOnly = TRUE)
if (length(argv) == 0 && nzchar(Sys.getenv("NB_CALIB_ARGS"))) {
  argv <- strsplit(trimws(Sys.getenv("NB_CALIB_ARGS")), "\\s+")[[1]]
}
args <- list()
for (a in argv) {
  if (!grepl("^--[a-z0-9-]+=", a)) stop("unrecognised argument '", a, "' (want --key=value)")
  kv <- strsplit(sub("^--", "", a), "=", fixed = TRUE)[[1]]
  args[[kv[1]]] <- paste(kv[-1], collapse = "=")
}
results_dir <- if (!is.null(args$results)) args$results else
  file.path("bench", "null_calibration", "results", "raw")
out_dir <- if (!is.null(args$out)) args$out else
  file.path("bench", "null_calibration", "results")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

files <- list.files(results_dir, pattern = "^pvalues_.*[.]csv$", full.names = TRUE)
if (length(files) == 0) stop("no pvalues_*.csv under ", results_dir)
dat <- do.call(rbind, lapply(files, function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE)
  d$file <- basename(f)
  d
}))
if (!"taxa" %in% names(dat)) dat$taxa <- NA_integer_
dat$has_p <- !is.na(dat$pvalue) & dat$status %in% c("ok", "boundary")

# Wilson score interval for k/n at 95% (the same interval prop.test uses
# without continuity correction, written out so the bench needs nothing
# beyond base R distributions).
wilson <- function(k, n) {
  if (n == 0) return(c(NA_real_, NA_real_, NA_real_))
  z <- qnorm(0.975)
  p <- k / n
  den <- 1 + z^2 / n
  mid <- (p + z^2 / (2 * n)) / den
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / den
  c(p, max(0, mid - half), min(1, mid + half))
}

key_of <- function(d) paste(d$truth, d$shape, d$offset, d$n_per, d$taxa, d$test, sep = "|")
groups <- split(dat, key_of(dat))

summ_rows <- lapply(groups, function(d) {
  p <- d$pvalue[d$has_p]
  # Under a power cell only the truly-null taxa calibrate the test.
  p_null <- d$pvalue[d$has_p & d$true_log2fc == 0]
  ks <- if (length(p_null) >= 10) {
    k <- suppressWarnings(ks.test(p_null, "punif"))
    c(unname(k$statistic), k$p.value)
  } else c(NA_real_, NA_real_)
  w <- function(alpha) wilson(sum(p_null < alpha), length(p_null))
  w01 <- w(0.01); w05 <- w(0.05); w10 <- w(0.10)
  data.frame(
    truth = d$truth[1], shape = d$shape[1], offset = d$offset[1],
    n_per_group = d$n_per[1], n_taxa_setting = d$taxa[1], test = d$test[1],
    n_sims = length(unique(d$sim)), n_attempted = nrow(d),
    n_pvalues = length(p), n_failed = sum(d$status == "failed"),
    n_boundary = sum(d$status == "boundary"),
    fail_rate = sum(d$status == "failed") / nrow(d),
    rate_01 = w01[1], rate_01_lo = w01[2], rate_01_hi = w01[3],
    rate_05 = w05[1], rate_05_lo = w05[2], rate_05_hi = w05[3],
    rate_10 = w10[1], rate_10_lo = w10[2], rate_10_hi = w10[3],
    ks_D = ks[1], ks_p = ks[2], mean_p_null = if (length(p_null)) mean(p_null) else NA_real_,
    stringsAsFactors = FALSE
  )
})
summary_df <- do.call(rbind, summ_rows)
summary_df <- summary_df[order(summary_df$truth, summary_df$shape, summary_df$offset,
                               summary_df$n_per_group, summary_df$test), ]
write.csv(summary_df, file.path(out_dir, "calibration_summary.csv"), row.names = FALSE)
cat(sprintf("wrote %s (%d rows)\n", file.path(out_dir, "calibration_summary.csv"), nrow(summary_df)))

pow <- dat[dat$truth == "power", , drop = FALSE]
if (nrow(pow) > 0) {
  pow$padj <- NA_real_
  # BH within each simulated dataset and test, over that dataset's tested
  # family - the same family production adjusts over.
  fams <- split(seq_len(nrow(pow)),
                paste(pow$file, pow$sim, pow$test, sep = "|"))
  for (idx in fams) {
    fam <- idx[pow$has_p[idx]]
    if (length(fam) > 0) pow$padj[fam] <- p.adjust(pow$pvalue[fam], method = "BH")
  }
  pg <- split(pow, key_of(pow))
  prows <- lapply(pg, function(d) {
    de <- d[d$true_log2fc != 0 & d$has_p, , drop = FALSE]
    by_sim <- split(d, d$sim)
    fdp <- vapply(by_sim, function(s) {
      disc <- s$has_p & !is.na(s$padj) & s$padj < 0.05
      if (!any(disc)) 0 else mean(s$true_log2fc[disc] == 0)
    }, numeric(1))
    data.frame(
      shape = d$shape[1], offset = d$offset[1], n_per_group = d$n_per[1],
      test = d$test[1], n_sims = length(by_sim),
      power_raw_05 = if (nrow(de)) mean(de$pvalue < 0.05) else NA_real_,
      power_bh_05 = if (nrow(de)) mean(!is.na(de$padj) & de$padj < 0.05) else NA_real_,
      bh_fdr_05 = mean(fdp),
      mean_discoveries = mean(vapply(by_sim, function(s)
        sum(s$has_p & !is.na(s$padj) & s$padj < 0.05), numeric(1))),
      stringsAsFactors = FALSE
    )
  })
  power_df <- do.call(rbind, prows)
  power_df <- power_df[order(power_df$shape, power_df$offset,
                             power_df$n_per_group, power_df$test), ]
  write.csv(power_df, file.path(out_dir, "power_summary.csv"), row.names = FALSE)
  cat(sprintf("wrote %s (%d rows)\n", file.path(out_dir, "power_summary.csv"), nrow(power_df)))
}
cat("summarise complete\n")
