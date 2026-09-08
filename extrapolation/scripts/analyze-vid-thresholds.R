#!/usr/bin/env Rscript

# Read-only threshold analysis against the VPTS Iceberg tables. The only remote
# write is a temporary solar-dimension Parquet object used by Spark; it is
# deleted on exit. Result CSVs are written beneath extrapolation/results/.

suppressPackageStartupMessages({
  library(DBI)
  library(sparklyr)
})

args <- commandArgs(trailingOnly = TRUE)
aws_profile <- if (length(args) >= 1L) args[[1L]] else "sso-admin"
output_dir <- if (length(args) >= 2L) args[[2L]] else "extrapolation/results"
livy_url <- if (length(args) >= 3L) args[[3L]] else "http://localhost:8998"

cfg <- yaml::read_yaml("extrapolation/config.yml")
n_layers <- as.integer(cfg$n_layers)
k_max <- as.integer(cfg$k_max)
dh_m <- as.numeric(cfg$dh_m)
if (n_layers != 50L || k_max != 10L || dh_m != 100) {
  stop("Threshold analysis expects n_layers=50, k_max=10, and dh_m=100.")
}

source("extrapolation/R/metadata.R")
if (!requireNamespace("arrow", quietly = TRUE)) stop("Package 'arrow' is required.")
if (!requireNamespace("suncalc", quietly = TRUE)) stop("Package 'suncalc' is required.")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
run_stamp <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")

spark_cfg <- spark_config()
spark_cfg[["sparklyr.livy.jar"]] <-
  "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
spark_cfg[["spark.dynamicAllocation.initialExecutors"]] <- 8
spark_cfg[["spark.dynamicAllocation.maxExecutors"]] <- 12
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.type"]] <- "apache"
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.apache.max-connections"]] <- 200
spark_cfg[["spark.sql.catalog.glue_catalog.http-client.apache.connection-acquisition-timeout-ms"]] <- 120000

message("Connecting to Livy at ", livy_url)
sc <- spark_connect(master = livy_url, method = "livy", version = "3.5", config = spark_cfg)
on.exit(try(spark_disconnect(sc), silent = TRUE), add = TRUE)

query <- function(label, sql) {
  started <- Sys.time()
  message("Running: ", label)
  result <- dbGetQuery(sc, sql)
  message(sprintf("Finished %s in %.1f seconds (%s rows)", label,
                  as.numeric(difftime(Sys.time(), started, units = "secs")),
                  format(nrow(result), big.mark = ",")))
  result
}

snapshots <- query("Iceberg snapshots", "
  SELECT 'vpi' AS table_name, snapshot_id, committed_at
  FROM glue_catalog.vpts.vpi.snapshots
  UNION ALL
  SELECT 'data' AS table_name, snapshot_id, committed_at
  FROM glue_catalog.vpts.data.snapshots
")
latest <- do.call(rbind, lapply(split(snapshots, snapshots$table_name), function(x) {
  x[which.max(x$committed_at), , drop = FALSE]
}))
write.csv(latest, file.path(output_dir, paste0("snapshots-", run_stamp, ".csv")), row.names = FALSE)

coverage <- query("VPI station and date coverage", "
  SELECT radar AS station_id, FIRST(lon, true) AS lon, FIRST(lat, true) AS lat,
         MIN(CAST(datetime AS DATE)) AS first_date,
         MAX(CAST(datetime AS DATE)) AS last_date,
         COUNT(*) AS profiles
  FROM glue_catalog.vpts.vpi
  WHERE year BETWEEN 2013 AND 2025
    AND lat BETWEEN 24 AND 50 AND lon BETWEEN -125 AND -66
  GROUP BY radar
")
if (nrow(coverage) != 143L) {
  stop("Expected 143 CONUS stations but found ", nrow(coverage), ".")
}

solar <- build_solar_dimension(
  coverage[, c("station_id", "lat", "lon")],
  min(as.Date(coverage$first_date)) - 1,
  max(as.Date(coverage$last_date)),
  polar_policy = "drop"
)
local_solar <- tempfile(pattern = "vpts-solar-", fileext = ".parquet")
arrow::write_parquet(solar, local_solar, compression = "zstd")
s3_solar <- paste0("s3://ice.bird/tutorial/vpts-extrapolation/tmp/solar-", run_stamp, ".parquet")

aws <- function(arguments) {
  status <- system2("aws", c("--profile", aws_profile, "--region", "us-east-1", arguments))
  if (!identical(status, 0L)) stop("AWS command failed with status ", status)
}
message("Uploading temporary solar lookup: ", s3_solar)
aws(c("s3", "cp", local_solar, s3_solar, "--only-show-errors"))
on.exit({
  try(aws(c("s3", "rm", s3_solar, "--only-show-errors")), silent = TRUE)
  unlink(local_solar)
}, add = TRUE)

dbExecute(sc, paste0(
  "CREATE OR REPLACE TEMP VIEW threshold_solar USING parquet OPTIONS (path '",
  s3_solar, "')"
))

night_sql <- "
  WITH candidates AS (
    SELECT v.*, candidate_night_key
    FROM glue_catalog.vpts.vpi v
    LATERAL VIEW EXPLODE(ARRAY(CAST(v.datetime AS DATE),
                               DATE_SUB(CAST(v.datetime AS DATE), 1))) nights
      AS candidate_night_key
    -- Candidate thresholds are derived only from pre-test development years.
    WHERE v.year BETWEEN 2013 AND 2024
      AND v.lat BETWEEN 24 AND 50 AND v.lon BETWEEN -125 AND -66
      AND v.vid IS NOT NULL AND NOT ISNAN(v.vid) AND v.vid >= 0
  ), joined AS (
    SELECT v.radar, v.datetime, v.lon, v.lat, v.year, MONTH(s.night_key) AS month,
           v.vid, s.night_key,
           CASE WHEN DATE_FORMAT(s.night_key, 'MM-dd') BETWEEN '03-01' AND '06-15'
                  THEN 'spring'
                WHEN DATE_FORMAT(s.night_key, 'MM-dd') BETWEEN '08-01' AND '11-15'
                  THEN 'fall' END AS season
    FROM candidates v
    JOIN threshold_solar s
      ON s.station_id = v.radar
     AND s.night_key = v.candidate_night_key
     AND v.datetime >= s.sunset0
     AND v.datetime < s.sunrise
    WHERE (DATE_FORMAT(s.night_key, 'MM-dd') BETWEEN '03-01' AND '06-15'
        OR DATE_FORMAT(s.night_key, 'MM-dd') BETWEEN '08-01' AND '11-15')
  ), hourly AS (
    SELECT radar, DATE_TRUNC('hour', datetime) AS station_hour,
           PERCENTILE_APPROX(vid, 0.5, 10000) AS hour_median
    FROM joined GROUP BY radar, DATE_TRUNC('hour', datetime)
  ), ranked AS (
    SELECT j.*, ROW_NUMBER() OVER (
      PARTITION BY j.radar, h.station_hour
      ORDER BY ABS(j.vid - h.hour_median), XXHASH64(j.radar, CAST(j.datetime AS STRING))
    ) AS hour_rank
    FROM joined j JOIN hourly h
      ON j.radar = h.radar AND DATE_TRUNC('hour', j.datetime) = h.station_hour
  )
  SELECT radar, datetime, lon, lat, year, month, vid, night_key, season
  FROM ranked WHERE hour_rank = 1
"
message("Creating and caching the corrected thinned nighttime population")
dbExecute(sc, paste0("CREATE OR REPLACE TEMP VIEW threshold_night_profiles AS ", night_sql))
dbExecute(sc, "CACHE TABLE threshold_night_profiles")
night_base <- "SELECT * FROM threshold_night_profiles"

quantiles <- query("nighttime VID quantiles", paste0("
  WITH base AS (", night_base, ")
  SELECT COUNT(*) AS profiles,
         COUNT(DISTINCT STRUCT(radar, night_key)) AS station_nights,
         PERCENTILE_APPROX(vid, 0.10, 10000) AS q10,
         PERCENTILE_APPROX(vid, 0.25, 10000) AS q25,
         PERCENTILE_APPROX(vid, 0.50, 10000) AS q50,
         PERCENTILE_APPROX(vid, 0.75, 10000) AS q75,
         PERCENTILE_APPROX(vid, 0.90, 10000) AS q90
  FROM base"))
write.csv(quantiles, file.path(output_dir, paste0("vid-quantiles-", run_stamp, ".csv")), row.names = FALSE)

thresholds <- sort(unique(signif(as.numeric(quantiles[1, c("q10", "q25", "q50", "q75", "q90")]), 2)))
thresholds <- thresholds[is.finite(thresholds) & thresholds > 0]
if (!length(thresholds)) stop("No positive candidate VID thresholds were derived.")
threshold_values <- paste0("(", format(thresholds, scientific = FALSE, trim = TRUE), "D)", collapse = ", ")
threshold_cte <- paste0("thresholds AS (SELECT * FROM VALUES ", threshold_values,
                        " AS t(threshold))")

overall <- query("candidate threshold retention", paste0("
  WITH base AS (", night_base, "), ", threshold_cte, "
  SELECT threshold,
         SUM(CASE WHEN vid >= threshold THEN 1 ELSE 0 END) AS eligible_profiles,
         COUNT(DISTINCT CASE WHEN vid >= threshold THEN STRUCT(radar, night_key) END) AS eligible_station_nights,
         COUNT(DISTINCT CASE WHEN vid >= threshold THEN radar END) AS eligible_stations,
         100.0 * AVG(CASE WHEN vid >= threshold THEN 1D ELSE 0D END) AS profile_retention_pct
  FROM base CROSS JOIN thresholds
  GROUP BY threshold ORDER BY threshold"))
write.csv(overall, file.path(output_dir, paste0("vid-threshold-overall-", run_stamp, ".csv")), row.names = FALSE)

season_region <- query("season and region retention", paste0("
  WITH base0 AS (", night_base, "), base AS (
    SELECT *, CASE WHEN lon < -100 THEN 'west' ELSE 'east' END AS region
    FROM base0
  ), ", threshold_cte, "
  SELECT threshold, season, region, COUNT(*) AS available_profiles,
         SUM(CASE WHEN vid >= threshold THEN 1 ELSE 0 END) AS eligible_profiles,
         100.0 * AVG(CASE WHEN vid >= threshold THEN 1D ELSE 0D END) AS retention_pct
  FROM base CROSS JOIN thresholds
  GROUP BY threshold, season, region
  ORDER BY threshold, season, region"))
write.csv(season_region, file.path(output_dir, paste0("vid-threshold-season-region-", run_stamp, ".csv")), row.names = FALSE)

min_threshold <- min(thresholds)
retained_columns <- paste(vapply(seq_len(k_max), function(k) sprintf(
  "SUM(CASE WHEN d.height >= %d AND d.dens IS NOT NULL AND NOT ISNAN(d.dens) THEN d.dens * %s ELSE 0D END) AS retained_%02d",
  k * dh_m, format(dh_m / 1000, scientific = FALSE), k
), character(1)), collapse = ",\n         ")
rvid_case <- paste(vapply(k_max:1, function(k) sprintf(
  "WHEN retained_%02d >= threshold THEN %d", k, k
), character(1)), collapse = "\n           ")

rvid <- query("provisional density headroom", paste0("
  WITH night_profiles AS (SELECT * FROM (", night_base, ") thinned WHERE vid >= ",
  format(min_threshold, scientific = FALSE), "), layer_stats AS (
    SELECT b.radar, b.datetime, b.night_key, b.vid AS archive_vid,
           SUM(CASE WHEN d.dens IS NOT NULL AND NOT ISNAN(d.dens) THEN 1 ELSE 0 END) AS n_present,
           ", retained_columns, "
    FROM night_profiles b
    JOIN glue_catalog.vpts.data d
      ON d.radar = b.radar AND d.datetime = b.datetime
    WHERE d.height >= 0 AND d.height < ", n_layers * dh_m,
    " AND PMOD(d.height, ", dh_m, ") = 0
    GROUP BY b.radar, b.datetime, b.night_key, b.vid
  ), ", threshold_cte, ", scored AS (
    SELECT threshold, CASE
           ", rvid_case, "
           ELSE 0 END AS r_vid
    FROM layer_stats CROSS JOIN thresholds
    WHERE n_present = ", n_layers, " AND archive_vid >= threshold
  )
  SELECT threshold, r_vid, COUNT(*) AS profiles
  FROM scored GROUP BY threshold, r_vid ORDER BY threshold, r_vid"))
write.csv(rvid, file.path(output_dir, paste0("vid-threshold-rvid-", run_stamp, ".csv")), row.names = FALSE)

message("Candidate thresholds: ", paste(thresholds, collapse = ", "), " birds/km^2")
message("Results written to ", normalizePath(output_dir))
print(overall)
print(rvid)
