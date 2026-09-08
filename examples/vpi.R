library(sparklyr)
library(DBI)
options(rstudio.connectionObserver.errorsSuppressed = TRUE)
source("examples/helpers.R")

# First run scripts/tunnel-livy.sh in a terminal and leave it open.
sc <- connect_vpts(initial_executors = 1L, max_executors = 4L)

# Discover every Iceberg table in the VPTS database.
timed_query(sc, "List VPTS tables", "SHOW TABLES IN glue_catalog.vpts")
timed_query(sc, "Describe VPI", "DESCRIBE glue_catalog.vpts.vpi")

# How many vertically integrated profiles are available per year?
vpi_by_year <- timed_query(sc, "VPI counts by year", "
  SELECT year,
         COUNT(*) AS vpi_count,
         COUNT(DISTINCT radar) AS radar_count,
         MIN(datetime) AS first_observation,
         MAX(datetime) AS last_observation
  FROM glue_catalog.vpts.vpi
  GROUP BY year
  ORDER BY year
")

print(vpi_by_year)

# Vertically integrated products by radar/week.
vpi_week <- timed_query(sc, "Weekly VPI summary", "
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

# SQL equivalent of integrate_profile_pyspark() from sparkbird.ipynb.
# It integrates 100 m vertical profiles from 0--5,000 m for one radar-day.
# Change the radar/date after trying this small example.
integrate_profile_sql <- "
  WITH cleaned AS (
    SELECT
      radar, datetime, radar_latitude, radar_longitude, radar_height,
      height, rcs, source_file,
      CASE WHEN ISNAN(dens) THEN NULL ELSE dens END AS dens,
      CASE WHEN ISNAN(eta)  THEN NULL ELSE eta  END AS eta,
      CASE WHEN ISNAN(ff)   THEN NULL ELSE ff   END AS ff,
      CASE WHEN ISNAN(dd)   THEN NULL ELSE dd   END AS dd,
      CASE WHEN ISNAN(u) THEN NULL ELSE u END AS u0,
      CASE WHEN ISNAN(v) THEN NULL ELSE v END AS v0
    FROM glue_catalog.vpts.data
    WHERE year = 2023
      AND radar = 'KABR'
      AND datetime >= TIMESTAMP '2023-01-03 00:00:00'
      AND datetime <  TIMESTAMP '2023-01-04 00:00:00'
      AND height >= 0 AND height < 5000
  ), velocity AS (
    SELECT *,
      COALESCE(u0, ff * SIN(RADIANS(dd))) AS u,
      COALESCE(v0, ff * COS(RADIANS(dd))) AS v,
      LEAST(100.0, GREATEST(5000.0 - height, 0.0)) / 1000.0 AS dh_km
    FROM cleaned
  ), terms AS (
    SELECT *,
      dens * dh_km AS dens_dh,
      eta * dh_km AS eta_dh,
      dens * ff * 3.6 * dh_km AS mtr_term,
      eta * ff * 3.6 * dh_km AS rtr_term,
      height + 50.0 AS height_mid
    FROM velocity
    WHERE dh_km > 0
  ), integrated AS (
    SELECT
      radar, datetime, radar_longitude AS lon, radar_latitude AS lat,
      radar_height,
      SUM(mtr_term) AS mtr,
      SUM(dens_dh) AS vid,
      SUM(eta_dh) AS vir,
      SUM(rtr_term) AS rtr,
      SUM(dens_dh * u) / SUM(dens_dh) AS u,
      SUM(dens_dh * v) / SUM(dens_dh) AS v,
      SUM(dens_dh * ff) / SUM(dens_dh) AS ff,
      SUM(dens_dh * height_mid) / SUM(dens_dh) AS height_mean_asl,
      FIRST(rcs, TRUE) AS rcs,
      FIRST(source_file, TRUE) AS source_file
    FROM terms
    GROUP BY radar, datetime, radar_longitude, radar_latitude, radar_height
  )
  SELECT
    radar, datetime, lon, lat, radar_height, mtr, vid, vir, rtr,
    CAST(NULL AS DOUBLE) AS mt, CAST(NULL AS DOUBLE) AS rt,
    ff,
    CASE
      WHEN 90.0 - DEGREES(ATAN2(v, u)) < 0
        THEN 450.0 - DEGREES(ATAN2(v, u))
      ELSE 90.0 - DEGREES(ATAN2(v, u))
    END AS dd,
    u, v,
    GREATEST(height_mean_asl - radar_height, 0.0) AS height_mean,
    height_mean_asl, rcs, source_file
  FROM integrated
  ORDER BY datetime
"

vpi_from_profiles <- timed_query(
  sc,
  "Run integrate_profile in Spark SQL",
  integrate_profile_sql
)
print(head(vpi_from_profiles))

spark_disconnect(sc)
