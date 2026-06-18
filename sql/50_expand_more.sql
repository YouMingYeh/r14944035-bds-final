-- 50_expand_more.sql — DEPTH: get existing payers to spend more.
-- repeat-purchase behavior, one-time vs repeat DNA, whale concentration, PRIME cross-sell.
SELECT jsonb_build_object(
  'purchase_freq', (
    SELECT json_agg(x ORDER BY x.ord) FROM (
      SELECT CASE WHEN n_purchases=1 THEN '1 (one-time)' WHEN n_purchases<=3 THEN '2-3'
                  WHEN n_purchases<=10 THEN '4-10' ELSE '11+' END bucket,
             min(n_purchases) ord, count(*) payers, round(sum(pcoin_usd)::numeric,2) usd
      FROM player_features WHERE n_purchases>=1 GROUP BY 1) x
  ),
  'one_time_vs_repeat', (
    SELECT json_agg(x) FROM (
      SELECT CASE WHEN n_purchases>=2 THEN 'repeat' ELSE 'one_time' END grp,
             count(*) players,
             round(avg(pcoins_wagered)::numeric,0) avg_wagered,
             round(avg(max_streak)::numeric,1)     avg_streak,
             round(avg(active_days)::numeric,1)    avg_active_days
      FROM player_features WHERE n_purchases>=1 GROUP BY 1) x
  ),
  'whale_concentration', (
    SELECT jsonb_build_object(
      'payers', count(*),
      'median_usd', round(percentile_cont(0.5) within group (order by lifetime_usd)::numeric,2),
      'p90_usd',   round(percentile_cont(0.9) within group (order by lifetime_usd)::numeric,2),
      'p99_usd',   round(percentile_cont(0.99) within group (order by lifetime_usd)::numeric,2),
      'max_usd',   round(max(lifetime_usd)::numeric,2)
    ) FROM player_features WHERE is_payer
  ),
  'prime_cross_sell', (
    SELECT jsonb_build_object(
      'pcoin_buyers_not_prime', count(*) filter (where n_purchases>=1 and not is_prime_real),
      'their_lifetime_usd',     round(sum(lifetime_usd) filter (where n_purchases>=1 and not is_prime_real)::numeric,2)
    ) FROM player_features
  )
);
