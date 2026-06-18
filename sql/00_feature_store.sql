-- 00_feature_store.sql — the core data asset.
-- Builds player_features: ONE row per non-deleted player, joining every first-party
-- signal we have (demographics + engagement + wagering + social + retention + stated
-- WTP + revealed spend/LTV) plus the learning label is_payer.
-- Keyed by player.id, which is also the RevenueCat app_user_id (the join to the revenue
-- source-of-truth). Each source is pre-aggregated per player, then left-joined onto the
-- player base, so the 1M-session / 5.8M-feeding tables collapse before the join.

DROP TABLE IF EXISTS player_features;
CREATE TABLE player_features AS
WITH base AS (
  SELECT id AS player_id, created_at, last_seen, country_code, gender, language,
         acquisition_source, invited_by_player_id, is_prime_subscriber,
         COALESCE(pcoins,0) AS pcoins_balance, COALESCE(coins,0) AS coins_balance,
         COALESCE(jsonb_array_length(login_dates),0) AS login_days,
         GREATEST(EXTRACT(EPOCH FROM (last_seen-created_at))/86400, 0) AS active_days
  FROM player WHERE NOT is_deleted
),
sv AS (  -- most recent survey per player
  SELECT DISTINCT ON (player_id) player_id,
    COALESCE(responses->>'ageRange', responses->>'age') AS age_raw,
    NULLIF(responses->>'priceFeeling','')  AS price_feeling,
    responses->'wouldPayFor'               AS would_pay_for,
    COALESCE(NULLIF(responses->>'boughtPcoins',''), NULLIF(responses->>'paymentStatus','')) AS pay_state,
    NULLIF(responses->>'halfOffWouldTry','') AS half_off
  FROM survey_response ORDER BY player_id, created_at DESC
),
rooms AS (
  SELECT player_id, MAX(current_streak) AS max_streak, COUNT(*) AS n_rooms
  FROM player_room GROUP BY player_id
),
owned AS (  -- rooms the player manages → cosmetic-spend proxy
  SELECT manager_id AS player_id,
    SUM(jsonb_array_length(COALESCE(furniture_objects,'[]'::jsonb))) AS furniture_cnt,
    SUM((SELECT count(*) FROM jsonb_object_keys(COALESCE(wardrobe_items,'{}'::jsonb)))) AS wardrobe_cnt
  FROM room WHERE manager_id IS NOT NULL GROUP BY manager_id
),
wager AS (  -- the monetization driver: pcoins wagered in minigames
  SELECT host_player_id AS player_id, COUNT(*) AS n_games_hosted,
    SUM(COALESCE(bet_amount,0)) AS pcoins_wagered,
    MODE() WITHIN GROUP (ORDER BY game_type) AS fav_game
  FROM game_session WHERE host_player_id IS NOT NULL GROUP BY host_player_id
),
feed AS  ( SELECT player_id, COUNT(*) AS n_feedings FROM pet_feeding GROUP BY player_id ),
arc AS   ( SELECT player_id, COUNT(*) AS n_arcade   FROM arcade_score GROUP BY player_id ),
social AS( SELECT invited_by_player_id AS player_id, COUNT(*) AS n_invited
           FROM player WHERE invited_by_player_id IS NOT NULL GROUP BY invited_by_player_id ),
buys AS (
  SELECT player_id, COUNT(*) AS n_purchases, SUM(price) AS lifetime_usd, MIN(created_at) AS first_buy
  FROM pcoin_transaction WHERE status::text='completed' GROUP BY player_id
),
prime AS (
  SELECT player_id, SUM(price) AS prime_usd
  FROM prime_subscription_event WHERE event_type IN ('INITIAL_PURCHASE','RENEWAL') GROUP BY player_id
)
SELECT
  b.player_id, b.created_at, b.last_seen, b.active_days, b.login_days,
  b.country_code, b.gender, b.language, b.acquisition_source,
  (b.invited_by_player_id IS NOT NULL) AS was_invited,
  CASE COALESCE(sv.age_raw,'')
    WHEN '13-17' THEN 'under_18'
    WHEN '18-24' THEN '18_24' WHEN '18-22' THEN '18_24'
    WHEN '25-34' THEN '25_34' WHEN '23-27' THEN '25_34' WHEN '28-35' THEN '25_34'
    WHEN '35-44' THEN '35_44' WHEN '36-45' THEN '35_44'
    WHEN '45-54' THEN '45_plus' WHEN '55-64' THEN '45_plus' WHEN '65+' THEN '45_plus' WHEN '46+' THEN '45_plus'
    ELSE 'unknown' END AS age_bucket,
  (sv.player_id IS NOT NULL) AS surveyed,
  sv.price_feeling, sv.pay_state, sv.half_off,
  -- lenient stated intent (said fair/cheap, or claims bought/considering, or names a paid item, or would try discount).
  -- COALESCE to false so "surveyed but no intent signal" is a real negative, not NULL.
  COALESCE(
    sv.price_feeling IN ('fair','cheap')
    OR sv.pay_state IN ('once','many','considering','pcoins_only','prime_only','both')
    OR (sv.would_pay_for IS NOT NULL AND sv.would_pay_for::text NOT IN ('[]','["nothing"]'))
    OR sv.half_off IN ('yes','maybe')
  , false) AS stated_intent,
  COALESCE(r.max_streak,0) AS max_streak, COALESCE(r.n_rooms,0) AS n_rooms,
  COALESCE(o.furniture_cnt,0) AS furniture_cnt, COALESCE(o.wardrobe_cnt,0) AS wardrobe_cnt,
  COALESCE(w.n_games_hosted,0) AS n_games_hosted, COALESCE(w.pcoins_wagered,0) AS pcoins_wagered, w.fav_game,
  COALESCE(f.n_feedings,0) AS n_feedings, COALESCE(a.n_arcade,0) AS n_arcade,
  COALESCE(s.n_invited,0) AS n_invited,
  b.pcoins_balance, b.coins_balance,
  -- REVEALED outcome + label
  COALESCE(bu.n_purchases,0) AS n_purchases,
  ROUND(COALESCE(bu.lifetime_usd,0)::numeric,2) AS pcoin_usd,
  ROUND(COALESCE(pr.prime_usd,0)::numeric,2) AS prime_usd,
  ROUND((COALESCE(bu.lifetime_usd,0)+COALESCE(pr.prime_usd,0))::numeric,2) AS lifetime_usd,
  (bu.player_id IS NOT NULL OR pr.player_id IS NOT NULL) AS is_payer,
  (pr.player_id IS NOT NULL) AS is_prime_real,
  CASE WHEN bu.first_buy IS NOT NULL
       THEN ROUND((EXTRACT(EPOCH FROM (bu.first_buy-b.created_at))/86400)::numeric,2) END AS first_buy_lag_days
FROM base b
LEFT JOIN sv     ON sv.player_id = b.player_id
LEFT JOIN rooms  r ON r.player_id  = b.player_id
LEFT JOIN owned  o ON o.player_id  = b.player_id
LEFT JOIN wager  w ON w.player_id  = b.player_id
LEFT JOIN feed   f ON f.player_id  = b.player_id
LEFT JOIN arc    a ON a.player_id  = b.player_id
LEFT JOIN social s ON s.player_id  = b.player_id
LEFT JOIN buys   bu ON bu.player_id = b.player_id
LEFT JOIN prime  pr ON pr.player_id = b.player_id;

CREATE INDEX ON player_features (is_payer);
CREATE INDEX ON player_features (player_id);
