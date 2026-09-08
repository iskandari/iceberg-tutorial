# VPTS density extrapolation sampler

This directory implements the dataset-construction seam described in the VPTS
low-altitude extrapolation specification:

1. Spark reduces the long Iceberg table to profile statistics, applies QC,
   restricts profiles to `[sunset, sunrise)`, thins to one profile per
   station-hour, assigns station-night splits, samples deterministically, and
   pivots only selected profiles.
2. R computes solar/day cycles, applies the per-holdout VID cap, draws distinct
   `k` values deterministically, normalizes the retained block, and emits one
   model row per target layer.

No archive job runs merely by sourcing these files. Production validation
requires a pinned snapshot and refuses unresolved scientific inputs.

## Inputs that must be finalized

- `snapshot_id` and `vpi_snapshot_id`: Iceberg snapshots for the layer and VPI
  tables. Quote them in YAML so R does not round the 64-bit identifiers.
- `vid_min` and `vid_min_permissive`: selected from the sensitivity sweep. The
  latter prefilters full 0--5,000 m VID in `vpts.vpi`; the former protects the
  retained model-input block in the lowest 5,000 m.
- `quality_predicates`: predicates using the actual VPTS schema and approved
  thresholds. The code counts failures per predicate rather than baking them
  into one opaque flag.
- `metadata/stations.csv`: curated antenna-above-near-ground values and the
  unseen-station designation. Do not substitute `radar_height`; the existing
  export stores sea-level elevation and violates the model contract.
- A writable Iceberg catalog/S3 location. The tutorial EMR role in this repo is
  intentionally read-only and cannot materialize the six sampling stages.

The defaults fix `dh_m = 100`, `n_layers = 50`, `k_max = 10`, `S_max = 3`,
bottom-of-layer heights, day-of-year from `night_key`, and dropping polar dates
without complete solar events.

The Spark stages accept only the 50 observed 100 m bins with bottom heights
`0, 100, ..., 4900` m. Off-grid heights are rejected using the configured
millimetre-scale tolerance; they are never rounded into a neighboring bin.

## Start with one station-year

Copy `metadata/stations.csv.example` to a private or reviewed metadata file,
then build the two small dimensions locally:

```bash
Rscript extrapolation/scripts/build-metadata.R \
  path/to/stations.csv 2024-01-01 2025-12-31 path/to/metadata-output
```

Load those Parquet files as the configured `dim_station` and `dim_solar`
Iceberg tables. Fill the unresolved fields in a copy of `config.yml`, initially
pointing the source/stages at one station-year or a development catalog. Render
the exact Spark SQL for review:

```bash
Rscript extrapolation/scripts/render-spark-sql.R path/to/pilot-config.yml \
  > /tmp/vpts-extrapolation-pilot.sql
```

The generated SQL contains six separately materialized stages and three audit
queries. Both leakage queries must return zero rows. The selected-count query
reports the realized profile budget before the second archive scan/pivot.

After exporting a station-year partition of `profile_sampled` to local Parquet,
expand it and print the size estimate:

```bash
Rscript extrapolation/scripts/expand-profile-sample.R \
  path/to/profile_sampled.parquet path/to/model_rows.parquet \
  path/to/pilot-config.yml
```

The report uses each pilot profile's actual `r_eff`; it is more useful than the
full-headroom design estimate. Budgets are configured separately per split so
evaluation strata cannot consume the training allocation. At `r_eff = 10`,
`S_max = 3`, the expectation is 16.5 rows/profile, so 1.5M training profiles
produce about 24.75M rows and about 3 GiB of float32 feature values (diagnostic
columns and Parquet overhead are additional).

## Determinism and invariants

- Spark tie-breaking/splits and R `k` draws are hash-derived, never dependent
  on partition order or global RNG state.
- Reads are `VERSION AS OF snapshot_id`.
- Missing density stays missing; it is never converted to a genuine zero.
- Only profiles in the configurable station-local solar window
  (`sunset0 - night_buffer_hours <= ts < sunrise + night_buffer_hours`) enter
  thinning or any train/validation/test sample. The default buffer is zero.
- Every expanded observed block sums to one.
- Feature order is generated once by `feature_names()` and includes/excludes
  `target_agl_m` through the ablation flag.
- Raw `sunset0`, `sunrise`, and `sunset1` cross the Spark-to-R seam so solar
  events are not recomputed millions of times. Their sine/cosine features are
  still assembled only in the shared R feature path.

Run the local suite with:

```bash
Rscript extrapolation/tests/testthat.R
```
