-- 15_payer_dna.sql — deep cross-analysis of the betting economy (why/who pays).
-- Builds a per-player game-economy table from game_session (unnesting the jsonb
-- participants array + the text[] winner_ids), then cross-tabs paying against the
-- gambling mechanics the headline cuts miss: loss-chasing, stake size, game type,
-- and the two distinct payer psychologies (net-winner whales vs net-loser refillers).
CREATE TEMP TABLE pgs AS
SELECT (elem->>'playerId')::uuid AS player_id,
       count(*) games, sum(bet_amount) wagered,
       count(*) FILTER (WHERE (elem->>'playerId') = ANY(winner_ids)) wins,
       COALESCE(sum(total_pot) FILTER (WHERE (elem->>'playerId') = ANY(winner_ids)),0) won
FROM (SELECT jsonb_array_elements(participants) elem, bet_amount, total_pot, winner_ids
      FROM game_session WHERE jsonb_typeof(participants)='array') g
WHERE elem->>'playerId' IS NOT NULL
GROUP BY 1;
CREATE INDEX ON pgs(player_id);

SELECT jsonb_build_object(
  'loss_chasing', (   -- net pcoin outcome (won - wagered) -> payer rate (the J-curve)
    SELECT json_agg(x ORDER BY x.ord) FROM (
      SELECT ord, bucket, count(*) players, round(100.0*avg(f.is_payer::int),2) payer_pct
      FROM (SELECT player_id,
              CASE WHEN won-wagered < -5000 THEN 1 WHEN won-wagered<-500 THEN 2
                   WHEN won-wagered<=500 THEN 3 WHEN won-wagered<=5000 THEN 4 ELSE 5 END ord,
              CASE WHEN won-wagered < -5000 THEN 'big_loser' WHEN won-wagered<-500 THEN 'loser'
                   WHEN won-wagered<=500 THEN 'even' WHEN won-wagered<=5000 THEN 'winner'
                   ELSE 'big_winner' END bucket FROM pgs) z
      JOIN player_features f USING(player_id) GROUP BY ord, bucket) x),
  'bet_size_lift', (  -- avg stake per game -> payer rate
    SELECT json_agg(x ORDER BY x.ord) FROM (
      SELECT ord, bucket, count(*) players, round(100.0*avg(f.is_payer::int),2) payer_pct
      FROM (SELECT player_id,
              CASE WHEN wagered/games<100 THEN 1 WHEN wagered/games<300 THEN 2
                   WHEN wagered/games<800 THEN 3 ELSE 4 END ord,
              CASE WHEN wagered/games<100 THEN '<100' WHEN wagered/games<300 THEN '100-300'
                   WHEN wagered/games<800 THEN '300-800' ELSE '800+' END bucket
            FROM pgs WHERE games>0) z
      JOIN player_features f USING(player_id) GROUP BY ord, bucket) x),
  'game_type_pay', (  -- payer rate by favourite game
    SELECT json_agg(x ORDER BY x.payer_pct DESC) FROM (
      SELECT fav_game, count(*) players, round(100.0*avg(is_payer::int),2) payer_pct
      FROM player_features WHERE fav_game IS NOT NULL GROUP BY fav_game) x),
  'payer_psychology', (  -- whales vs regular payers: winners vs loss-refillers
    SELECT json_agg(x) FROM (
      SELECT grp, count(*) players, round(avg(g.games),0) avg_games,
             round(avg(100.0*g.wins/nullif(g.games,0)),1) win_rate,
             round(avg(g.wagered),0) avg_wagered, round(avg(g.won-g.wagered),0) avg_net_pcoins
      FROM (SELECT player_id, CASE WHEN lifetime_usd>=75 THEN 'whale_75+'
                                   ELSE 'regular_payer' END grp
            FROM player_features WHERE is_payer AND lifetime_usd>0) f
      JOIN pgs g USING(player_id) GROUP BY grp) x),
  'why_never_bought', (  -- survey: non-payers' stated barrier
    SELECT json_agg(x ORDER BY x.n DESC) FROM (
      SELECT s.responses->>'neverBoughtReason' reason, count(*) n
      FROM survey_response s JOIN player_features f
        ON f.player_id=s.player_id AND NOT f.is_payer
      WHERE s.responses ? 'neverBoughtReason' AND s.responses->>'neverBoughtReason' <> ''
      GROUP BY 1) x)
);
