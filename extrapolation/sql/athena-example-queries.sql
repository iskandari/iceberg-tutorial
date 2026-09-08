-- Overall size and coverage.
SELECT count(*) AS layer_rows,
       count(DISTINCT (radar, datetime)) AS profiles,
       count(DISTINCT radar) AS stations,
       min(datetime) AS first_profile,
       max(datetime) AS last_profile,
       min(height) AS min_height_m,
       max(height) AS max_height_m
FROM vpts_extrapolation.profile_sampled_2025;

-- Cheap partition-pruned summary for one radar-month.
SELECT radar, month,
       count(DISTINCT datetime) AS profiles,
       avg(archive_vid) AS mean_vid
FROM vpts_extrapolation.profile_sampled_2025
WHERE rad = 'KBUF' AND month = 5
GROUP BY radar, month;

-- Missing values by height. Filter partitions for a cheaper inspection query.
SELECT height, count(*) AS rows,
       count_if(dens IS NULL OR is_nan(dens)) AS dens_missing,
       count_if(u IS NULL OR is_nan(u)) AS u_missing,
       count_if(v IS NULL OR is_nan(v)) AS v_missing
FROM vpts_extrapolation.profile_sampled_2025
WHERE rad = 'KBUF' AND month = 5
GROUP BY height
ORDER BY height;

-- Show one actual 50-bin profile.
WITH chosen AS (
  SELECT radar, datetime
  FROM vpts_extrapolation.profile_sampled_2025
  WHERE rad = 'KBUF' AND month = 5
  GROUP BY radar, datetime
  ORDER BY datetime
  LIMIT 1
)
SELECT p.radar, p.datetime, p.height, p.dens, p.u, p.v,
       p.n_dbz_all, p.sd_vvp, p.archive_vid, p.sunset0, p.sunrise
FROM vpts_extrapolation.profile_sampled_2025 p
JOIN chosen c ON p.radar = c.radar AND p.datetime = c.datetime
WHERE p.rad = 'KBUF' AND p.month = 5
ORDER BY p.height;

-- Verify the natural keys. Both duplicate counts should be zero.
WITH row_keys AS (
  SELECT radar, datetime, height, count(*) AS n
  FROM vpts_extrapolation.profile_sampled_2025
  GROUP BY radar, datetime, height
), profile_sizes AS (
  SELECT radar, datetime, count(*) AS n
  FROM vpts_extrapolation.profile_sampled_2025
  GROUP BY radar, datetime
)
SELECT (SELECT count(*) FROM row_keys WHERE n <> 1) AS duplicate_layer_keys,
       (SELECT count(*) FROM profile_sizes WHERE n <> 50) AS non_50_bin_profiles;
