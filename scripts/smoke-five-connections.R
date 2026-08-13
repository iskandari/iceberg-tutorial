library(parallel)

results <- mclapply(seq_len(5), function(user_number) {
  tryCatch({
    library(sparklyr)
    library(DBI)
    config <- spark_config()
    config[["sparklyr.livy.jar"]] <- "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
    config[["spark.dynamicAllocation.initialExecutors"]] <- 1
    config[["spark.dynamicAllocation.maxExecutors"]] <- 4
    sc <- spark_connect(
      master = "http://localhost:8998",
      method = "livy",
      version = "3.5",
      config = config
    )
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
}, mc.cores = 5)

print(unlist(results))
if (any(grepl("ERROR", unlist(results)))) quit(status = 1)

