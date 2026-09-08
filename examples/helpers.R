options(rstudio.connectionObserver.errorsSuppressed = TRUE)

vpts_spark_config <- function(initial_executors = 1L, max_executors = 4L) {
  config <- sparklyr::spark_config()
  config[["sparklyr.livy.jar"]] <-
    "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
  config[["spark.dynamicAllocation.initialExecutors"]] <- initial_executors
  config[["spark.dynamicAllocation.maxExecutors"]] <- max_executors
  config[["spark.sql.catalog.glue_catalog.http-client.type"]] <- "apache"
  config[["spark.sql.catalog.glue_catalog.http-client.apache.max-connections"]] <- 200
  config[["spark.sql.catalog.glue_catalog.http-client.apache.connection-acquisition-timeout-ms"]] <- 120000
  config
}

connect_vpts <- function(livy_url = "http://localhost:8998",
                         initial_executors = 1L, max_executors = 4L) {
  sparklyr::spark_connect(
    master = livy_url,
    method = "livy",
    version = "3.5",
    config = vpts_spark_config(initial_executors, max_executors)
  )
}

timed_query <- function(sc, label, sql) {
  started <- Sys.time()
  result <- DBI::dbGetQuery(sc, sql)
  seconds <- as.numeric(difftime(Sys.time(), started, units = "secs"))
  message(sprintf("TIMING | %s | %.2f seconds", label, seconds))
  result
}
