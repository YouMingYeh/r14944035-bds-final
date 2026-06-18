-- 60_social_retention_geo.sql — three extra lenses: virality, retention, geography.
SELECT jsonb_build_object(
  'social', jsonb_build_object(
    'invited_in_payer_pct', (SELECT round(100.0*avg(is_payer::int),2) FROM player_features WHERE was_invited),
    'organic_payer_pct',    (SELECT round(100.0*avg(is_payer::int),2) FROM player_features WHERE not was_invited),
    'inviter_payer_pct',    (SELECT round(100.0*avg(is_payer::int),2) FROM player_features WHERE n_invited>0),
    'noninviter_payer_pct', (SELECT round(100.0*avg(is_payer::int),2) FROM player_features WHERE n_invited=0)
  ),
  'retention_x_pay', (
    SELECT json_agg(x ORDER BY x.ord) FROM (
      SELECT CASE WHEN active_days<1 THEN '0' WHEN active_days<7 THEN '1-6'
                  WHEN active_days<30 THEN '7-29' ELSE '30+' END bucket,
             min(active_days) ord, count(*) players, round(100.0*avg(is_payer::int),2) payer_pct
      FROM player_features GROUP BY 1) x
  ),
  'geo', (
    SELECT json_agg(x ORDER BY x.players DESC) FROM (
      SELECT country_code, count(*) players, round(100.0*avg(is_payer::int),2) payer_pct,
             round(sum(lifetime_usd)::numeric,0) usd
      FROM player_features WHERE country_code IS NOT NULL
      GROUP BY country_code ORDER BY count(*) DESC LIMIT 10) x
  )
);
