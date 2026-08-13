library(sparklyr)
library(DBI)
options(rstudio.connectionObserver.errorsSuppressed = TRUE)
source("examples/helpers.R")

config <- spark_config()
config[["sparklyr.livy.jar"]] <- "https://raw.githubusercontent.com/sparklyr/sparklyr/main/inst/java/sparklyr-3.5-2.12.jar"
config[["spark.dynamicAllocation.initialExecutors"]] <- 1
config[["spark.dynamicAllocation.maxExecutors"]] <- 12

sc <- spark_connect(
  master = "http://localhost:8998",
  method = "livy",
  version = "3.5",
  config = config
)
on.exit(spark_disconnect(sc), add = TRUE)

# Question: Across the complete archive, which 100 m mean-flight-height bands
# have the highest vertically integrated density (VID)?
# Intentionally no year/week/radar filter: this scans the entire VPI table.
all_vpts <- timed_query(sc, "Archive-wide VID by flight-height band", "
  SELECT
    FLOOR(height_mean / 100) * 100 AS height_band_m,
    COUNT(*) AS observations,
    COUNT(DISTINCT radar) AS radars,
    ROUND(AVG(vid), 2) AS mean_vid,
    ROUND(PERCENTILE_APPROX(vid, 0.5), 2) AS median_vid,
    ROUND(PERCENTILE_APPROX(vid, 0.95), 2) AS p95_vid
  FROM glue_catalog.vpts.vpi
  WHERE height_mean IS NOT NULL AND NOT ISNAN(height_mean)
    AND vid IS NOT NULL AND NOT ISNAN(vid)
  GROUP BY FLOOR(height_mean / 100) * 100
  HAVING COUNT(*) >= 1000
  ORDER BY mean_vid DESC
")
print(all_vpts)

library(ggplot2)

all_vpts$height_band_f <- factor(
  all_vpts$height_band_m,
  levels = sort(unique(all_vpts$height_band_m))
)

ggplot(all_vpts, aes(x = mean_vid, y = height_band_f)) +
  geom_col(width = 0.8) +
  scale_x_continuous(
    limits = c(0, NA),
    expand = expansion(mult = c(0, 0.05))
  ) +
  scale_y_discrete(
    labels = function(x) {
      ifelse(as.numeric(as.character(x)) %% 500 == 0, x, "")
    }
  ) +
  labs(
    x = "Mean VID",
    y = "Height bin (m)",
    title = "Mean VID by height"
  ) +
  theme_classic(base_size = 14) +
  theme(
    plot.title = element_text(face = "bold"),
    axis.ticks.y = element_blank()
  )
