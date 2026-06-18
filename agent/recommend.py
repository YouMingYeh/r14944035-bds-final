"""recommend.py — agentic analyst layer (SERVING / decision stage).

Turns the pipeline's numeric `insights.json` into the studio's monetization action
plan: which lever to pull (from the diagnostic), why (the wagering-loop driver),
who to target, and a 2-week A/B plan. This is the course's AI-agent theme applied
where it earns its keep — judgment over results, not parsing data (the SQL pipeline
does that). Calls Claude via the official Anthropic SDK; falls back to a deterministic
brief when ANTHROPIC_API_KEY is absent, so the repo reproduces offline for grading.

Run:  python3 agent/recommend.py   (after src/run_pipeline.py)
"""
from __future__ import annotations
import json
import os
import textwrap

HERE = os.path.dirname(__file__)
INSIGHTS = os.path.join(HERE, "..", "outputs", "insights.json")
OUT_MD = os.path.join(HERE, "..", "outputs", "recommendation.md")
MODEL = "claude-opus-4-8"

SYSTEM = textwrap.dedent("""\
    You are a monetization analyst embedded with a small indie social-game studio that
    has no data team. You are handed the JSON output of a first-party monetization-
    intelligence pipeline (behavioral DB joined to RevenueCat revenue). Convert it into
    a decision the founder can act on this week.

    Rules:
    - Lead with the DIAGNOSTIC: which lever has the most $ upside, and why.
    - Ground every claim in the revealed numbers; never quote stated intent without its
      revealed counterweight.
    - Surface the causal driver (what behaviour precedes paying), not just correlations.
    - Be explicit that propensity is an interpretable score validated on a holdout, and
      that $ figures are directional upside to be confirmed by live A/B.
    - Output Markdown with exactly these sections:
      ## The call  ## Why (evidence)  ## Who to target  ## Risks  ## 2-week experiment plan
    - Concrete and brief. The reader is a busy founder.
    """)


def build_prompt(insights: dict) -> str:
    return ("Here is this week's monetization-intelligence output. Write the brief.\n\n"
            "```json\n" + json.dumps(insights, indent=2, ensure_ascii=False) + "\n```")


def call_claude(insights: dict) -> str | None:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return None
    try:
        import anthropic
    except ImportError:
        return None
    client = anthropic.Anthropic()
    msg = client.messages.create(
        model=MODEL, max_tokens=2000, thinking={"type": "adaptive"},
        system=SYSTEM, messages=[{"role": "user", "content": build_prompt(insights)}],
    )
    return "".join(b.text for b in msg.content if b.type == "text").strip()


_TEMPLATE = """\
# Peeps — Weekly Monetization Brief  *(deterministic fallback; set ANTHROPIC_API_KEY for the Claude-generated version)*

## The call
Pull **{top_lever}** first — est. **${top_usd:,}** upside (pool {top_pool:,} players), ahead of
the other levers below. It is the highest-ROI move and barely touched today.

| Lever | Pool | Est. upside | Assumption |
|---|---|---|---|
{lever_rows}

## Why (evidence)
- **Paying is fueled by the wagering loop:** {wagered_before}% of payers had wagered pcoins
  *before* their first purchase, and {same_day}% buy day-0. Players buy pcoins to keep betting
  in minigames — cosmetics are effectively dead ({cosmetics}% of players own any).
- **Behaviour predicts paying better than words:** wagering lifts payer rate {wager_lift}x,
  vs stated intent {intent_lift}x. The propensity score (interpretable, holdout-validated)
  separates payers cleanly — top decile {top_decile}% vs {base_decile}% base ({decile_lift}x).
- **Revealed truth:** {payers:,} of {players:,} players pay ({payer_pct}%), ${total_usd:,} lifetime
  (reconciles with RevenueCat). ARPPU ${arppu}.

## Who to target
- **Convert:** {hp_nonpayers:,} high-propensity non-payers (mostly TW/HK) — they already wager but
  haven't bought. Trigger an offer the moment their pcoin balance runs low mid-game.
- **Expand:** {one_timers:,} one-time buyers (55% of payers) — nudge a 2nd purchase.
- **Cross-sell:** {prime_pool:,} pcoin buyers are not PRIME subscribers — the single biggest gap.

## Risks
- $ figures are directional upside, not booked revenue — confirm with live A/B.
- Wagering-led monetization invites responsible-design / regulatory scrutiny (minors, odds disclosure).
- Propensity is a transparent heuristic, not a trained model — re-fit if behaviour shifts.

## 2-week experiment plan
1. **Low-balance offer:** when a high-propensity non-payer's pcoins run low mid-minigame, show a
   one-tap pcoin_1/pcoin_5 offer (the proven gateway packs). Measure day-0 conversion.
2. **PRIME cross-sell:** prompt the {prime_pool:,} pcoin buyers with a "bet more for less" PRIME
   trial. Measure take rate vs the 5% assumption.
3. **Repeat nudge:** to one-time buyers, a 2nd-purchase bonus. Measure repeat rate.
4. Read revealed conversion + ARPPU after 14 days; promote winners.
"""


def fallback_brief(insights: dict) -> str:
    h = insights["headline"]
    diag = insights["diagnostic"]["levers"]
    top = diag[0]
    cm = insights["convert_more"]
    prop = insights["propensity"]
    bd = {x["feature"]: x["lift"] for x in insights["behavior_diff"]["predictor_lift"]}
    rows = "\n".join(
        f"| {l['lever']} | {l['pool']:,} | ${l['est_upside_usd']:,} | {l['assumption']} |"
        for l in diag)
    return _TEMPLATE.format(
        top_lever=top["lever"], top_usd=top["est_upside_usd"], top_pool=top["pool"],
        lever_rows=rows,
        wagered_before=cm["wagered_before_paying_pct"], same_day=cm["conversion_moment"]["same_day_pct"],
        cosmetics=insights["why_pay"]["cosmetics_gap"]["pct"],
        wager_lift=bd.get("wagered pcoins (>0)", "?"),
        intent_lift=bd.get("stated intent to pay (survey)", "?"),
        top_decile=prop["top_decile_payer_pct"], base_decile=prop["holdout_base_payer_pct"],
        decile_lift=prop["top_decile_lift"],
        payers=h["payers"], players=h["players"], payer_pct=h["payer_pct"],
        total_usd=h["total_usd"], arppu=h["arppu_usd"],
        hp_nonpayers=cm["target_pool"]["high_propensity_nonpayers"],
        one_timers=insights["expand_more"]["purchase_freq"][0]["payers"],
        prime_pool=insights["expand_more"]["prime_cross_sell"]["pcoin_buyers_not_prime"])


def run():
    insights = json.load(open(INSIGHTS, encoding="utf-8"))
    brief = call_claude(insights)
    source = MODEL
    if brief is None:
        brief, source = fallback_brief(insights), "deterministic-fallback"
    with open(OUT_MD, "w", encoding="utf-8") as f:
        f.write(brief + f"\n\n<!-- generated by: {source} -->\n")
    print(f"-> wrote {os.path.relpath(OUT_MD)}  (source: {source})")


if __name__ == "__main__":
    run()
