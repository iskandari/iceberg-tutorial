library(sparklyr)
library(DBI)

# First run scripts/tunnel-livy.sh in a terminal and leave it open.
# First time only: install.packages(c("sparklyr", "DBI"))
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

DBI::dbGetQuery(sc, "SHOW TABLES IN glue_catalog.vpts")

sample <- DBI::dbGetQuery(sc, "
  SELECT radar, datetime, height, dens, ff, dd
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND rad = 'KBUF'
  ORDER BY datetime, height
  LIMIT 100
")

head(sample)

# A small aggregation stays in Spark; only the result returns to RStudio.
nightly_profiles <- DBI::dbGetQuery(sc, "
  SELECT radar, CAST(datetime AS DATE) AS date,
         ROUND(AVG(dens), 2) AS mean_density,
         ROUND(AVG(CASE WHEN ISNAN(ff) THEN NULL ELSE ff END), 2) AS mean_speed,
         COUNT(*) AS profiles
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND rad IN ('KBUF', 'KTYX')
  GROUP BY radar, CAST(datetime AS DATE)
  ORDER BY date, radar
  LIMIT 100
")

head(nightly_profiles)
spark_disconnect(sc)
