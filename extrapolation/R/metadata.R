prepare_station_dimension <- function(stations, cfg) {
  required <- c("station_id", "lat", "lon", "h_antenna_m", "is_unseen_station")
  missing <- setdiff(required, names(stations))
  if (length(missing)) stop("Station metadata is missing: ", paste(missing, collapse = ", "))
  if (anyDuplicated(stations$station_id)) stop("station_id must be unique.")
  numeric_fields <- c("lat", "lon", "h_antenna_m")
  if (any(!vapply(stations[numeric_fields], is.numeric, logical(1))) ||
      any(!is.finite(as.matrix(stations[numeric_fields])))) {
    stop("lat, lon, and h_antenna_m must be finite numeric values.")
  }
  if (any(stations$lat < -90 | stations$lat > 90) ||
      any(stations$lon < -180 | stations$lon > 180) ||
      any(stations$h_antenna_m < 0)) stop("Station coordinates or antenna heights are invalid.")
  stations$is_unseen_station <- as.logical(stations$is_unseen_station)
  if (anyNA(stations$is_unseen_station)) stop("is_unseen_station must be true or false.")
  stations$l_min <- floor(stations$h_antenna_m / cfg$dh_m)
  stations$r_antenna <- cfg$k_max - stations$l_min
  stations$include <- stations$r_antenna >= 1L
  stations
}

build_solar_dimension <- function(stations, start_date, end_date,
                                  polar_policy = "drop") {
  if (!requireNamespace("suncalc", quietly = TRUE)) {
    stop("Package 'suncalc' is required to build the solar dimension.")
  }
  if (!polar_policy %in% "drop") stop("Only polar_policy = 'drop' is implemented.")
  dates <- seq(as.Date(start_date), as.Date(end_date) + 1, by = "day")
  by_station <- lapply(seq_len(nrow(stations)), function(i) {
    station <- stations[i, ]
    events <- suncalc::getSunlightTimes(
      date = dates, lat = station$lat, lon = station$lon,
      keep = c("sunrise", "sunset"), tz = "UTC"
    )
    result <- data.frame(
      station_id = station$station_id,
      night_key = events$date[-length(dates)],
      sunset0 = events$sunset[-length(dates)],
      sunrise = events$sunrise[-1L],
      sunset1 = events$sunset[-1L],
      stringsAsFactors = FALSE
    )
    complete <- stats::complete.cases(result)
    result[complete, , drop = FALSE]
  })
  do.call(rbind, by_station)
}
