-- 10_why_pay.sql — WHY do players pay? Returns one JSON object.
-- product mix ($ by pack), the wagering sink (the real money driver),
-- cosmetics-underused gap, and payer archetypes.
SELECT jsonb_build_object(
  'product_mix', (
    SELECT json_agg(x ORDER BY x.usd DESC NULLS LAST) FROM (
      SELECT product_id, count(*) tx, count(distinct player_id) ppl,
             round(sum(price)::numeric,2) usd
      FROM pcoin_transaction WHERE status::text='completed'
      GROUP BY product_id) x
  ),
  'wagering_by_game', (
    SELECT json_agg(x ORDER BY x.sessions DESC) FROM (
      SELECT game_type, count(*) sessions, count(distinct host_player_id) hosts,
             sum(bet_amount)::bigint pcoins_wagered
      FROM game_session GROUP BY game_type) x
  ),
  'cosmetics_gap', (
    SELECT jsonb_build_object(
      'players_with_furniture_or_wardrobe',
        count(*) filter (where furniture_cnt>0 or wardrobe_cnt>0),
      'total_players', count(*),
      'pct', round(100.0*count(*) filter (where furniture_cnt>0 or wardrobe_cnt>0)/count(*),1)
    ) FROM player_features
  ),
  'payer_archetypes', (
    SELECT json_agg(x ORDER BY x.usd DESC) FROM (
      SELECT archetype, count(*) players, round(sum(lifetime_usd)::numeric,2) usd,
             round(avg(pcoins_wagered)::numeric,0) avg_wagered,
             round(avg(max_streak)::numeric,1) avg_streak
      FROM (
        SELECT *, CASE WHEN is_prime_real THEN 'prime'
                       WHEN lifetime_usd >= 75 THEN 'whale_75+'
                       WHEN n_purchases >= 2 THEN 'repeat'
                       ELSE 'one_time' END archetype
        FROM player_features WHERE is_payer) z
      GROUP BY archetype) x
  )
);
