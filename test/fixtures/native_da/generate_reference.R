# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: MPL-2.0
#
# Reference values for the native ALDEx2 and ANCOM-BC methods.
#
# Run with R 4.5.0 and Bioconductor 3.22 (ALDEx2, ANCOMBC), from the repository
# root:  Rscript test/fixtures/native_da/generate_reference.R
#
# This script is not part of the application and these packages are not in
# renv.lock: the application fits both methods in Julia (CompositionalDA), and
# R is used here only to produce the numbers the Julia fit is compared with.
# Writes, next to this file:
#   counts.csv           the input (samples x taxa) and group labels
#   aldex2_reference.csv ALDEx2::aldex, mean over `reps` runs plus the spread
#   ancombc_reference.csv ANCOMBC::ancombc, deterministic
#   versions.txt         R and package versions that produced them

suppressMessages({
  library(ALDEx2)
  library(ANCOMBC)
  library(TreeSummarizedExperiment)
})

here <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
if (is.na(here) || here == "") here <- "test/fixtures/native_da"

## Input: 8 + 8 samples, 12 taxa. Taxa 1-3 are higher in group B, 4-6 lower,
## 7-10 unchanged, taxon 11 is absent from group A (structural zero in A), and
## taxon 12 is rare and unchanged.
set.seed(20260101)
n <- 8L
group <- rep(c("A", "B"), each = n)
base <- c(200, 150, 120, 300, 220, 160, 400, 250, 180, 90, 0, 30)
lfc  <- c(1.2, 1.0, 0.8, -1.0, -0.9, -0.7, 0, 0, 0, 0, 0, 0)
mu <- outer(rep(1, 2 * n), base) * exp(outer(group == "B", lfc))
mu[group == "A", 11] <- 0
mu[group == "B", 11] <- 60
lib <- exp(rnorm(2 * n, 0, 0.3))
counts <- matrix(rnbinom(length(mu), mu = mu * lib, size = 20), nrow = 2 * n)
counts[group == "A", 11] <- 0L
storage.mode(counts) <- "integer"
rownames(counts) <- sprintf("s%02d", seq_len(2 * n))
colnames(counts) <- sprintf("taxon%02d", seq_len(ncol(counts)))
write.csv(data.frame(sample = rownames(counts), group = group, counts,
                     check.names = FALSE),
          file.path(here, "counts.csv"), row.names = FALSE, quote = FALSE)

## ALDEx2: Monte Carlo, so run it with several seeds. The native fit draws from
## its own stream, so the value that can be compared is the expectation, and
## the spread across R seeds says how close two correct runs are expected to be.
mc <- 128L
reps <- 25L
runs <- lapply(seq_len(reps), function(s) {
  set.seed(1000 + s)
  ALDEx2::aldex(t(counts), group, mc.samples = mc, test = "t", effect = TRUE,
                denom = "all", verbose = FALSE)
})
stack <- function(col, f = identity) sapply(runs, function(r) f(r[colnames(counts), col]))
## Effects are compared as they are; p-values and BH values on the log10 scale,
## where their Monte Carlo error is roughly symmetric, with a floor of 1e-10.
cols <- c("diff.btw", "diff.win", "effect", "rab.all")
pcols <- c("we.ep", "we.eBH", "wi.ep", "wi.eBH")
ald <- data.frame(feature = colnames(counts))
add <- function(name, m) {
  ald[[name]] <<- rowMeans(m)
  ald[[paste0(name, "_range")]] <<- apply(m, 1, function(v) diff(range(v)))
}
for (col in cols) add(col, stack(col))
P_FLOOR <- 1e-10  # p-values below this are not resolved by the Monte Carlo draw
for (col in pcols) add(paste0("log10_", col), stack(col, function(p) log10(pmax(p, P_FLOOR))))
write.csv(ald, file.path(here, "aldex2_reference.csv"), row.names = FALSE)

## ANCOM-BC (two-group model, deterministic).
tse <- TreeSummarizedExperiment(
  assays = list(counts = t(counts)),
  colData = S4Vectors::DataFrame(group = factor(group, levels = c("A", "B")),
                                 row.names = rownames(counts)))
fit <- ANCOMBC::ancombc(data = tse, assay_name = "counts", tax_level = NULL,
  formula = "group", p_adj_method = "BH", prv_cut = 0, lib_cut = 0,
  group = "group", struc_zero = TRUE, neg_lb = FALSE, tol = 1e-5,
  max_iter = 100, conserve = TRUE, alpha = 0.05, global = FALSE)
res <- fit$res
sz <- fit$zero_ind
stopifnot(identical(res$lfc$taxon, sz$taxon))
col <- function(df) as.numeric(df[["groupB"]])
anc <- data.frame(
  feature = res$lfc$taxon,
  beta = col(res$lfc), se = col(res$se), w = col(res$W),
  p = col(res$p_val), q = col(res$q_val),
  zero_A = sz[[2]], zero_B = sz[[3]])
write.csv(anc, file.path(here, "ancombc_reference.csv"), row.names = FALSE)

writeLines(c(R.version.string,
             paste("Bioconductor", as.character(BiocManager::version())),
             paste("ALDEx2", as.character(packageVersion("ALDEx2"))),
             paste("ANCOMBC", as.character(packageVersion("ANCOMBC"))),
             paste("aldex2 mc.samples", mc, "reps", reps)),
           file.path(here, "versions.txt"))
