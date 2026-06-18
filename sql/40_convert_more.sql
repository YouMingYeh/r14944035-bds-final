-- 40_convert_more.sql — BREADTH: convert more payers.
-- The product's core output: a ranked, look-alike target pool of high-propensity
-- non-payers (counts + profile only, no PII), plus the day-0 "conversion moment".
SELECT jsonb_build_object(
  'target_pool', (
    SELECT jsonb_build_object(
      'high_propensity_nonpayers', count(*) filter (where not is_payer and propensity>=40),
      'total_nonpayers',           count(*) filter (where not is_payer),
      'avg_wagered',  round(avg(pcoins_wagered) filter (where not is_payer and propensity>=40)::numeric,0),
      'avg_streak',   round(avg(max_streak)     filter (where not is_payer and propensity>=40)::numeric,1)
    ) FROM player_features
  ),
  'target_by_country', (
    SELECT json_agg(x ORDER BY x.targets DESC) FROM (
      SELECT country_code, count(*) targets
      FROM player_features
      WHERE not is_payer AND propensity>=40 AND country_code IS NOT NULL
      GROUP BY country_code ORDER BY count(*) DESC LIMIT 8) x
  ),
  'conversion_moment', (
    SELECT jsonb_build_object(
      'same_day_pct',   round(100.0*count(*) filter (where first_buy_lag_days<1)/count(*),1),
      'within_7d_pct',  round(100.0*count(*) filter (where first_buy_lag_days<7)/count(*),1),
      'median_lag_days', round(percentile_cont(0.5) within group (order by first_buy_lag_days)::numeric,1)
    ) FROM player_features WHERE is_payer AND first_buy_lag_days IS NOT NULL
  ),
  'wagered_before_paying_pct', (
    SELECT round(100.0*count(*) filter (where pcoins_wagered>0)/count(*),1)
    FROM player_features WHERE is_payer
  )
);
