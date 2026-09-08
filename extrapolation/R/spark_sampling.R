# Spark SQL generation for the narrow-first VPTS profile sampler.

sql_identifier <- function(x, label = "SQL identifier") {
  if (length(x) != 1L || !grepl("^[A-Za-z_][A-Za-z0-9_.]*$", x)) {
    stop(label, " contains unsupported characters: ", x)
  }
  x
}

sql_number <- function(x, label) {
  if (length(x) != 1L || !is.numeric(x) || !is.finite(x)) stop(label, " must be numeric.")
  format(x, scientific = FALSE, trim = TRUE)
}

sql_integer_literal <- function(x, label) {
  value <- as.character(x)
  if (length(value) != 1L || !grepl("^[0-9]+$", value)) {
    stop(label, " must be an unsigned integer literal.")
  }
  value
}

snapshot_table <- function(table, snapshot_id, alias = NULL) {
  table <- sql_identifier(table, "snapshot table")
  snapshot <- sql_integer_literal(snapshot_id, "snapshot_id")
  paste(table, "VERSION AS OF", snapshot, if (!is.null(alias)) alias else "")
}

snapshot_source <- function(cfg, alias = NULL) {
  snapshot_table(cfg$tables$source, cfg$snapshot_id, alias)
}

create_table_as <- function(table, select_sql, partitions = NULL) {
  partition_sql <- if (is.null(partitions)) "" else
    paste0("\nPARTITIONED BY (", paste(partitions, collapse = ", "), ")")
  paste0("CREATE OR REPLACE TABLE ", sql_identifier(table),
         "\nUSING iceberg", partition_sql, "\nAS\n", select_sql)
}

build_profile_stats_sql <- function(cfg) {
  validate_pipeline_config(cfg, production = TRUE)
  col <- lapply(cfg$columns, sql_identifier)
  predicates <- unlist(cfg$quality_predicates, use.names = FALSE)
  fail_columns <- vapply(seq_along(predicates), function(i) {
    sprintf("SUM(CASE WHEN (%s) THEN 0 ELSE 1 END) AS n_fail_qc_%02d",
            predicates[[i]], i)
  }, character(1))
  select_sql <- paste0(
    "WITH candidates AS (\n",
    "  SELECT i.", col$station_id, " AS station_id, i.", col$timestamp, " AS ts,\n",
    "         i.", col$profile_vid, " AS archive_vid\n",
    "  FROM ", snapshot_table(cfg$tables$profile_index, cfg$vpi_snapshot_id, "i"), "\n",
    "  WHERE i.", col$profile_vid, " IS NOT NULL AND NOT ISNAN(i.", col$profile_vid, ")\n",
    "    AND i.", col$profile_vid, " >= ",
    sql_number(cfg$vid_min_permissive, "vid_min_permissive"), "\n",
    "    AND i.", col$station_id, " IN (SELECT station_id FROM ",
    sql_identifier(cfg$tables$dim_station), " WHERE include)\n",
    ")\n",
    "SELECT c.station_id, c.ts, YEAR(c.ts) AS yr,\n",
    "       MAX(c.archive_vid) AS archive_vid,\n",
    "       SUM(CASE WHEN v.", col$density, " IS NOT NULL AND NOT ISNAN(v.",
    col$density, ") THEN v.", col$density, " ELSE 0D END) * ",
    sql_number(cfg$dh_m / 1000, "dh_km"), " AS vid_total,\n",
    "       SUM(CASE WHEN v.", col$density, " IS NOT NULL AND NOT ISNAN(v.",
    col$density, ") THEN 1 ELSE 0 END) AS n_present,\n       ",
    paste(fail_columns, collapse = ",\n       "), "\n",
    "FROM ", snapshot_source(cfg, "v"), " JOIN candidates c\n",
    "  ON v.", col$station_id, " = c.station_id AND v.", col$timestamp, " = c.ts\n",
    "WHERE v.", col$height_m, " >= 0 AND v.", col$height_m, " < ",
    sql_number(cfg$n_layers * cfg$dh_m, "profile_top_m"), "\n",
    "  AND ABS(v.", col$height_m, " - ROUND(v.", col$height_m, " / ",
    sql_number(cfg$dh_m, "dh_m"), ") * ", sql_number(cfg$dh_m, "dh_m"), ") <= ",
    sql_number(cfg$height_grid_tolerance_m, "height_grid_tolerance_m"), "\n",
    "GROUP BY c.station_id, c.ts"
  )
  create_table_as(cfg$tables$profile_stats, select_sql, c("yr", "station_id"))
}

build_profile_qc_sql <- function(cfg) {
  fail_checks <- sprintf("n_fail_qc_%02d = 0", seq_along(cfg$quality_predicates))
  buffer_hours <- as.integer(cfg$night_buffer_hours)
  select_sql <- paste0(
    "WITH candidates AS (\n",
    "  SELECT p.*, candidate_night_key\n",
    "  FROM ", sql_identifier(cfg$tables$profile_stats), " p\n",
    "  LATERAL VIEW EXPLODE(ARRAY(CAST(p.ts AS DATE), DATE_SUB(CAST(p.ts AS DATE), 1))) nights\n",
    "    AS candidate_night_key\n",
    ")\n",
    "SELECT p.* EXCEPT (candidate_night_key), s.night_key, s.sunset0, s.sunrise, s.sunset1\n",
    "FROM candidates p\n",
    "JOIN ", sql_identifier(cfg$tables$dim_solar), " s\n",
    "  ON s.station_id = p.station_id\n",
    " AND s.night_key = p.candidate_night_key\n",
    " AND p.ts >= s.sunset0 - INTERVAL ", buffer_hours, " HOUR\n",
    " AND p.ts < s.sunrise + INTERVAL ", buffer_hours, " HOUR\n",
    "WHERE p.n_present = ", as.integer(cfg$n_layers), "\n",
    "  AND ", paste(fail_checks, collapse = "\n  AND ")
  )
  create_table_as(cfg$tables$profile_qc, select_sql, c("yr", "station_id"))
}

build_profile_thinned_sql <- function(cfg) {
  q <- sql_identifier(cfg$tables$profile_qc)
  seed <- sql_number(cfg$seed, "seed")
  stat_columns <- c("station_id", "ts", "yr", "archive_vid", "vid_total", "n_present",
                    "night_key", "sunset0", "sunrise", "sunset1",
                    sprintf("n_fail_qc_%02d", seq_along(cfg$quality_predicates)))
  select_sql <- paste0(
    "WITH hourly AS (\n",
    "  SELECT station_id, DATE_TRUNC('hour', ts) AS station_hour,\n",
    "         PERCENTILE_APPROX(vid_total, 0.5, 10000) AS hour_median\n",
    "  FROM ", q, " GROUP BY station_id, DATE_TRUNC('hour', ts)\n",
    "), ranked AS (\n",
    "  SELECT q.*, ROW_NUMBER() OVER (\n",
    "           PARTITION BY q.station_id, h.station_hour\n",
    "           ORDER BY ABS(q.vid_total - h.hour_median),\n",
    "                    XXHASH64(q.station_id, CAST(q.ts AS STRING), CAST(", seed,
    " AS STRING))\n",
    "         ) AS hour_rank\n",
    "  FROM ", q, " q JOIN hourly h\n",
    "    ON q.station_id = h.station_id\n",
    "   AND DATE_TRUNC('hour', q.ts) = h.station_hour\n",
    ")\nSELECT ", paste(stat_columns, collapse = ", "),
    " FROM ranked WHERE hour_rank = 1"
  )
  create_table_as(cfg$tables$profile_thinned, select_sql, c("yr", "station_id"))
}

build_profile_split_sql <- function(cfg) {
  t <- sql_identifier(cfg$tables$profile_thinned)
  stations <- sql_identifier(cfg$tables$dim_station)
  seed <- sql_number(cfg$seed, "seed")
  valid_fraction <- sql_number(cfg$validation_fraction, "validation_fraction")
  test_year <- as.integer(cfg$test_year)
  select_sql <- paste0(
    "WITH keyed AS (SELECT * FROM ", t, "), night_means AS (\n",
    "  SELECT station_id, night_key, YEAR(night_key) AS night_year,\n",
    "         MONTH(night_key) AS season_bin, AVG(vid_total) AS night_vid\n",
    "  FROM keyed GROUP BY station_id, night_key\n",
    "), nights AS (\n",
    "  SELECT n.*, d.is_unseen_station,\n",
    "         NTILE(10) OVER (ORDER BY night_vid) AS intensity_decile\n",
    "  FROM night_means n JOIN ", stations, " d USING (station_id)\n",
    "), eligible AS (\n",
    "  SELECT n.*,\n",
    "         ROW_NUMBER() OVER (PARTITION BY season_bin, intensity_decile\n",
    "           ORDER BY XXHASH64(station_id, CAST(night_key AS STRING), CAST(", seed,
    " AS STRING))) AS validation_rank,\n",
    "         COUNT(*) OVER (PARTITION BY season_bin, intensity_decile) AS candidate_count\n",
    "  FROM nights n WHERE NOT is_unseen_station AND night_year <> ", test_year, "\n",
    "), labelled AS (\n",
    "  SELECT station_id, night_key, season_bin, intensity_decile,\n",
    "         CASE WHEN validation_rank <= CEIL(candidate_count * ", valid_fraction,
    ") THEN 'valid' ELSE 'train' END AS split\n",
    "  FROM eligible\n",
    "  UNION ALL\n",
    "  SELECT station_id, night_key, season_bin, intensity_decile,\n",
    "         CASE WHEN is_unseen_station THEN 'unseen_station' ELSE 'test' END AS split\n",
    "  FROM nights WHERE is_unseen_station OR night_year = ", test_year, "\n",
    ")\n",
    "SELECT k.*, l.split, l.season_bin, l.intensity_decile\n",
    "FROM keyed k JOIN labelled l USING (station_id, night_key)"
  )
  create_table_as(cfg$tables$profile_split, select_sql, c("split", "yr"))
}

build_profile_selected_sql <- function(cfg) {
  split <- sql_identifier(cfg$tables$profile_split)
  seed <- sql_number(cfg$seed, "seed")
  budgets <- cfg$target_profiles[c("train", "valid", "test", "unseen_station")]
  budget_values <- paste(vapply(names(budgets), function(name) {
    sprintf("('%s', %d)", name, as.integer(budgets[[name]]))
  }, character(1)), collapse = ", ")
  # A common quota balances all non-empty strata. Sparse strata can make the
  # realized count smaller; sampling_report() exposes that before pass 3.
  select_sql <- paste0(
    "WITH ranked AS (\n",
    "  SELECT s.*, ROW_NUMBER() OVER (\n",
    "    PARTITION BY split, season_bin, HOUR(ts), intensity_decile, station_id\n",
    "    ORDER BY XXHASH64(station_id, CAST(ts AS STRING), CAST(", seed,
    " AS STRING))) AS stratum_rank\n",
    "  FROM ", split, " s\n",
    "), counts AS (\n",
    "  SELECT split, COUNT(DISTINCT STRUCT(season_bin, HOUR(ts), intensity_decile, station_id)) AS n_strata\n",
    "  FROM ranked GROUP BY split\n",
    "), budgets AS (\n",
    "  SELECT * FROM VALUES ", budget_values, " AS b(split, target_profiles)\n",
    ")\n",
    "SELECT station_id, ts, night_key, sunset0, sunrise, sunset1, split, yr,\n",
    "       season_bin, intensity_decile, vid_total\n",
    "FROM ranked JOIN counts USING (split) JOIN budgets USING (split)\n",
    "WHERE stratum_rank <= CEIL(target_profiles / n_strata)"
  )
  create_table_as(cfg$tables$profile_selected, select_sql, c("split", "yr"))
}

build_profile_sampled_sql <- function(cfg) {
  selected <- sql_identifier(cfg$tables$profile_selected)
  stations <- sql_identifier(cfg$tables$dim_station)
  col <- lapply(cfg$columns, sql_identifier)
  slots <- vapply(0:(cfg$n_layers - 1L), function(i) {
    sprintf("MAX(CASE WHEN layer_idx = %d THEN dens END) AS slot_%02d", i, i)
  }, character(1))
  slot_names <- sprintf("p.slot_%02d", 0:(cfg$n_layers - 1L))
  select_sql <- paste0(
    "WITH sel AS (SELECT /*+ BROADCAST */ * FROM ", selected, "), raw AS (\n",
    "  SELECT v.", col$station_id, " AS station_id, v.", col$timestamp, " AS ts,\n",
    "         CAST(ROUND(v.", col$height_m, " / ", cfg$dh_m, ") AS INT) AS layer_idx,\n",
    "         CASE WHEN ISNAN(v.", col$density, ") THEN NULL ELSE v.", col$density, " END AS dens\n",
    "  FROM ", snapshot_source(cfg, "v"), " JOIN sel s\n",
    "    ON v.", col$station_id, " = s.station_id AND v.", col$timestamp, " = s.ts\n",
    "  WHERE v.", col$height_m, " >= 0 AND v.", col$height_m, " < ",
    sql_number(cfg$n_layers * cfg$dh_m, "profile_top_m"), "\n",
    "    AND ABS(v.", col$height_m, " - ROUND(v.", col$height_m, " / ",
    cfg$dh_m, ") * ", cfg$dh_m, ") <= ",
    sql_number(cfg$height_grid_tolerance_m, "height_grid_tolerance_m"), "\n",
    "), pivoted AS (\n",
    "  SELECT station_id, ts,\n         ", paste(slots, collapse = ",\n         "), "\n",
    "  FROM raw GROUP BY station_id, ts\n",
    ")\n",
    "SELECT s.station_id, s.ts, s.night_key, s.sunset0, s.sunrise, s.sunset1,\n",
    "       s.split, s.yr, ARRAY(", paste(slot_names, collapse = ", "), ") AS dens,\n",
    "       d.h_antenna_m, d.r_antenna, d.lat, d.lon, s.vid_total,\n",
    "       CAST(", sql_integer_literal(cfg$snapshot_id, "snapshot_id"), " AS BIGINT) AS snapshot_id\n",
    "FROM sel s JOIN pivoted p USING (station_id, ts)\n",
    "JOIN ", stations, " d USING (station_id)"
  )
  create_table_as(cfg$tables$profile_sampled, select_sql, c("split", "yr"))
}

build_sampling_sql <- function(cfg) {
  validate_pipeline_config(cfg, production = TRUE)
  list(
    profile_stats = build_profile_stats_sql(cfg),
    profile_qc = build_profile_qc_sql(cfg),
    profile_thinned = build_profile_thinned_sql(cfg),
    profile_split = build_profile_split_sql(cfg),
    profile_selected = build_profile_selected_sql(cfg),
    profile_sampled = build_profile_sampled_sql(cfg)
  )
}

sampling_audit_sql <- function(cfg) {
  split <- sql_identifier(cfg$tables$profile_split)
  selected <- sql_identifier(cfg$tables$profile_selected)
  list(
    leakage_by_night = paste0("SELECT station_id, night_key FROM ", split,
      " GROUP BY station_id, night_key HAVING COUNT(DISTINCT split) > 1"),
    unseen_leakage = paste0("SELECT station_id FROM ", split,
      " GROUP BY station_id HAVING COUNT(DISTINCT CASE WHEN split = 'unseen_station' THEN 'unseen' ELSE 'seen' END) > 1"),
    selected_counts = paste0("SELECT split, COUNT(*) AS profiles FROM ", selected,
      " GROUP BY split ORDER BY split")
  )
}
