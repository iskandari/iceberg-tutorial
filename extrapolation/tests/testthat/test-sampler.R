testthat::test_that("feature names implement the AGL ablation", {
  cfg <- test_config()
  testthat::expect_length(feature_names(cfg), 56L)
  testthat::expect_true("target_agl_m" %in% feature_names(cfg))
  cfg$include_target_agl <- FALSE
  testthat::expect_length(feature_names(cfg), 55L)
  testthat::expect_false("target_agl_m" %in% feature_names(cfg))
})

testthat::test_that("solar cycle anchors sunset, sunrise, and following sunset", {
  ss0 <- as.POSIXct("2025-05-01 18:00:00", tz = "UTC")
  sr <- as.POSIXct("2025-05-02 06:00:00", tz = "UTC")
  ss1 <- as.POSIXct("2025-05-02 18:00:00", tz = "UTC")
  testthat::expect_equal(solar_sin_cos(ss0, ss0, sr, ss1), c(solar_sin = 0, solar_cos = 1), tolerance = 1e-12)
  testthat::expect_equal(solar_sin_cos(sr, ss0, sr, ss1), c(solar_sin = 0, solar_cos = -1), tolerance = 1e-12)
  noon <- as.POSIXct("2025-05-02 12:00:00", tz = "UTC")
  testthat::expect_equal(solar_sin_cos(noon, ss0, sr, ss1), c(solar_sin = -1, solar_cos = 0), tolerance = 1e-12)
  before_sunset <- as.POSIXct("2025-05-01 17:00:00", tz = "UTC")
  expected_phase <- -pi / 12
  testthat::expect_equal(
    solar_sin_cos(before_sunset, ss0, sr, ss1),
    c(solar_sin = sin(expected_phase), solar_cos = cos(expected_phase)),
    tolerance = 1e-12
  )
})

testthat::test_that("k draws are distinct, stable, and independent of RNG state", {
  timestamp <- as.POSIXct("2025-05-02", tz = "UTC")
  first <- draw_k("KXYZ", timestamp, 10, 3, 42)
  set.seed(999)
  stats::runif(100)
  second <- draw_k("KXYZ", timestamp, 10, 3, 42)
  testthat::expect_identical(first, second)
  testthat::expect_length(unique(first), 3L)
  testthat::expect_true(all(first %in% 1:10))
})

testthat::test_that("expansion normalizes per k and maps gaps to bottom layers", {
  cfg <- test_config()
  cfg$s_max <- 4
  cfg$vid_min <- 31
  rows <- expand_profile(test_profile(), cfg)
  testthat::expect_equal(sort(unique(rows$k)), 1:4)
  testthat::expect_equal(nrow(rows), 10L)
  assert_expanded_rows(rows, cfg)

  k4 <- rows[rows$k == 4, ]
  testthat::expect_equal(k4$slot_00, rep(5 / sum(5:50), 4))
  testthat::expect_true(all(is.na(k4[, sprintf("slot_%02d", 46:49)])))
  testthat::expect_equal(k4$target_agl_m, c(330, 230, 130, 30))
  testthat::expect_equal(k4$label, c(4, 3, 2, 1) / sum(5:50))
})

testthat::test_that("VID cap skips profiles with too little retained density", {
  cfg <- test_config()
  cfg$vid_min <- 1000
  testthat::expect_null(expand_profile(test_profile(), cfg))
})

testthat::test_that("pilot report computes expected ladder expansion", {
  cfg <- test_config()
  cfg$vid_min <- 1
  profile <- test_profile()
  profiles <- data.frame(
    station_id = profile$station_id,
    r_antenna = profile$r_antenna,
    stringsAsFactors = FALSE
  )
  profiles$dens <- list(profile$dens)
  report <- sampling_report(profiles, cfg)
  # r_eff = 4 and S = 3 => E[sum(k)] = 3 * (4 + 1) / 2 = 7.5.
  testthat::expect_equal(report$expected_rows, 7.5)
  testthat::expect_equal(report$eligible_profiles, 1)
})
