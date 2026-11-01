#!/usr/bin/env Rscript
# SPDX-License-Identifier: MPL-2.0
# Parse-only R structure inventory. Base R only; never source/evaluate a target.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
root <- normalizePath(args[[1]], mustWork = TRUE)
paths <- system2("git", c("-C", shQuote(root), "ls-files", "--", "*.R", "*.r"), stdout = TRUE)
paths <- paths[nzchar(paths)]
stopifnot(!any(grepl("[\r\n]", paths)))
jstr <- function(x) {
  x <- enc2utf8(x)
  chars <- strsplit(x, "", fixed = TRUE)[[1]]
  out <- vapply(chars, function(ch) {
    code <- utf8ToInt(ch)
    if (ch == '"') return('\\"')
    if (ch == '\\') return('\\\\')
    if (code < 32L) return(sprintf('\\u%04x', code))
    ch
  }, character(1))
  paste0('"', paste(out, collapse = ""), '"')
}
jvec <- function(x) paste0("[", paste(vapply(x, jstr, character(1)), collapse = ","), "]")
canon <- function(x) {
  if (is.call(x) || is.pairlist(x) || is.expression(x)) {
    parts <- vapply(as.list(x), canon, character(1))
    return(paste0("call:", paste(parts, collapse = ",")))
  }
  paste0(typeof(x), ":", paste(deparse(x, width.cutoff = 500L, control = c("keepInteger", "showAttributes")), collapse = "\\n"))
}
for (path in sort(paths)) {
  expr <- parse(file = file.path(root, path), keep.source = FALSE)
  calls <- character(); imports <- character(); functions <- character()
  visit <- function(x, caller) {
    if (!is.call(x)) return(invisible(NULL))
    head <- x[[1]]
    name <- paste(deparse(head, width.cutoff = 500L), collapse = " ")
    calls <<- c(calls, paste0('{"caller":', jstr(caller), ',"callee":', jstr(name), ',"resolved":false}'))
    if (name %in% c("library", "require", "source") && length(x) >= 2L)
      imports <<- c(imports, paste(deparse(x[[2]]), collapse = " "))
    if (name %in% c("<-", "=") && length(x) >= 3L && is.call(x[[3]]) && identical(x[[3]][[1]], as.name("function"))) {
      fn <- paste(deparse(x[[2]]), collapse = " ")
      functions <<- c(functions, paste0('{"name":', jstr(fn), ',"normalized":', jstr(canon(x[[3]])), '}'))
    }
    for (child in as.list(x)[-1]) visit(child, caller)
    invisible(NULL)
  }
  for (ex in expr) visit(ex, "<top-level>")
  cat(paste0('{"path":', jstr(path), ',"language":"r","normalized":', jstr(canon(expr)),
             ',"functions":[', paste(functions, collapse = ","), '],"calls":[', paste(calls, collapse = ","),
             '],"imports":', jvec(sort(unique(imports))), ',"limitations":["parse-only","syntactic unresolved calls","no R dataflow analysis"]}', "\n"), sep = "")
}
