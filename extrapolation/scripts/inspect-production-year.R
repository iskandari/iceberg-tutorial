#!/usr/bin/env Rscript

# Run scripts/tunnel-livy.sh first and leave it open. This script is read-only.
suppressPackageStartupMessages({
  library(DBI)
  library(sparklyr)
})
source("examples/helpers.R")

args <- commandArgs(trailingOnly = TRUE)
target_year <- if (length(args)) as.integer(args[[1L]]) else 2025L
sample_path <- if (length(args) >= 2L) args[[2L]] else
  paste0("s3://vpts-extrapolation-863683271215/production/profile_sampled/year=",
         target_year, "/")

sc <- connect_vpts(initial_executors = 1L, max_executors = 4L)
on.exit(spark_disconnect(sc), add = TRUE)

path_literal <- gsub("'", "''", sample_path, fixed = TRUE)
DBI::dbExecute(sc, paste0(
  "CREATE OR REPLACE TEMP VIEW production_sample USING parquet OPTIONS (path '",
  path_literal, "')"))

summary <- timed_query(sc, "Production sample summary", "
  SELECT COUNT(*) AS layer_rows,
         COUNT(DISTINCT STRUCT(radar, datetime)) AS profiles,
         COUNT(DISTINCT radar) AS stations,
         MIN(datetime) AS first_profile,
         MAX(datetime) AS last_profile,
         MIN(height) AS min_height_m,
         MAX(height) AS max_height_m,
         MIN(archive_vid) AS min_vid
  FROM production_sample
")
print(summary)

missingness <- timed_query(sc, "Missingness by height", "
  SELECT height, COUNT(*) AS rows,
         SUM(CASE WHEN dens IS NULL OR ISNAN(dens) THEN 1 ELSE 0 END) AS dens_missing,
         SUM(CASE WHEN u IS NULL OR ISNAN(u) THEN 1 ELSE 0 END) AS u_missing,
         SUM(CASE WHEN v IS NULL OR ISNAN(v) THEN 1 ELSE 0 END) AS v_missing,
         SUM(CASE WHEN sd_vvp IS NULL OR ISNAN(sd_vvp) THEN 1 ELSE 0 END) AS sd_vvp_missing
  FROM production_sample
  GROUP BY height ORDER BY height
")
print(missingness, row.names = FALSE)

one_profile <- timed_query(sc, "One 50-bin profile", "
  WITH first_profile AS (
    SELECT radar, datetime FROM production_sample
    ORDER BY radar, datetime LIMIT 1
  )
  SELECT p.radar, p.datetime, p.height, p.dens, p.u, p.v,
         p.n_dbz_all, p.sd_vvp, p.archive_vid, p.sunset0, p.sunrise
  FROM production_sample p JOIN first_profile f
    ON p.radar = f.radar AND p.datetime = f.datetime
  ORDER BY p.height
")
print(one_profile, row.names = FALSE)
