source(testthat::test_path("..", "..", "R", "sampler.R"))
source(testthat::test_path("..", "..", "R", "spark_sampling.R"))
source(testthat::test_path("..", "..", "R", "metadata.R"))

test_config <- function() {
  list(
    dh_m = 100,
    height_grid_tolerance_m = 0.001,
    n_layers = 50,
    k_max = 10,
    s_max = 3,
    seed = 8675309,
    validation_fraction = 0.1,
    night_buffer_hours = 0,
    target_profiles = list(train = 1500000, valid = 200000,
                           test = 200000, unseen_station = 100000),
    test_year = 2025,
    include_target_agl = TRUE,
    vid_min = 1,
    vid_min_permissive = 0,
    snapshot_id = "123",
    vpi_snapshot_id = "456",
    tables = list(
      source = "glue_catalog.vpts.data",
      profile_index = "glue_catalog.vpts.vpi",
      dim_station = "work.dim_station",
      dim_solar = "work.dim_solar",
      profile_stats = "work.profile_stats",
      profile_qc = "work.profile_qc",
      profile_thinned = "work.profile_thinned",
      profile_split = "work.profile_split",
      profile_selected = "work.profile_selected",
      profile_sampled = "work.profile_sampled"
    ),
    columns = list(station_id = "radar", timestamp = "datetime",
                   height_m = "height", density = "dens", profile_vid = "vid"),
    quality_predicates = c("n_dbz_all >= 5", "sd_vvp <= 2"),
    conventions = list(layer_height = "bottom", doy_source = "night_key",
                       polar_solar = "drop", truncate_top_at_inference = TRUE)
  )
}

test_profile <- function() {
  list(
    station_id = "KXYZ",
    ts = as.POSIXct("2025-05-02 00:00:00", tz = "UTC"),
    night_key = as.Date("2025-05-01"),
    sunset0 = as.POSIXct("2025-05-01 18:00:00", tz = "UTC"),
    sunrise = as.POSIXct("2025-05-02 06:00:00", tz = "UTC"),
    sunset1 = as.POSIXct("2025-05-02 18:00:00", tz = "UTC"),
    split = "train",
    dens = as.numeric(1:50),
    h_antenna_m = 30,
    r_antenna = 4L
  )
}
