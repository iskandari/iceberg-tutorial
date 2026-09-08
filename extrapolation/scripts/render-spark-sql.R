#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
config_path <- if (length(args)) args[[1L]] else "extrapolation/config.yml"
source("extrapolation/R/sampler.R")
source("extrapolation/R/spark_sampling.R")
cfg <- read_pipeline_config(config_path, production = TRUE)
queries <- build_sampling_sql(cfg)
for (name in names(queries)) {
  cat("-- stage: ", name, "\n", queries[[name]], ";\n\n", sep = "")
}
cat("-- audits (must return zero rows for leakage checks)\n")
audits <- sampling_audit_sql(cfg)
for (name in names(audits)) cat("-- ", name, "\n", audits[[name]], ";\n\n", sep = "")
