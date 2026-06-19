# Peeps Monetization Intelligence

**BDS Final Project — Designing a System That Monetizes Data**
R14944035 葉又銘 · Big Data Systems, Spring 2026 · NTU

> A SQL-first system that turns a #1 social game's **first-party production data** (173k players)
> into a **monetization diagnostic**: why players pay, who will pay next, and **which lever has the
> most $ upside** — with named, actionable (anonymized) target pools. Sold to small indie game
> studios with the same data but no data team. **Peeps is the design partner and first case study.**

---

## Headline result (real, reproducible)

- **173,336** players · **1.92%** paid conversion · **$31,861** lifetime revenue (reconciles with RevenueCat's independent **$30,664**).
- **Why they pay:** a wagering loop — **86.3%** of payers wagered pcoins *before* their first purchase; cosmetics are dead (0.3%).
- **Behaviour beats words:** wagering lifts payer rate **4.7×** vs stated intent 3.9×.
- **Propensity model** (transparent, holdout-validated): top decile **6.17%** vs **1.99%** base = **3.1× lift**.
- **Diagnostic levers:** PRIME cross-sell **$7.7k** (3,211 buyers not subscribed) > convert non-payers **$7.1k** (24,669) > one-time→repeat **$2.5k**.

## Architecture

```
INGEST                          PROCESS (SQL, in Postgres)                 SERVE
──────                          ──────────────────────────                 ─────
Production Postgres  ┐          00 feature_store  (1 row / player)         outputs/insights.json
 (player, surveys,   ├─────►    10–60 analysis suite                  ─►   dashboard/index.html (read-only)
  pcoin_transaction, │            why-pay · behaviour lift · propensity     agent/recommend.py → action plan
  prime, sessions…)  │            (holdout) · convert · expand · social     (claude-opus-4-8 + offline fallback)
RevenueCat (revenue) ┘          70 diagnostic  (size & rank levers in $)    [PII gate: aggregates only]
```

Heavy joins (1.0M sessions, 5.8M feedings) run set-based in Postgres; Python only orchestrates and
serializes. The two sources join at `player.id` (= RevenueCat app_user_id).

## Run it

```bash
# 0. one-time: restore the production dump into local Postgres (see below)
python3 src/run_pipeline.py     # build feature store + run all SQL -> outputs/insights.json + dashboard/data.js
python3 agent/recommend.py      # agentic analyst -> outputs/recommendation.md
open dashboard/index.html       # read-only dashboard (renders from data.js)
```

`run_pipeline.py` is stdlib-only (shells out to `psql`); no pandas/sklearn needed. The agent uses the
official `anthropic` SDK when `ANTHROPIC_API_KEY` is set, else a deterministic fallback — so every
artifact reproduces without credentials.

### Restoring the production data (one-time)

The raw 47.5 GB dump is **not** in this repo (PII). With it in `data/_private/db_20260618.dump`:

```bash
createdb -p 5444 peeps
pg_restore -s -d "postgresql://postgres@/peeps?host=/tmp&port=5444" data/_private/db_20260618.dump
pg_restore --data-only --disable-triggers -j4 \
  -t player -t survey_response -t pcoin_transaction -t prime_subscription_event \
  -t prime_credit_ledger -t pcoin_admin_ledger -t game_session -t player_room \
  -t pet -t pet_feeding -t arcade_score \
  -d "postgresql://postgres@/peeps?host=/tmp&port=5444" data/_private/db_20260618.dump
```

Connection is configurable via `PEEPS_PGHOST/PGPORT/PGDB/PGUSER` env vars (defaults: `/tmp`, `5444`, `peeps`, `postgres`).

## Layout

| Path | Role |
|------|------|
| `sql/00_feature_store.sql` | per-player feature store (the core data asset) + `is_payer` label |
| `sql/10–60_*.sql` | analysis suite (why-pay, **payer-DNA / loss-chasing**, behaviour lift, propensity, convert, expand, social/retention/geo) |
| `sql/70_diagnostic.sql` | sizes & ranks the monetization levers in $ |
| `src/run_pipeline.py` | orchestrator → `outputs/insights.json` + `dashboard/data.js` |
| `src/anonymize.py` | PII gate (fails if any uuid/email reaches an output) |
| `agent/recommend.py` | LLM analyst → weekly action plan |
| `dashboard/index.html` | self-contained read-only delivery surface |
| `report/r14944035.pdf` | the report (also `report.html` source) |
| `data/revenue_real.json` | RevenueCat aggregates (cross-validation) |
| `data/_private/` | **gitignored** — raw production dump + restored DB (never committed) |

## Data provenance & ethics

- All data is **first-party** (the author's own product). The raw production dump and restored DB stay
  in gitignored `data/_private/`; **only anonymized aggregates** reach `outputs/`, the dashboard, and the
  report. `src/anonymize.py` enforces this — the pipeline aborts if a `player_id`/email appears in output.
- No third-party scraping or external personal data. The studio remains the data controller.

## Verifiability (the raw data is proprietary by necessity)

The system's whole premise is a **proprietary first-party dataset** — the live production DB, which contains
player PII and cannot be published. A grader therefore cannot re-run the pipeline against the raw data. What
**is** committed and verifiable: every `sql/*.sql` query (the exact analysis logic), the **aggregated results**
in `outputs/insights.json`, the agent brief, and the rendered dashboard. These let a reader inspect precisely how
each number was produced and confirm the analysis end-to-end without ever touching PII. The pipeline reproduces
fully for anyone with access to the source DB (e.g. the author / the studio), per the restore steps above.

## Known limitations (honest)

- Propensity is a **transparent additive score**, not a trained model — chosen so a non-technical studio
  can audit it; validated on a 20% holdout (3.1× lift) but should be re-fit if behaviour shifts.
- Diagnostic $ figures are **directional upside** on real pools, to be confirmed by live A/B.
- `birthday` is only 6% populated, so age uses the survey's `ageRange`; revealed revenue is the reliable signal.
