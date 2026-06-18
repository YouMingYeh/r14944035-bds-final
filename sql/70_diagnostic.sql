-- 70_diagnostic.sql — the system's headline output: size each monetization lever in $
-- and rank them, so the studio knows WHERE the upside is. Assumptions are explicit and
-- conservative; figures are directional upside (to be confirmed by live A/B).
WITH p AS (
  SELECT
    count(*) filter (where not is_payer and propensity>=40)               AS hp_nonpayers,
    count(*) filter (where n_purchases=1)                                  AS one_timers,
    count(*) filter (where n_purchases>=1 and not is_prime_real)           AS prime_candidates,
    avg(lifetime_usd) filter (where is_payer)                              AS arppu,
    avg(lifetime_usd) filter (where n_purchases>=2)                        AS repeat_arppu,
    avg(lifetime_usd) filter (where n_purchases=1)                         AS onetime_arppu
  FROM player_features
)
SELECT jsonb_build_object('levers', json_agg(l ORDER BY l.est_upside_usd DESC))
FROM (
  SELECT 'Convert high-propensity non-payers' lever, hp_nonpayers pool,
         '3% convert × avg payer LTV' assumption,
         round((hp_nonpayers*0.03*arppu)::numeric,0) est_upside_usd FROM p
  UNION ALL
  SELECT 'Turn one-time buyers into repeat', one_timers,
         '15% make a 2nd purchase × (repeat − one-time LTV)',
         round((one_timers*0.15*greatest(repeat_arppu-onetime_arppu,0))::numeric,0) FROM p
  UNION ALL
  SELECT 'Cross-sell PRIME to pcoin buyers', prime_candidates,
         '5% subscribe × $48/yr',
         round((prime_candidates*0.05*48)::numeric,0) FROM p
) l;
