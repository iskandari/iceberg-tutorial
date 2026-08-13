#!/usr/bin/env Rscript

required <- c("sparklyr", "DBI")
installed <- rownames(installed.packages())
missing <- setdiff(required, installed)

if (length(missing)) {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
} else {
  message("Required R packages are already installed.")
}

failed <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(failed)) {
  stop("Could not load: ", paste(failed, collapse = ", "))
}

message("R setup complete: ", paste(required, collapse = ", "))

