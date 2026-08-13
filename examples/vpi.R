library(sparklyr)
library(DBI)

# First run scripts/tunnel-livy.sh in a terminal and leave it open.
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

# Discover every Iceberg table in the VPTS database.
DBI::dbGetQuery(sc, "SHOW TABLES IN glue_catalog.vpts")
DBI::dbGetQuery(sc, "DESCRIBE glue_catalog.vpts.vpi")

# Vertically integrated products by radar/week.
vpi_week <- DBI::dbGetQuery(sc, "
  SELECT radar, year, week,
         ROUND(AVG(CASE WHEN ISNAN(mtr) THEN NULL ELSE mtr END), 2) AS mean_mtr,
         ROUND(AVG(CASE WHEN ISNAN(vid) THEN NULL ELSE vid END), 2) AS mean_vid,
         ROUND(AVG(CASE WHEN ISNAN(ff) THEN NULL ELSE ff END), 2) AS mean_speed,
         COUNT(*) AS observations
  FROM glue_catalog.vpts.vpi
  WHERE year = 2024 AND radar IN ('KBUF', 'KTYX')
  GROUP BY radar, year, week
  ORDER BY year, week, radar
  LIMIT 100
")

head(vpi_week)
spark_disconnect(sc)
