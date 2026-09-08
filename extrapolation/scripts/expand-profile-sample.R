#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L || length(args) > 3L) {
  stop("Usage: expand-profile-sample.R INPUT.parquet OUTPUT.parquet [CONFIG.yml]")
}
source("extrapolation/R/sampler.R")
if (!requireNamespace("arrow", quietly = TRUE)) stop("Package 'arrow' is required.")
cfg <- read_pipeline_config(if (length(args) == 3L) args[[3L]] else "extrapolation/config.yml")
if (is.null(cfg$vid_min)) stop("Set vid_min in the config before expansion.")
profiles <- arrow::read_parquet(args[[1L]], as_data_frame = TRUE)
print(sampling_report(profiles, cfg))
rows <- lapply(seq_len(nrow(profiles)), function(i) {
  profile <- lapply(profiles, function(column) column[i])
  expand_profile(profile, cfg)
})
rows <- Filter(Negate(is.null), rows)
if (!length(rows)) stop("No profiles passed the effective-headroom filter.")
rows <- do.call(rbind, rows)
assert_expanded_rows(rows, cfg)
arrow::write_parquet(rows, args[[2L]], compression = "zstd")
message("Wrote ", nrow(rows), " expanded rows to ", args[[2L]])
