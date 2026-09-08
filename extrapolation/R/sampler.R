# VPTS density sampling and feature construction.
#
# This file is deliberately dependency-light. `digest` is used for stateless,
# deterministic k sampling; `yaml`, `arrow`, and `xgboost` are needed only by
# their respective boundary functions.

read_pipeline_config <- function(path = "extrapolation/config.yml",
                                 production = FALSE) {
  if (!requireNamespace("yaml", quietly = TRUE)) {
    stop("Package 'yaml' is required to read the pipeline config.")
  }
  cfg <- yaml::read_yaml(path)
  validate_pipeline_config(cfg, production = production)
  cfg
}

validate_pipeline_config <- function(cfg, production = FALSE) {
  required <- c("dh_m", "height_grid_tolerance_m", "n_layers", "k_max", "s_max", "seed",
                "include_target_agl", "conventions")
  missing <- setdiff(required, names(cfg))
  if (length(missing)) stop("Missing config keys: ", paste(missing, collapse = ", "))

  scalar_positive <- function(x) length(x) == 1L && is.numeric(x) &&
    is.finite(x) && x > 0
  if (!scalar_positive(cfg$dh_m) || !scalar_positive(cfg$n_layers) ||
      !scalar_positive(cfg$k_max) || !scalar_positive(cfg$s_max)) {
    stop("dh_m, n_layers, k_max, and s_max must be positive numeric scalars.")
  }
  if (length(cfg$height_grid_tolerance_m) != 1L ||
      !is.numeric(cfg$height_grid_tolerance_m) ||
      !is.finite(cfg$height_grid_tolerance_m) || cfg$height_grid_tolerance_m < 0 ||
      cfg$height_grid_tolerance_m >= cfg$dh_m / 2) {
    stop("height_grid_tolerance_m must be between zero and half a layer.")
  }
  if (cfg$k_max >= cfg$n_layers) stop("k_max must be smaller than n_layers.")
  if (cfg$s_max > cfg$k_max) stop("s_max cannot exceed k_max.")
  if (length(cfg$night_buffer_hours) != 1L ||
      !is.numeric(cfg$night_buffer_hours) || !is.finite(cfg$night_buffer_hours) ||
      cfg$night_buffer_hours < 0 || cfg$night_buffer_hours != floor(cfg$night_buffer_hours)) {
    stop("night_buffer_hours must be a non-negative integer.")
  }
  if (!identical(cfg$conventions$layer_height, "bottom")) {
    stop("Only the reviewed bottom-of-layer height convention is implemented.")
  }
  if (!cfg$conventions$doy_source %in% c("night_key", "timestamp")) {
    stop("conventions.doy_source must be 'night_key' or 'timestamp'.")
  }
  expected_splits <- c("train", "valid", "test", "unseen_station")
  if (!is.list(cfg$target_profiles) ||
      !setequal(names(cfg$target_profiles), expected_splits) ||
      any(!is.finite(unlist(cfg$target_profiles))) ||
      any(unlist(cfg$target_profiles) < 1)) {
    stop("target_profiles must define positive budgets for train, valid, test, and unseen_station.")
  }
  if (production) {
    if (is.null(cfg$vid_min) || !is.numeric(cfg$vid_min)) stop("Set vid_min.")
    if (is.null(cfg$vid_min_permissive) || !is.numeric(cfg$vid_min_permissive)) {
      stop("Set vid_min_permissive.")
    }
    if (cfg$vid_min_permissive > cfg$vid_min) {
      stop("vid_min_permissive must be <= vid_min.")
    }
    snapshots <- list(source = cfg$snapshot_id, vpi = cfg$vpi_snapshot_id)
    if (any(vapply(snapshots, is.null, logical(1)))) {
      stop("Set snapshot_id and vpi_snapshot_id for a production build.")
    }
    valid_snapshot <- vapply(snapshots, function(value) {
      text <- as.character(value)
      length(text) == 1L && grepl("^[0-9]+$", text)
    }, logical(1))
    if (!all(valid_snapshot)) {
      stop("snapshot_id and vpi_snapshot_id must be quoted unsigned integers.")
    }
    if (!length(cfg$quality_predicates)) {
      stop("Set and review at least one quality_predicate for a production build.")
    }
  }
  invisible(cfg)
}

feature_names <- function(cfg) {
  c(
    sprintf("slot_%02d", 0:(cfg$n_layers - 1L)),
    "gap_to_lowest_observed_m",
    if (isTRUE(cfg$include_target_agl)) "target_agl_m",
    "solar_sin", "solar_cos", "doy_sin", "doy_cos"
  )
}

# Convert an xxhash64 digest to a stable uniform double. Only the leading 52 bits
# are used so the integer is exactly representable by an R double.
hash_unit <- function(...) {
  if (!requireNamespace("digest", quietly = TRUE)) {
    stop("Package 'digest' is required for deterministic sampling.")
  }
  key <- paste(vapply(list(...), function(x) {
    if (inherits(x, "POSIXt")) format(x, "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")
    else as.character(x)
  }, character(1)), collapse = "\x1f")
  hex <- substr(digest::digest(key, algo = "xxhash64", serialize = FALSE), 1L, 13L)
  hi <- strtoi(substr(hex, 1L, 6L), base = 16L)
  lo <- strtoi(substr(hex, 7L, 13L), base = 16L)
  (hi * 16^7 + lo) / 16^13
}

draw_k <- function(station_id, timestamp, r_eff, s, seed) {
  r_eff <- as.integer(r_eff)
  s <- as.integer(s)
  if (length(r_eff) != 1L || is.na(r_eff) || r_eff < 1L) {
    stop("r_eff must be a positive integer.")
  }
  if (length(s) != 1L || is.na(s) || s < 1L || s > r_eff) {
    stop("s must be between 1 and r_eff.")
  }
  scores <- vapply(seq_len(r_eff), function(k) {
    hash_unit(station_id, timestamp, k, seed)
  }, numeric(1))
  order(scores, seq_len(r_eff))[seq_len(s)]
}

solar_sin_cos <- function(timestamp, sunset0, sunrise, sunset1) {
  times <- as.POSIXct(c(timestamp, sunset0, sunrise, sunset1), tz = "UTC")
  if (anyNA(times)) return(c(solar_sin = NA_real_, solar_cos = NA_real_))
  t <- as.numeric(times[1L])
  ss0 <- as.numeric(times[2L])
  sr <- as.numeric(times[3L])
  ss1 <- as.numeric(times[4L])
  if (!(t < ss1 && ss0 < sr && sr < ss1)) {
    stop("Solar events must satisfy timestamp < sunset1 and sunset0 < sunrise < sunset1.")
  }
  phase <- if (t < sr) pi * (t - ss0) / (sr - ss0) else
    pi + pi * (t - sr) / (ss1 - sr)
  c(solar_sin = sin(phase), solar_cos = cos(phase))
}

day_of_year <- function(x) {
  as.integer(format(as.Date(x), "%j"))
}

build_feature_rows <- function(dens_observed, edge_agl_m, gaps_m, timestamp,
                               sunset0, sunrise, sunset1, doy, cfg) {
  dens_observed <- as.numeric(dens_observed)
  gaps_m <- as.numeric(gaps_m)
  if (!length(dens_observed) || length(dens_observed) > cfg$n_layers) {
    stop("dens_observed must contain between 1 and n_layers values.")
  }
  if (!length(gaps_m) || anyNA(gaps_m) || any(gaps_m <= 0) ||
      max(gaps_m) > cfg$k_max * cfg$dh_m) {
    stop("Target gaps must be positive and within k_max * dh_m.")
  }

  if (isTRUE(cfg$conventions$truncate_top_at_inference)) {
    m_max <- cfg$n_layers - ceiling(max(gaps_m) / cfg$dh_m)
    if (m_max < 1L) stop("Target gaps leave no usable observed layers.")
    dens_observed <- head(dens_observed, min(length(dens_observed), m_max))
  }

  dens_sum <- sum(dens_observed, na.rm = TRUE)
  if (!is.finite(dens_sum) || dens_sum <= 0) return(NULL)
  x_profile <- c(dens_observed / dens_sum,
                 rep(NA_real_, cfg$n_layers - length(dens_observed)))
  solar <- solar_sin_cos(timestamp, sunset0, sunrise, sunset1)
  cyc <- c(solar, doy_sin = sin(2 * pi * doy / 365.25),
           doy_cos = cos(2 * pi * doy / 365.25))
  if (any(!is.finite(cyc))) return(NULL)

  rows <- lapply(gaps_m, function(gap) {
    c(
      x_profile,
      gap,
      if (isTRUE(cfg$include_target_agl)) edge_agl_m - gap,
      cyc
    )
  })
  x <- do.call(rbind, rows)
  storage.mode(x) <- "double"
  colnames(x) <- feature_names(cfg)
  list(X = x, dens_sum = dens_sum, gaps_m = gaps_m)
}

profile_value <- function(profile, name) {
  value <- profile[[name]]
  if (is.null(value) || !length(value)) stop("Profile is missing '", name, "'.")
  value[[1L]]
}

expand_profile <- function(profile, cfg) {
  dens_value <- profile$dens
  if (is.list(dens_value)) dens_value <- dens_value[[1L]]
  dens <- as.numeric(dens_value)
  if (length(dens) != cfg$n_layers) {
    stop("profile$dens must have exactly n_layers values, lowest layer first.")
  }
  if (any(!is.finite(dens))) {
    stop("Training profiles must be complete and finite before expansion.")
  }
  r_antenna <- min(as.integer(profile_value(profile, "r_antenna")), cfg$k_max)
  if (r_antenna < 1L) return(NULL)
  if (is.null(cfg$vid_min) || !is.numeric(cfg$vid_min)) stop("Set cfg$vid_min before expansion.")

  vid_from <- rev(cumsum(rev(dens))) * (cfg$dh_m / 1000)
  candidate_k <- seq_len(r_antenna)
  passes <- vid_from[candidate_k + 1L] >= cfg$vid_min
  r_vid <- if (any(passes)) max(candidate_k[passes]) else 0L
  r_eff <- min(r_antenna, r_vid)
  if (r_eff < 1L) return(NULL)

  timestamp <- profile_value(profile, "ts")
  ks <- draw_k(profile_value(profile, "station_id"), timestamp, r_eff,
               min(cfg$s_max, r_eff), cfg$seed)
  doy_value <- if (identical(cfg$conventions$doy_source, "night_key")) {
    day_of_year(profile_value(profile, "night_key"))
  } else day_of_year(timestamp)

  expanded <- lapply(ks, function(k) {
    gaps <- seq_len(k) * cfg$dh_m
    fr <- build_feature_rows(
      dens_observed = dens[(k + 1L):cfg$n_layers],
      edge_agl_m = profile_value(profile, "h_antenna_m") + k * cfg$dh_m,
      gaps_m = gaps,
      timestamp = timestamp,
      sunset0 = profile_value(profile, "sunset0"),
      sunrise = profile_value(profile, "sunrise"),
      sunset1 = profile_value(profile, "sunset1"),
      doy = doy_value,
      cfg = cfg
    )
    if (is.null(fr)) return(NULL)
    target_index <- k + 1L - as.integer(fr$gaps_m / cfg$dh_m)
    metadata <- data.frame(
      label = dens[target_index] / fr$dens_sum,
      k = rep.int(k, length(fr$gaps_m)),
      gap_m = fr$gaps_m,
      station_id = rep.int(as.character(profile_value(profile, "station_id")), length(fr$gaps_m)),
      ts = rep(as.POSIXct(timestamp, tz = "UTC"), length(fr$gaps_m)),
      split = rep.int(as.character(profile_value(profile, "split")), length(fr$gaps_m)),
      dens_sum = rep.int(fr$dens_sum, length(fr$gaps_m)),
      stringsAsFactors = FALSE
    )
    cbind(as.data.frame(fr$X, check.names = FALSE), metadata)
  })
  expanded <- Filter(Negate(is.null), expanded)
  if (!length(expanded)) NULL else do.call(rbind, expanded)
}

effective_headroom <- function(profile, cfg) {
  dens_value <- profile$dens
  if (is.list(dens_value)) dens_value <- dens_value[[1L]]
  dens <- as.numeric(dens_value)
  if (length(dens) != cfg$n_layers || any(!is.finite(dens))) return(0L)
  r_antenna <- min(as.integer(profile_value(profile, "r_antenna")), cfg$k_max)
  if (r_antenna < 1L) return(0L)
  vid_from <- rev(cumsum(rev(dens))) * (cfg$dh_m / 1000)
  passing <- seq_len(r_antenna)[vid_from[seq_len(r_antenna) + 1L] >= cfg$vid_min]
  if (!length(passing)) 0L else as.integer(min(r_antenna, max(passing)))
}

sampling_report <- function(profiles, cfg, bytes_per_value = 4) {
  if (!nrow(profiles)) stop("profiles is empty.")
  r_eff <- vapply(seq_len(nrow(profiles)), function(i) {
    p <- lapply(profiles, function(column) column[i])
    effective_headroom(p, cfg)
  }, integer(1))
  kept <- r_eff > 0L
  rows <- if (any(kept)) vapply(r_eff[kept], function(r) {
    # Each selected k emits k rows. This is the exact expectation for a
    # uniformly drawn subset of min(s_max, r) distinct k values.
    min(cfg$s_max, r) * (r + 1) / 2
  }, numeric(1)) else numeric(0)
  n_features <- length(feature_names(cfg))
  data.frame(
    input_profiles = nrow(profiles),
    eligible_profiles = sum(kept),
    eligible_fraction = mean(kept),
    expected_rows = sum(rows),
    expected_rows_per_input_profile = sum(rows) / nrow(profiles),
    estimated_feature_gib = sum(rows) * n_features * bytes_per_value / 1024^3,
    stringsAsFactors = FALSE
  )
}

assert_expanded_rows <- function(rows, cfg, tolerance = 1e-9) {
  if (is.null(rows) || !nrow(rows)) stop("No expanded rows to validate.")
  slots <- sprintf("slot_%02d", 0:(cfg$n_layers - 1L))
  expected_features <- feature_names(cfg)
  if (!identical(names(rows)[seq_along(expected_features)], expected_features)) {
    stop("Feature columns are absent or out of order.")
  }
  sums <- rowSums(as.matrix(rows[, slots, drop = FALSE]), na.rm = TRUE)
  if (any(abs(sums - 1) > tolerance)) stop("Observed profile slots do not sum to one.")
  allowed_gaps <- seq_len(cfg$k_max) * cfg$dh_m
  if (any(!rows$gap_m %in% allowed_gaps) || any(rows$gap_m <= 0)) stop("Invalid target gap.")
  if (isTRUE(cfg$include_target_agl) && any(rows$target_agl_m < 0)) stop("Negative target AGL.")
  cyc <- c("solar_sin", "solar_cos", "doy_sin", "doy_cos")
  if (any(!is.finite(as.matrix(rows[, cyc, drop = FALSE])))) stop("Non-finite cyclical feature.")
  invisible(rows)
}

predict_below_edge <- function(booster, dens_observed, edge_agl_m,
                               target_depths_m, timestamp, sunset0, sunrise,
                               sunset1, doy, cfg) {
  if (!requireNamespace("xgboost", quietly = TRUE)) stop("Package 'xgboost' is required.")
  fr <- build_feature_rows(dens_observed, edge_agl_m, target_depths_m,
                           timestamp, sunset0, sunrise, sunset1, doy, cfg)
  if (is.null(fr)) return(NULL)
  model_features <- xgboost::xgb.attributes(booster)[["feature_names"]]
  if (!is.null(model_features) && !identical(colnames(fr$X), strsplit(model_features, "\\|")[[1L]])) {
    stop("Feature columns do not match the booster artifact.")
  }
  as.numeric(stats::predict(booster, xgboost::xgb.DMatrix(fr$X))) * fr$dens_sum
}
