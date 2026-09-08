#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(sparklyr)
})
if (!requireNamespace("arrow", quietly = TRUE)) stop("Package 'arrow' is required.")
if (!requireNamespace("yaml", quietly = TRUE)) stop("Package 'yaml' is required.")

args <- commandArgs(trailingOnly = TRUE)
target_year <- if (length(args)) as.integer(args[[1L]]) else 2025L
output_path <- if (length(args) >= 2L) args[[2L]] else
  paste0("s3://vpts-extrapolation-863683271215/production/profile_sampled/year=",
         target_year, "/")
livy_url <- if (length(args) >= 3L) args[[3L]] else "http://localhost:8998"
aws_profile <- if (length(args) >= 4L) args[[4L]] else "sso-admin"

cfg <- yaml::read_yaml("extrapolation/config.yml")
stopifnot(target_year == cfg$test_year, cfg$n_layers == 50, cfg$dh_m == 100,
          cfg$k_max == 10, cfg$s_max == 3, cfg$vid_min == 6.6,
          nzchar(cfg$snapshot_id), nzchar(cfg$vpi_snapshot_id))

spark_cfg <- spark_config()
spark_cfg[["sparklyr.livy.jar"]] <-
  "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
spark_cfg[["spark.dynamicAllocation.initialExecutors"]] <- 8
spark_cfg[["spark.dynamicAllocation.maxExecutors"]] <- 12
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.type"]] <- "apache"
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.apache.max-connections"]] <- 200
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.apache.connection-acquisition-timeout-ms"]] <- 120000

sc <- spark_connect(master = livy_url, method = "livy", version = "3.5",
                    config = spark_cfg)
on.exit(try(spark_disconnect(sc), silent = TRUE), add = TRUE)

coverage <- dbGetQuery(sc, sprintf("
  SELECT radar AS station_id, FIRST(lon, true) AS lon, FIRST(lat, true) AS lat
  FROM glue_catalog.vpts.vpi VERSION AS OF %s
  WHERE year = %d AND lat BETWEEN 24 AND 50 AND lon BETWEEN -125 AND -66
  GROUP BY radar
", cfg$vpi_snapshot_id, target_year))
source("extrapolation/R/metadata.R")
solar <- build_solar_dimension(coverage,
  as.Date(sprintf("%d-01-01", target_year)) - 1,
  as.Date(sprintf("%d-12-31", target_year)), polar_policy = "drop")
local_solar <- tempfile(pattern = "vpts-production-solar-", fileext = ".parquet")
arrow::write_parquet(solar, local_solar, compression = "zstd")
s3_solar <- paste0("s3://ice.bird/tutorial/vpts-extrapolation/tmp/production-solar-",
                   target_year, "-", Sys.getpid(), ".parquet")
aws <- function(arguments) {
  status <- system2("aws", c("--profile", aws_profile, "--region", "us-east-1",
                              arguments))
  if (!identical(status, 0L)) stop("AWS command failed with status ", status)
}
aws(c("s3", "cp", local_solar, s3_solar, "--only-show-errors"))
on.exit({
  try(aws(c("s3", "rm", s3_solar, "--only-show-errors")), silent = TRUE)
  unlink(local_solar)
}, add = TRUE)
dbExecute(sc, paste0(
  "CREATE OR REPLACE TEMP VIEW production_solar USING parquet OPTIONS (path '",
  s3_solar, "')"))

production_sql <- sprintf("
  WITH night_candidates AS (
    SELECT v.radar, v.datetime, v.year, v.vid AS archive_vid,
           s.night_key, s.sunset0, s.sunrise, s.sunset1
    FROM (
      SELECT v.*, candidate_night_key
      FROM glue_catalog.vpts.vpi VERSION AS OF %s v
      LATERAL VIEW EXPLODE(ARRAY(CAST(v.datetime AS DATE),
                                 DATE_SUB(CAST(v.datetime AS DATE), 1))) nights
        AS candidate_night_key
      WHERE v.year = %d
        AND v.lat BETWEEN 24 AND 50 AND v.lon BETWEEN -125 AND -66
        AND v.vid IS NOT NULL AND NOT ISNAN(v.vid) AND v.vid >= %.17g
    ) v
    JOIN production_solar s
      ON s.station_id = v.radar AND s.night_key = v.candidate_night_key
     AND v.datetime >= s.sunset0 AND v.datetime < s.sunrise
  ), hourly AS (
    SELECT radar, DATE_TRUNC('hour', datetime) AS station_hour,
           PERCENTILE_APPROX(archive_vid, 0.5, 10000) AS hour_median
    FROM night_candidates GROUP BY radar, DATE_TRUNC('hour', datetime)
  ), thinned AS (
    SELECT n.*, ROW_NUMBER() OVER (
      PARTITION BY n.radar, h.station_hour
      ORDER BY ABS(n.archive_vid - h.hour_median),
               XXHASH64(n.radar, CAST(n.datetime AS STRING), '%d')
    ) AS hour_rank
    FROM night_candidates n JOIN hourly h
      ON n.radar = h.radar
     AND DATE_TRUNC('hour', n.datetime) = h.station_hour
  ), complete AS (
    SELECT t.radar, t.datetime, t.archive_vid, t.night_key,
           t.sunset0, t.sunrise, t.sunset1
    FROM thinned t
    JOIN glue_catalog.vpts.data VERSION AS OF %s d
      ON d.radar = t.radar AND d.datetime = t.datetime AND d.year = %d
    WHERE t.hour_rank = 1 AND d.height >= 0 AND d.height < %d
      AND ABS(d.height - ROUND(d.height / %d) * %d) <= %.17g
    GROUP BY t.radar, t.datetime, t.archive_vid, t.night_key,
             t.sunset0, t.sunrise, t.sunset1
    HAVING COUNT(DISTINCT d.height) = %d
  )
  SELECT d.*, c.archive_vid, c.night_key, c.sunset0, c.sunrise, c.sunset1,
         CAST('%s' AS STRING) AS source_snapshot_id,
         CAST('%s' AS STRING) AS vpi_snapshot_id,
         CAST(%.17g AS DOUBLE) AS vid_min
  FROM complete c
  JOIN glue_catalog.vpts.data VERSION AS OF %s d
    ON d.radar = c.radar AND d.datetime = c.datetime AND d.year = %d
  WHERE d.height >= 0 AND d.height < %d
    AND ABS(d.height - ROUND(d.height / %d) * %d) <= %.17g
", cfg$vpi_snapshot_id, target_year, cfg$vid_min, cfg$seed,
   cfg$snapshot_id, target_year, cfg$n_layers * cfg$dh_m, cfg$dh_m, cfg$dh_m,
   cfg$height_grid_tolerance_m, cfg$n_layers, cfg$snapshot_id,
   cfg$vpi_snapshot_id, cfg$vid_min, cfg$snapshot_id, target_year,
   cfg$n_layers * cfg$dh_m, cfg$dh_m, cfg$dh_m,
   cfg$height_grid_tolerance_m)

message("Writing 2025 production sample to ", output_path)
started <- Sys.time()
production <- sdf_sql(sc, production_sql)
spark_write_parquet(production, output_path, mode = "error",
                    options = list(compression = "zstd"),
                    partition_by = c("rad", "month"))

audit <- dbGetQuery(sc, sprintf("
  SELECT COUNT(*) AS rows,
         COUNT(DISTINCT STRUCT(radar, datetime)) AS profiles,
         COUNT(DISTINCT radar) AS stations,
         MIN(height) AS min_height_m, MAX(height) AS max_height_m
  FROM parquet.`%s`
", output_path))
audit$output_path <- output_path
audit$year <- target_year
audit$elapsed_seconds <- as.numeric(difftime(Sys.time(), started, units = "secs"))
dir.create("extrapolation/results", recursive = TRUE, showWarnings = FALSE)
audit_path <- file.path("extrapolation/results",
                        paste0("production-sample-audit-", target_year, ".csv"))
write.csv(audit, audit_path, row.names = FALSE)
print(audit)
message("Audit: ", normalizePath(audit_path))
