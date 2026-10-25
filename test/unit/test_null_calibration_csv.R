# Regression checks for the null-calibration CSV writer, resumer and warning readers.
# Run from the repository root: Rscript --vanilla test/unit/test_null_calibration_csv.R
expressions <- parse("bench/null_calibration/calibration.R")
wanted <- c("RESULT_COLUMNS", "report_cell_failures", "validate_resume_cell",
            "write_cell_rows")
loaded <- character()
for (expr in expressions) {
  if (is.call(expr) && identical(expr[[1]], as.name("<-")) &&
      is.symbol(expr[[2]]) && as.character(expr[[2]]) %in% wanted) {
    eval(expr)
    loaded <- c(loaded, as.character(expr[[2]]))
  }
}
stopifnot(setequal(loaded, wanted))

cell <- "null_original_tss_n4_t40_smoke"
double_quote <- intToUtf8(34)
note_multiline <- paste0("comma, quote ", double_quote, " and newline", intToUtf8(10), "continued")
note_control <- paste0("second reason 50% and newline", intToUtf8(10), "continued")
duplicate_test <- "duplicate_test"
failed_status <- "failed"
rows <- data.frame(
  truth = rep("null", 5), shape = rep("original", 5), offset = rep("tss", 5),
  n_per = rep(4L, 5), taxa = rep(40L, 5), sim = rep(1L, 5),
  taxon = seq_len(5), true_log2fc = rep(0, 5),
  test = c(duplicate_test, duplicate_test, duplicate_test, "missing_note", "ok_test"),
  status = c(failed_status, failed_status, failed_status, failed_status, "ok"),
  pvalue = c(NA_real_, NA_real_, NA_real_, NA_real_, 0.01),
  note = c(note_multiline, note_multiline, note_control, NA_character_, NA_character_),
  stringsAsFactors = FALSE
)
stopifnot(identical(names(rows), RESULT_COLUMNS))

csv_path <- tempfile(fileext = ".csv")
provenance_path <- tempfile(fileext = ".txt")
legacy_path <- tempfile(fileext = ".csv")
bad_csv_path <- tempfile(fileext = ".csv")
write_cell_rows(rows, csv_path, header_done = FALSE)
write_cell_rows(rows[1, , drop = FALSE], csv_path, header_done = TRUE)
round_trip <- read.csv(csv_path, stringsAsFactors = FALSE, check.names = FALSE, fill = FALSE)
stopifnot(nrow(round_trip) == nrow(rows) + 1L,
          identical(names(round_trip), RESULT_COLUMNS),
          identical(round_trip$note[1:3], c(note_multiline, note_multiline, note_control)),
          is.na(round_trip$note[4]), round_trip$status[5] == "ok")

# R's per-cell diagnostic reader must retain special characters, deduplicate
# repeated reasons, and still warn when a failed row has no note.
r_messages <- capture.output(report_cell_failures(csv_path, cell))
r_log <- paste(r_messages, collapse = "\n")
stopifnot(sum(grepl(paste0("WARNING ", cell, ": test ", duplicate_test),
                    r_messages, fixed = TRUE)) == 1L,
          grepl(note_multiline, r_log, fixed = TRUE),
          grepl(paste0("WARNING ", cell, ": test missing_note produced no p-value in this cell"),
                r_log, fixed = TRUE),
          !grepl("ok_test", r_log, fixed = TRUE))
file.create(bad_csv_path)
read_error <- tryCatch({
  report_cell_failures(bad_csv_path, cell)
  ""
}, error = function(e) conditionMessage(e))
stopifnot(grepl("unreadable result CSV", read_error, fixed = TRUE))

# The workflow calls this same CSV-aware Python reader. It emits distinct
# reasons once, skips NA notes and escapes annotation control characters.
python <- Sys.which("python3")
stopifnot(nzchar(python))
reader_script <- "bench/null_calibration/report_failures.py"
annotations <- suppressWarnings(system2(
  python,
  args = c(shQuote(reader_script), shQuote(cell)),
  stdout = TRUE, stderr = TRUE, stdin = csv_path
))
reader_status <- attr(annotations, "status")
expected_annotations <- c(
  paste0("::warning title=", cell,
         ": a requested test failed::", duplicate_test, " :: comma, quote ", double_quote,
         " and newline%0Acontinued"),
  paste0("::warning title=", cell,
         ": a requested test failed::", duplicate_test,
         " :: second reason 50%25 and newline%0Acontinued")
)
stopifnot(is.null(reader_status) || identical(reader_status, 0L),
          identical(unname(annotations), expected_annotations))

# Refuse legacy 11-column CSVs and mismatched provenance before any append.
legacy <- rows[, RESULT_COLUMNS[-length(RESULT_COLUMNS)], drop = FALSE]
write.table(legacy, legacy_path, sep = ",", row.names = FALSE, quote = TRUE,
            qmethod = "double")
writeLines("cell key: 123", provenance_path)
legacy_error <- tryCatch({
  validate_resume_cell(legacy_path, provenance_path, cell, 123)
  ""
}, error = function(e) conditionMessage(e))
stopifnot(grepl("incompatible CSV schema", legacy_error, fixed = TRUE),
          identical(validate_resume_cell(csv_path, provenance_path, cell, 123), 1L))

writeLines("cell key: 999", provenance_path)
key_error <- tryCatch({
  validate_resume_cell(csv_path, provenance_path, cell, 123)
  ""
}, error = function(e) conditionMessage(e))
stopifnot(grepl("mismatched cell key", key_error, fixed = TRUE))
unlink(provenance_path)
provenance_error <- tryCatch({
  validate_resume_cell(csv_path, provenance_path, cell, 123)
  ""
}, error = function(e) conditionMessage(e))
stopifnot(grepl("no provenance file", provenance_error, fixed = TRUE),
          identical(validate_resume_cell(tempfile(), provenance_path, cell, 123), integer(0)))
unlink(c(csv_path, provenance_path, legacy_path, bad_csv_path))

cat("Null-calibration CSV round-trip, warning reader and resume checks passed\n")
