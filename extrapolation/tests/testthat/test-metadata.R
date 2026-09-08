testthat::test_that("station antenna headroom comes only from curated metadata", {
  cfg <- test_config()
  stations <- data.frame(
    station_id = c("LOW", "HIGH"), lat = c(42, 43), lon = c(-76, -77),
    h_antenna_m = c(30, 1000), is_unseen_station = c(FALSE, TRUE)
  )
  result <- prepare_station_dimension(stations, cfg)
  testthat::expect_equal(result$l_min, c(0, 10))
  testthat::expect_equal(result$r_antenna, c(10, 0))
  testthat::expect_equal(result$include, c(TRUE, FALSE))
})
