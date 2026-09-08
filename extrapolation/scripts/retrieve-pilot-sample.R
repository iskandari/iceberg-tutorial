#!/usr/bin/env Rscript

# Retrieve a compact, deterministic, read-only pilot sample for inspecting the
# 50-bin model inputs and finalizing QC predicates. The sample stays local.

suppressPackageStartupMessages({
  library(DBI)
  library(sparklyr)
})

if (!requireNamespace("arrow", quietly = TRUE)) stop("Package 'arrow' is required.")
if (!requireNamespace("yaml", quietly = TRUE)) stop("Package 'yaml' is required.")

args <- commandArgs(trailingOnly = TRUE)
output_path <- if (length(args) >= 1L) args[[1L]] else
  "extrapolation/samples/vpts-pilot-50bins.parquet"
livy_url <- if (length(args) >= 2L) args[[2L]] else "http://localhost:8998"
aws_profile <- if (length(args) >= 3L) args[[3L]] else "sso-admin"

cfg <- yaml::read_yaml("extrapolation/config.yml")
stopifnot(cfg$n_layers == 50, cfg$dh_m == 100, cfg$k_max == 10,
          cfg$s_max == 3, cfg$vid_min == 6.6)

spark_cfg <- spark_config()
spark_cfg[["sparklyr.livy.jar"]] <-
  "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
spark_cfg[["spark.dynamicAllocation.initialExecutors"]] <- 4
spark_cfg[["spark.dynamicAllocation.maxExecutors"]] <- 12
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.type"]] <- "apache"
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.apache.max-connections"]] <- 200
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.apache.connection-acquisition-timeout-ms"]] <- 120000

message("Connecting to Livy at ", livy_url)
sc <- spark_connect(master = livy_url, method = "livy", version = "3.5",
                    config = spark_cfg)
on.exit(try(spark_disconnect(sc), silent = TRUE), add = TRUE)

snapshot_rows <- dbGetQuery(sc, "
  SELECT 'data' AS table_name, CAST(snapshot_id AS STRING) AS snapshot_id,
         committed_at
  FROM glue_catalog.vpts.data.snapshots
  UNION ALL
  SELECT 'vpi' AS table_name, CAST(snapshot_id AS STRING) AS snapshot_id,
         committed_at
  FROM glue_catalog.vpts.vpi.snapshots
")
latest <- do.call(rbind, lapply(split(snapshot_rows, snapshot_rows$table_name),
  function(x) x[which.max(x$committed_at), , drop = FALSE]))
data_snapshot <- latest$snapshot_id[latest$table_name == "data"]
vpi_snapshot <- latest$snapshot_id[latest$table_name == "vpi"]

coverage <- dbGetQuery(sc, sprintf("
  SELECT radar AS station_id, FIRST(lon, true) AS lon, FIRST(lat, true) AS lat,
         MIN(CAST(datetime AS DATE)) AS first_date,
         MAX(CAST(datetime AS DATE)) AS last_date
  FROM glue_catalog.vpts.vpi VERSION AS OF %s
  WHERE year BETWEEN 2013 AND 2024
    AND lat BETWEEN 24 AND 50 AND lon BETWEEN -125 AND -66
  GROUP BY radar
", vpi_snapshot))
source("extrapolation/R/metadata.R")
solar <- build_solar_dimension(
  coverage[, c("station_id", "lat", "lon")],
  min(as.Date(coverage$first_date)) - 1,
  max(as.Date(coverage$last_date)),
  polar_policy = "drop"
)
local_solar <- tempfile(pattern = "vpts-pilot-solar-", fileext = ".parquet")
arrow::write_parquet(solar, local_solar, compression = "zstd")
run_stamp <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")
s3_solar <- paste0("s3://ice.bird/tutorial/vpts-extrapolation/tmp/pilot-solar-",
                   run_stamp, ".parquet")
aws <- function(arguments) {
  status <- system2("aws", c("--profile", aws_profile, "--region", "us-east-1",
                              arguments))
  if (!identical(status, 0L)) stop("AWS command failed with status ", status)
}
message("Uploading temporary solar lookup")
aws(c("s3", "cp", local_solar, s3_solar, "--only-show-errors"))
on.exit({
  try(aws(c("s3", "rm", s3_solar, "--only-show-errors")), silent = TRUE)
  unlink(local_solar)
}, add = TRUE)
dbExecute(sc, paste0(
  "CREATE OR REPLACE TEMP VIEW pilot_solar USING parquet OPTIONS (path '",
  s3_solar, "')"
))

build_year_sql <- function(sample_year) sprintf("
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
    JOIN pilot_solar s
      ON s.station_id = v.radar
     AND s.night_key = v.candidate_night_key
     AND v.datetime >= s.sunset0 AND v.datetime < s.sunrise
  ), hourly AS (
    SELECT radar, DATE_TRUNC('hour', datetime) AS station_hour,
           PERCENTILE_APPROX(archive_vid, 0.5, 10000) AS hour_median
    FROM night_candidates
    GROUP BY radar, DATE_TRUNC('hour', datetime)
  ), thinned AS (
    SELECT n.*, ROW_NUMBER() OVER (
      PARTITION BY n.radar, h.station_hour
      ORDER BY ABS(n.archive_vid - h.hour_median),
               XXHASH64(n.radar, CAST(n.datetime AS STRING), '%d')
    ) AS hour_rank
    FROM night_candidates n JOIN hourly h
      ON n.radar = h.radar
     AND DATE_TRUNC('hour', n.datetime) = h.station_hour
  ), intensity AS (
    SELECT *, NTILE(10) OVER (
      PARTITION BY radar, year ORDER BY archive_vid
    ) AS intensity_decile
    FROM thinned WHERE hour_rank = 1
  ), ranked_candidates AS (
    SELECT *, ROW_NUMBER() OVER (
      PARTITION BY radar, year, intensity_decile
      ORDER BY XXHASH64(radar, CAST(datetime AS STRING), '%d')
    ) AS candidate_rank
    FROM intensity
  ), candidate_layers AS (
    SELECT c.radar, c.datetime, c.year, c.archive_vid, c.night_key,
           c.sunset0, c.sunrise, c.sunset1, c.intensity_decile,
           c.candidate_rank, d.height
    FROM ranked_candidates c
    JOIN glue_catalog.vpts.data VERSION AS OF %s d
      ON d.radar = c.radar AND d.datetime = c.datetime AND d.year = %d
    WHERE c.candidate_rank <= 5
      AND d.height >= 0 AND d.height < %d
      AND ABS(d.height - ROUND(d.height / %d) * %d) <= %.17g
  ), complete AS (
    SELECT radar, datetime, year, archive_vid, night_key, sunset0, sunrise,
           sunset1, intensity_decile, candidate_rank
    FROM candidate_layers
    GROUP BY radar, datetime, year, archive_vid, night_key, sunset0, sunrise,
             sunset1, intensity_decile, candidate_rank
    HAVING COUNT(DISTINCT height) = %d
  ), selected AS (
    SELECT *, ROW_NUMBER() OVER (
      PARTITION BY radar, year, intensity_decile ORDER BY candidate_rank
    ) AS profile_rank
    FROM complete
  )
  SELECT d.*, s.archive_vid, s.night_key, s.sunset0, s.sunrise, s.sunset1,
         s.intensity_decile
  FROM selected s
  JOIN glue_catalog.vpts.data VERSION AS OF %s d
    ON d.radar = s.radar AND d.datetime = s.datetime AND d.year = %d
  WHERE s.profile_rank = 1
    AND d.height >= 0 AND d.height < %d
    AND ABS(d.height - ROUND(d.height / %d) * %d) <= %.17g
  ORDER BY d.radar, d.datetime, d.height
", vpi_snapshot, sample_year, cfg$vid_min, cfg$seed, cfg$seed,
   data_snapshot, sample_year, cfg$n_layers * cfg$dh_m, cfg$dh_m, cfg$dh_m,
   cfg$height_grid_tolerance_m, cfg$n_layers, data_snapshot, sample_year,
   cfg$n_layers * cfg$dh_m, cfg$dh_m, cfg$dh_m,
   cfg$height_grid_tolerance_m)

message("Retrieving deterministic complete-profile pilot by year")
started <- Sys.time()
chunks <- lapply(2013:2024, function(sample_year) {
  message("Retrieving ", sample_year)
  value <- dbGetQuery(sc, build_year_sql(sample_year))
  message("Retrieved ", nrow(value), " rows for ", sample_year)
  value
})
sample <- do.call(rbind, chunks)
elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
if (!nrow(sample)) stop("Pilot query returned no rows.")

profile_key <- paste(sample$radar, sample$datetime)
profile_counts <- table(profile_key)
if (any(profile_counts != cfg$n_layers)) {
  stop("Pilot invariant failed: every profile must contain exactly 50 rows.")
}
expected_heights <- seq(0, 4900, by = 100)
height_ok <- vapply(split(sample$height, profile_key), function(x) {
  identical(sort(as.numeric(x)), expected_heights)
}, logical(1))
if (!all(height_ok)) stop("Pilot invariant failed: a profile is off the 100 m grid.")

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
arrow::write_parquet(sample, output_path, compression = "zstd")
manifest <- data.frame(
  output_path = normalizePath(output_path),
  data_snapshot_id = data_snapshot,
  vpi_snapshot_id = vpi_snapshot,
  vid_min = cfg$vid_min,
  dh_m = cfg$dh_m,
  n_layers = cfg$n_layers,
  k_max = cfg$k_max,
  s_max = cfg$s_max,
  profiles = length(profile_counts),
  rows = nrow(sample),
  elapsed_seconds = elapsed
)
manifest_path <- sub("\\.parquet$", "-manifest.csv", output_path)
write.csv(manifest, manifest_path, row.names = FALSE)
message("Wrote ", format(length(profile_counts), big.mark = ","),
        " profiles / ", format(nrow(sample), big.mark = ","), " rows to ",
        normalizePath(output_path))
message("Manifest: ", normalizePath(manifest_path))
