#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 4L) {
  stop("Usage: build-metadata.R STATIONS.csv START_DATE END_DATE OUTPUT_DIR")
}
source("extrapolation/R/sampler.R")
source("extrapolation/R/metadata.R")
if (!requireNamespace("arrow", quietly = TRUE)) stop("Package 'arrow' is required.")

cfg <- read_pipeline_config()
stations <- prepare_station_dimension(read.csv(args[[1L]], stringsAsFactors = FALSE), cfg)
solar <- build_solar_dimension(stations[stations$include, ], args[[2L]], args[[3L]],
                               cfg$conventions$polar_solar)
dir.create(args[[4L]], recursive = TRUE, showWarnings = FALSE)
arrow::write_parquet(stations, file.path(args[[4L]], "dim_station.parquet"), compression = "zstd")
arrow::write_parquet(solar, file.path(args[[4L]], "dim_solar.parquet"), compression = "zstd")
message("Wrote ", nrow(stations), " stations and ", nrow(solar), " station-night solar rows.")
