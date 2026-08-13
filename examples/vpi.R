library(sparklyr)
library(DBI)

# First run scripts/tunnel-livy.sh in a terminal and leave it open.
sc <- spark_connect(
  master = "http://localhost:8998",
  method = "livy",
  app_name = "vpi-r-tutorial"
)

# Discover every Iceberg table in the VPTS database.
DBI::dbGetQuery(sc, "SHOW TABLES IN glue_catalog.vpts")
DBI::dbGetQuery(sc, "DESCRIBE glue_catalog.vpts.vpi")

# Vertically integrated products by radar/week.
vpi_week <- DBI::dbGetQuery(sc, "
  SELECT radar, year, week,
         ROUND(AVG(mtr), 2) AS mean_mtr,
         ROUND(AVG(vid), 2) AS mean_vid,
         ROUND(AVG(ff), 2) AS mean_speed,
         COUNT(*) AS observations
  FROM glue_catalog.vpts.vpi
  WHERE year = 2024 AND radar IN ('KBUF', 'KTYX')
  GROUP BY radar, year, week
  ORDER BY year, week, radar
  LIMIT 100
")

head(vpi_week)
spark_disconnect(sc)

