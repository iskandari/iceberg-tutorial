library(parallel)
source("examples/helpers.R")

results <- mclapply(seq_len(10), function(user_number) {
  tryCatch({
    library(sparklyr)
    library(DBI)
    sc <- connect_vpts(initial_executors = 1L, max_executors = 4L)
    on.exit(spark_disconnect(sc), add = TRUE)
    row <- DBI::dbGetQuery(sc, "
      SELECT radar, datetime
      FROM glue_catalog.vpts.data
      WHERE rad = 'KBUF' AND year = 2024 AND month = 5
      LIMIT 1
    ")
    sprintf("user %d: %s", user_number, row$radar[[1]])
  }, error = function(error) {
    sprintf("user %d: ERROR: %s", user_number, conditionMessage(error))
  })
}, mc.cores = 10)

print(unlist(results))
if (any(grepl("ERROR", unlist(results)))) quit(status = 1)
