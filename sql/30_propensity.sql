-- 30_propensity.sql — transparent propensity-to-pay score, VALIDATED on a holdout.
-- The score is an interpretable additive of observed signals (no black box, so a studio
-- can audit why a player scored high). We persist it on player_features, then validate by
-- showing it ranks REAL payers on a 20% holdout it was not tuned on.
ALTER TABLE player_features ADD COLUMN IF NOT EXISTS propensity numeric;
UPDATE player_features SET propensity =
    least(pcoins_wagered/2000.0, 1)*30      -- wagering engagement (the money loop)
  + least(max_streak/30.0,      1)*20       -- habit / streak
  + least(n_games_hosted/20.0,  1)*15       -- social-game activity
  + least(active_days/30.0,     1)*15       -- retention
  + least(n_invited/3.0,        1)*10       -- virality
  + (CASE WHEN stated_intent THEN 10 ELSE 0 END);  -- words (weak but real signal)

WITH holdout AS (   -- deterministic 20% holdout, not used to design weights
  SELECT *, ntile(10) OVER (ORDER BY propensity) AS decile
  FROM player_features WHERE abs(hashtext(player_id::text)) % 5 = 0
),
base AS (SELECT avg(is_payer::int) r FROM holdout)
SELECT jsonb_build_object(
  'weights', jsonb_build_object('pcoins_wagered',30,'max_streak',20,'n_games_hosted',15,
                                'active_days',15,'n_invited',10,'stated_intent',10),
  'holdout_size', (SELECT count(*) FROM holdout),
  'holdout_base_payer_pct', (SELECT round(100*r::numeric,2) FROM base),
  'decile_payer_rate', (
    SELECT json_agg(x ORDER BY x.decile) FROM (
      SELECT decile, count(*) players, round(100.0*avg(is_payer::int),2) payer_pct
      FROM holdout GROUP BY decile) x
  ),
  'top_decile_lift', (
    SELECT round((avg(is_payer::int) / (SELECT r FROM base))::numeric,1)
    FROM holdout WHERE decile=10
  ),
  'top_decile_payer_pct', (
    SELECT round(100.0*avg(is_payer::int),2) FROM holdout WHERE decile=10
  )
);
