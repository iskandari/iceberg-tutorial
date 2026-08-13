library(sparklyr)
library(DBI)
source("examples/helpers.R")

config <- spark_config()
config[["sparklyr.livy.jar"]] <- "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
config[["spark.dynamicAllocation.initialExecutors"]] <- 1
config[["spark.dynamicAllocation.maxExecutors"]] <- 12

sc <- spark_connect(
  master = "http://localhost:8998",
  method = "livy",
  version = "3.5",
  config = config
)
on.exit(spark_disconnect(sc), add = TRUE)

# Question: Across the complete archive, which 100 m mean-flight-height bands
# have the highest vertically integrated density (VID)?
# Intentionally no year/week/radar filter: this scans the entire VPI table.
all_vpts <- timed_query(sc, "Archive-wide VID by flight-height band", "
  SELECT
    FLOOR(height_mean / 100) * 100 AS height_band_m,
    COUNT(*) AS observations,
    COUNT(DISTINCT radar) AS radars,
    ROUND(AVG(vid), 2) AS mean_vid,
    ROUND(PERCENTILE_APPROX(vid, 0.5), 2) AS median_vid,
    ROUND(PERCENTILE_APPROX(vid, 0.95), 2) AS p95_vid
  FROM glue_catalog.vpts.vpi
  WHERE height_mean IS NOT NULL AND NOT ISNAN(height_mean)
    AND vid IS NOT NULL AND NOT ISNAN(vid)
  GROUP BY FLOOR(height_mean / 100) * 100
  HAVING COUNT(*) >= 1000
  ORDER BY mean_vid DESC
")
print(all_vpts)
