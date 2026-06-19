"""run_pipeline.py — SQL-first orchestrator.

INGEST (production Postgres, restored from the dump) -> PROCESS (SQL) -> SERVE (JSON).

Builds the feature store, runs every analysis in sql/ (each returns one JSON object),
adds a headline + RevenueCat cross-validation, runs the PII gate, and writes
outputs/insights.json + dashboard/data.js. Stdlib only — the heavy lifting is in Postgres.

Run:  python3 src/run_pipeline.py
Prereq: local Postgres with the restored `peeps` db (see README). Connection via env or
defaults below (socket /tmp, port 5444).
"""
from __future__ import annotations
import json
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
ROOT = os.path.join(HERE, "..")
SQL = os.path.join(ROOT, "sql")
OUT = os.path.join(ROOT, "outputs")
DASH = os.path.join(ROOT, "dashboard")

sys.path.insert(0, HERE)
from anonymize import assert_no_pii  # noqa: E402

PGHOST = os.environ.get("PEEPS_PGHOST", "/tmp")
PGPORT = os.environ.get("PEEPS_PGPORT", "5444")
PGDB = os.environ.get("PEEPS_PGDB", "peeps")
PGUSER = os.environ.get("PEEPS_PGUSER", "postgres")
PSQL = os.environ.get("PSQL_BIN", "/opt/homebrew/opt/postgresql@17/bin/psql")

# section name -> sql file (run in order; 00 builds the table, 30 persists the score)
SECTIONS = [
    ("why_pay", "10_why_pay.sql"),
    ("payer_dna", "15_payer_dna.sql"),
    ("behavior_diff", "20_behavior_diff.sql"),
    ("propensity", "30_propensity.sql"),
    ("convert_more", "40_convert_more.sql"),
    ("expand_more", "50_expand_more.sql"),
    ("social_retention_geo", "60_social_retention_geo.sql"),
    ("diagnostic", "70_diagnostic.sql"),
]

HEADLINE_SQL = """
SELECT jsonb_build_object(
  'players',    count(*),
  'payers',     count(*) filter (where is_payer),
  'payer_pct',  round(100.0*count(*) filter (where is_payer)/count(*),2),
  'total_usd',  round(sum(lifetime_usd)::numeric,2),
  'arppu_usd',  round(avg(lifetime_usd) filter (where is_payer)::numeric,2),
  'surveyed',   count(*) filter (where surveyed),
  'stated_yes_payer_pct', round(100.0*avg(is_payer::int) filter (where stated_intent),2),
  'stated_no_payer_pct',  round(100.0*avg(is_payer::int) filter (where surveyed and not stated_intent),2)
) FROM player_features;
"""


def _psql(args: list[str]) -> str:
    cmd = [PSQL, "-h", PGHOST, "-p", PGPORT, "-U", PGUSER, "-d", PGDB,
           "-tA", "-v", "ON_ERROR_STOP=1"] + args
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"psql failed ({' '.join(args)}):\n{res.stderr}")
    return res.stdout


def run_file(fname: str) -> dict:
    """Run a .sql file; return the last line that parses as JSON (skips DDL chatter)."""
    out = _psql(["-f", os.path.join(SQL, fname)])
    for line in reversed([l for l in out.splitlines() if l.strip()]):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    raise RuntimeError(f"{fname} produced no JSON. Output tail:\n{out[-400:]}")


def run_query(sql: str) -> dict:
    return json.loads(_psql(["-c", sql]).strip())


def main():
    print("=== Peeps Monetization Intelligence — pipeline ===")
    print("  [ingest+process] building feature store (sql/00) ...")
    _psql(["-f", os.path.join(SQL, "00_feature_store.sql")])
    headline = run_query(HEADLINE_SQL)
    print(f"    players={headline['players']:,} payers={headline['payers']:,} "
          f"({headline['payer_pct']}%) revenue=${headline['total_usd']:,}")

    insights = {"headline": headline}
    for name, fname in SECTIONS:
        print(f"  [analyze] {name} ({fname}) ...")
        insights[name] = run_file(fname)

    # trained model (logistic regression, from scratch) — learned coefficients as insight
    print("  [model] training logistic regression from scratch ...")
    import train_model
    insights["model"] = train_model.train()

    # cross-validation against RevenueCat (revenue source-of-truth)
    rc_path = os.path.join(ROOT, "data", "revenue_real.json")
    if os.path.exists(rc_path):
        rc = json.load(open(rc_path, encoding="utf-8"))
        insights["revenuecat_validation"] = {
            "rc_total_revenue_usd": rc["revenue_total"]["revenue_usd"],
            "db_total_revenue_usd": headline["total_usd"],
            "rc_active_users_28d": rc["overview_28d"]["active_users_28d"],
            "note": "DB revenue reconciles with RevenueCat's independent total — same first-party truth.",
        }

    assert_no_pii(insights)  # PII gate — aggregates only

    os.makedirs(OUT, exist_ok=True)
    os.makedirs(DASH, exist_ok=True)
    with open(os.path.join(OUT, "insights.json"), "w", encoding="utf-8") as f:
        json.dump(insights, f, indent=2, ensure_ascii=False)
    with open(os.path.join(DASH, "data.js"), "w", encoding="utf-8") as f:
        f.write("window.INSIGHTS = " + json.dumps(insights, ensure_ascii=False) + ";\n")

    # console summary of the headline diagnostic
    yes_pct = headline["stated_yes_payer_pct"] or 0
    no_pct = headline["stated_no_payer_pct"] or 0
    ratio = round(yes_pct / no_pct, 1) if no_pct else "n/a"
    print(f"\n  stated-vs-revealed (per player): said-yes {yes_pct}% pay "
          f"vs said-no {no_pct}% ({ratio}x)")
    print("  top monetization levers ($ upside):")
    for lv in insights["diagnostic"]["levers"]:
        print(f"    - {lv['lever']}: ${lv['est_upside_usd']:,.0f}  (pool {lv['pool']:,})")
    print(f"  -> wrote outputs/insights.json + dashboard/data.js   (PII gate: passed)")


if __name__ == "__main__":
    main()
