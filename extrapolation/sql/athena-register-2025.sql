CREATE DATABASE IF NOT EXISTS vpts_extrapolation;

CREATE EXTERNAL TABLE IF NOT EXISTS vpts_extrapolation.profile_sampled_2025 (
  radar string,
  datetime timestamp,
  height int,
  height_reference string,
  u double,
  v double,
  w double,
  ff double,
  dd double,
  sd_vvp double,
  gap boolean,
  eta double,
  dens double,
  dbz double,
  dbz_all double,
  n int,
  n_dbz int,
  n_all int,
  n_dbz_all int,
  rcs int,
  sd_vvp_threshold int,
  vcp int,
  radar_latitude double,
  radar_longitude double,
  radar_height int,
  radar_wavelength double,
  source_file string,
  year int,
  archive_vid double,
  night_key date,
  sunset0 timestamp,
  sunrise timestamp,
  sunset1 timestamp,
  source_snapshot_id string,
  vpi_snapshot_id string,
  vid_min double
)
PARTITIONED BY (rad string, month int)
STORED AS PARQUET
LOCATION 's3://vpts-extrapolation-863683271215/production/profile_sampled/year=2025/'
TBLPROPERTIES ('parquet.compression'='ZSTD');

MSCK REPAIR TABLE vpts_extrapolation.profile_sampled_2025;
