options(rstudio.connectionObserver.errorsSuppressed = TRUE)

timed_query <- function(sc, label, sql) {
  started <- Sys.time()
  result <- DBI::dbGetQuery(sc, sql)
  seconds <- as.numeric(difftime(Sys.time(), started, units = "secs"))
  message(sprintf("TIMING | %s | %.2f seconds", label, seconds))
  result
}
