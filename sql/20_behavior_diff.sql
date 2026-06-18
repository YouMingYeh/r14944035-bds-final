-- 20_behavior_diff.sql — how do payers differ? Payer-rate LIFT per signal.
-- For each feature, payer rate in the "high" group vs "low" group, and the lift.
SELECT jsonb_build_object('predictor_lift', json_agg(r ORDER BY r.lift DESC NULLS LAST))
FROM (
  SELECT feature, high_pct, low_pct,
         round((high_pct/nullif(low_pct,0))::numeric,1) AS lift
  FROM (
    SELECT 'streak >= 7 days' feature,
      round(100.0*avg(is_payer::int) filter (where max_streak>=7),2) high_pct,
      round(100.0*avg(is_payer::int) filter (where max_streak<7),2)  low_pct FROM player_features
    UNION ALL SELECT 'wagered pcoins (>0)',
      round(100.0*avg(is_payer::int) filter (where pcoins_wagered>0),2),
      round(100.0*avg(is_payer::int) filter (where pcoins_wagered=0),2) FROM player_features
    UNION ALL SELECT 'hosted >= 10 minigames',
      round(100.0*avg(is_payer::int) filter (where n_games_hosted>=10),2),
      round(100.0*avg(is_payer::int) filter (where n_games_hosted<10),2) FROM player_features
    UNION ALL SELECT 'invited >= 1 friend',
      round(100.0*avg(is_payer::int) filter (where n_invited>=1),2),
      round(100.0*avg(is_payer::int) filter (where n_invited=0),2) FROM player_features
    UNION ALL SELECT 'active >= 14 days',
      round(100.0*avg(is_payer::int) filter (where active_days>=14),2),
      round(100.0*avg(is_payer::int) filter (where active_days<14),2) FROM player_features
    UNION ALL SELECT 'stated intent to pay (survey)',
      round(100.0*avg(is_payer::int) filter (where stated_intent),2),
      round(100.0*avg(is_payer::int) filter (where surveyed and not stated_intent),2) FROM player_features
    UNION ALL SELECT 'was invited in (vs organic)',
      round(100.0*avg(is_payer::int) filter (where was_invited),2),
      round(100.0*avg(is_payer::int) filter (where not was_invited),2) FROM player_features
  ) z
) r;
