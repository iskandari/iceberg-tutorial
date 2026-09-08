testthat::test_that("production config refuses unresolved scientific inputs", {
  cfg <- test_config()
  cfg$snapshot_id <- NULL
  testthat::expect_error(validate_pipeline_config(cfg, production = TRUE), "snapshot_id")
  cfg <- test_config()
  cfg$quality_predicates <- character()
  testthat::expect_error(validate_pipeline_config(cfg, production = TRUE), "quality_predicate")
})

testthat::test_that("SQL is snapshot-pinned, deterministic, and fixed-width", {
  cfg <- test_config()
  sql <- build_sampling_sql(cfg)
  testthat::expect_length(sql, 6L)
  testthat::expect_match(sql$profile_stats, "VERSION AS OF 123", fixed = TRUE)
  testthat::expect_match(sql$profile_stats, "glue_catalog.vpts.vpi VERSION AS OF 456", fixed = TRUE)
  testthat::expect_match(sql$profile_stats, "archive_vid", fixed = TRUE)
  testthat::expect_match(sql$profile_stats, "height >= 0 AND v.height < 5000", fixed = TRUE)
  testthat::expect_match(sql$profile_stats, "<= 0.001", fixed = TRUE)
  testthat::expect_match(sql$profile_qc, "p.ts >= s.sunset0 - INTERVAL 0 HOUR", fixed = TRUE)
  testthat::expect_match(sql$profile_qc, "p.ts < s.sunrise + INTERVAL 0 HOUR", fixed = TRUE)
  testthat::expect_match(sql$profile_qc, "EXPLODE(ARRAY", fixed = TRUE)
  testthat::expect_match(sql$profile_qc, "s.night_key = p.candidate_night_key", fixed = TRUE)
  testthat::expect_false(grepl("p.ts < s.sunset1", sql$profile_qc, fixed = TRUE))
  testthat::expect_false(any(grepl("RAND\\(|SHUFFLE\\(", sql, ignore.case = TRUE)))
  testthat::expect_equal(length(gregexpr("MAX\\(CASE WHEN layer_idx", sql$profile_sampled)[[1L]]), 50L)
  testthat::expect_match(sql$profile_sampled, "ARRAY(p.slot_00", fixed = TRUE)
  testthat::expect_match(sql$profile_split, "is_unseen_station", fixed = TRUE)
})

testthat::test_that("audit SQL covers both leakage invariants", {
  audit <- sampling_audit_sql(test_config())
  testthat::expect_setequal(names(audit), c("leakage_by_night", "unseen_leakage", "selected_counts"))
  testthat::expect_match(audit$leakage_by_night, "COUNT(DISTINCT split) > 1", fixed = TRUE)
})
