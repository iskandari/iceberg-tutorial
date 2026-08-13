library(sparklyr)
library(DBI)

# First run scripts/tunnel-livy.sh in a terminal and leave it open.
sc <- spark_connect(
  master = "http://localhost:8998",
  method = "livy",
  app_name = "vpts-r-tutorial"
)

DBI::dbGetQuery(sc, "SHOW TABLES IN glue_catalog.vpts")

sample <- DBI::dbGetQuery(sc, "
  SELECT radar, datetime, height, dens, ff, dd
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND radar = 'KBUF'
  ORDER BY datetime, height
  LIMIT 100
")

head(sample)
spark_disconnect(sc)

