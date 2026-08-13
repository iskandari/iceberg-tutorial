library(sparklyr)
library(DBI)
options(rstudio.connectionObserver.errorsSuppressed = TRUE)
source("examples/helpers.R")

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

# 1. Which spring weeks had the most migration traffic?
busiest_weeks <- timed_query(sc, "Busiest migration weeks", "
  SELECT radar, week,
         ROUND(AVG(CASE WHEN ISNAN(mtr) THEN NULL ELSE mtr END), 2) AS mean_mtr,
         ROUND(MAX(CASE WHEN ISNAN(mtr) THEN NULL ELSE mtr END), 2) AS peak_mtr
  FROM glue_catalog.vpts.vpi
  WHERE year = 2024 AND week BETWEEN 12 AND 22
    AND radar IN ('KBUF', 'KTYX')
  GROUP BY radar, week
  ORDER BY peak_mtr DESC
  LIMIT 20
")

# 2. At what height was bird density concentrated?
flight_height <- timed_query(sc, "Density-weighted flight height", "
  SELECT radar, CAST(datetime AS DATE) AS date,
         ROUND(SUM(height * dens) / SUM(dens), 0) AS density_weighted_height_m,
         ROUND(MAX(dens), 2) AS peak_density
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND rad IN ('KBUF', 'KTYX')
    AND dens > 0 AND NOT ISNAN(dens)
  GROUP BY radar, CAST(datetime AS DATE)
  ORDER BY peak_density DESC
  LIMIT 30
")

# 3. When during the day did migration density peak?
peak_hours <- timed_query(sc, "Peak migration hours", "
  SELECT radar, HOUR(datetime) AS utc_hour,
         ROUND(AVG(dens), 2) AS mean_density
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND rad IN ('KBUF', 'KTYX')
    AND dens IS NOT NULL AND NOT ISNAN(dens)
  GROUP BY radar, HOUR(datetime)
  ORDER BY mean_density DESC
")

# 4. What was the mean movement vector and speed by radar?
movement <- timed_query(sc, "Mean movement vectors", "
  SELECT radar,
         ROUND(AVG(CASE WHEN ISNAN(u) THEN NULL ELSE u END), 2) AS mean_u,
         ROUND(AVG(CASE WHEN ISNAN(v) THEN NULL ELSE v END), 2) AS mean_v,
         ROUND(AVG(CASE WHEN ISNAN(ff) THEN NULL ELSE ff END), 2) AS mean_speed
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND rad IN ('KBUF', 'KTYX')
  GROUP BY radar
")

# 5. Are gaps concentrated at particular radars?
coverage <- timed_query(sc, "Radar data gaps", "
  SELECT radar, COUNT(*) AS profiles,
         ROUND(100 * AVG(CASE WHEN gap THEN 1.0 ELSE 0.0 END), 2) AS gap_percent
  FROM glue_catalog.vpts.data
  WHERE year = 2024 AND month = 5 AND rad IN ('KBUF', 'KTYX')
  GROUP BY radar
  ORDER BY gap_percent DESC
")

print(busiest_weeks)
print(flight_height)
print(peak_hours)
print(movement)
print(coverage)
spark_disconnect(sc)
