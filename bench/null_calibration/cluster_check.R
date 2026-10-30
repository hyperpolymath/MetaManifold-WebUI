#!/usr/bin/env Rscript
# SPDX-License-Identifier: AGPL-3.0-only
# Simulation-clustered uncertainty for null-calibration benchmark CSVs.
# Uses base R and the pinned scientific R runtime; no Python or new packages.

required_columns <- c("sim", "test", "taxon", "status", "pvalue", "true_log2fc")

read_cluster_csv <- function(connection) {
  df <- utils::read.csv(connection, colClasses = "character",
                        check.names = FALSE, na.strings = NULL)
  missing <- setdiff(required_columns, names(df))
  if (length(missing)) {
    stop("missing required CSV columns: ", paste(missing, collapse = ", "))
  }
  if (!nrow(df)) stop("no method records in CSV")
  for (key in c("sim", "test", "taxon")) {
    if (anyNA(df[[key]]) || any(!nzchar(df[[key]]))) {
      stop("missing ", key, " identifier")
    }
  }
  if (anyDuplicated(df[c("test", "sim", "taxon")])) {
    stop("duplicated (test, sim, taxon) row")
  }
  truth <- suppressWarnings(as.numeric(df$true_log2fc))
  if (anyNA(truth) || any(!is.finite(truth))) {
    stop("invalid or non-finite true_log2fc")
  }
  df$.is_null <- truth == 0
  df
}

summarise_method <- function(df, method, alpha, min_clusters) {
  # Register all observed methods before filtering, including all-nonnull ones.
  subject <- df[df$test == method & df$.is_null, , drop = FALSE]
  if (!nrow(subject)) stop(method, ": no null observations")
  if (any(!subject$status %in% c("ok", "boundary", "failed"))) {
    stop(method, ": unknown fit status")
  }
  valid <- subject$status %in% c("ok", "boundary")
  p <- rep(NA_real_, nrow(subject))
  p[valid] <- suppressWarnings(as.numeric(subject$pvalue[valid]))
  if (anyNA(p[valid]) || any(!is.finite(p[valid])) ||
      any(p[valid] < 0 | p[valid] > 1)) {
    stop(method, ": valid fit has invalid p-value")
  }
  sim_ids <- unique(subject$sim)
  m <- length(sim_ids)
  if (m < min_clusters) {
    stop(method, ": only ", m, " independent simulation clusters; require ", min_clusters)
  }
  # Failed rows are included in the set of simulation clusters, but excluded
  # from the rejection-rate denominator, matching the benchmark report.
  groups <- split(seq_len(nrow(subject)), factor(subject$sim, levels = sim_ids))
  counts <- vapply(groups, function(idx) c(
    n = sum(valid[idx]),
    k = sum(valid[idx] & !is.na(p[idx]) & p[idx] < alpha)
  ), c(n = 0, k = 0))
  n_total <- sum(counts["n", ])
  k_total <- sum(counts["k", ])
  if (n_total == 0) stop(method, ": no valid null tests")
  rate <- k_total / n_total
  residual <- counts["k", ] - rate * counts["n", ]
  se <- sqrt(m / (m - 1) * sum(residual^2)) / n_total
  z95 <- stats::qnorm(0.975)
  data.frame(test = method, alpha = alpha, n_sims = m,
             n_pvalues = n_total, n_rejected = k_total, rate = rate,
             cluster_se = se, cluster_95_lo = max(0, rate - z95 * se),
             cluster_95_hi = min(1, rate + z95 * se))
}

analyse_rows <- function(df, alpha = 0.05, min_clusters = 30L) {
  if (length(alpha) != 1L || !is.finite(alpha) || alpha <= 0 || alpha >= 1) {
    stop("alpha must lie strictly between zero and one")
  }
  if (length(min_clusters) != 1L || !is.finite(min_clusters) ||
      min_clusters != as.integer(min_clusters) || min_clusters < 2L) {
    stop("at least two independent simulation clusters required")
  }
  if (!nrow(df)) stop("no method records in CSV")
  methods <- sort(unique(df$test))
  do.call(rbind, lapply(methods, function(method) {
    summarise_method(df, method, alpha, min_clusters)
  }))
}

cluster_sources <- function(paths) {
  sources <- list()
  for (path in paths) {
    if (grepl("\\.zip$", path, ignore.case = TRUE)) {
      members <- utils::unzip(path, list = TRUE)$Name
      members <- sort(members[grepl("pvalues_.*\\.csv$", basename(members))])
      if (!length(members)) stop(path, ": no pvalues_*.csv in ZIP")
      for (member in members) {
        sources[[length(sources) + 1L]] <- list(path = path, member = member)
      }
    } else {
      sources[[length(sources) + 1L]] <- list(path = path, member = NULL)
    }
  }
  sources
}

read_source <- function(source) {
  con <- if (is.null(source$member)) file(source$path, open = "r") else
    unz(source$path, source$member, open = "r")
  on.exit(close(con), add = TRUE)
  read_cluster_csv(con)
}

cluster_check <- function(paths, alpha = 0.05, min_clusters = 30L) {
  if (!length(paths)) stop("at least one input CSV or ZIP is required")
  chunks <- lapply(cluster_sources(paths), function(source) {
    result <- analyse_rows(read_source(source), alpha, min_clusters)
    origin <- if (is.null(source$member)) source$path else
      paste0(basename(source$path), "/", source$member)
    cbind(source = origin, result)
  })
  do.call(rbind, chunks)
}

parse_cluster_args <- function(args) {
  alpha <- 0.05
  min_clusters <- 30L
  files <- character()
  for (arg in args) {
    if (startsWith(arg, "--alpha=")) {
      alpha <- suppressWarnings(as.numeric(sub("^--alpha=", "", arg)))
    } else if (startsWith(arg, "--min-clusters=")) {
      min_clusters <- suppressWarnings(as.numeric(sub("^--min-clusters=", "", arg)))
    } else if (startsWith(arg, "-")) {
      stop("unknown option: ", arg)
    } else {
      files <- c(files, arg)
    }
  }
  list(files = files, alpha = alpha, min_clusters = min_clusters)
}

if (sys.nframe() == 0L) {
  arguments <- parse_cluster_args(commandArgs(trailingOnly = TRUE))
  result <- cluster_check(arguments$files, arguments$alpha, arguments$min_clusters)
  utils::write.table(result, file = stdout(), sep = ",", row.names = FALSE,
                     col.names = TRUE, quote = TRUE, na = "")
}
