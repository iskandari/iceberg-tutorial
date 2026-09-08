#!/usr/bin/env Rscript

required <- c("arrow", "digest", "suncalc", "testthat", "yaml")
installed <- rownames(installed.packages())
missing <- setdiff(required, installed)
if (length(missing)) install.packages(missing, repos = "https://cloud.r-project.org")
failed <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(failed)) stop("Could not load: ", paste(failed, collapse = ", "))
message("Extrapolation sampler dependencies are installed.")
