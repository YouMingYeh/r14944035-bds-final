"""train_model.py — a logistic-regression propensity model, trained from scratch.

No ML libraries. We pull the feature store from Postgres, standardize, train logistic
regression by full-batch gradient descent on a class-balanced sample, and evaluate on a
held-out 20% drawn from the natural (imbalanced) distribution. The point isn't a fancy
model — it's that the LEARNED coefficients are themselves the "who pays" insight
(quantified feature importance), and the model is interpretable enough for a studio to
trust. Writes outputs/model_report.json.

Run:  python3 src/train_model.py   (after the DB is restored)
"""
from __future__ import annotations
import json, math, os, subprocess

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, "..", "outputs")
PSQL = os.environ.get("PSQL_BIN", "/opt/homebrew/opt/postgresql@17/bin/psql")
CONN = ["-h", os.environ.get("PEEPS_PGHOST", "/tmp"), "-p", os.environ.get("PEEPS_PGPORT", "5444"),
        "-U", os.environ.get("PEEPS_PGUSER", "postgres"), "-d", os.environ.get("PEEPS_PGDB", "peeps")]

FEATURES = ["pcoins_wagered", "max_streak", "n_games_hosted", "active_days", "login_days",
            "n_invited", "n_rooms", "furniture_cnt", "n_feedings", "n_arcade",
            "stated_intent", "was_invited", "surveyed"]

EXPORT = f"""COPY (SELECT (abs(hashtext(player_id::text))%5=0)::int is_test, is_payer::int y,
  {', '.join(f'{c}::float' if c not in ('stated_intent','was_invited','surveyed') else f'{c}::int::float' for c in FEATURES)}
  FROM player_features) TO STDOUT WITH CSV HEADER"""


def load():
    out = subprocess.run([PSQL, *CONN, "-tA", "-c", EXPORT], capture_output=True, text=True, check=True).stdout
    rows = [r.split(",") for r in out.splitlines() if r]
    header = rows[0]
    data = [[float(v) for v in r] for r in rows[1:]]
    return header, data


def standardize(rows, idx):
    """z-score each feature column (over the training rows); return (means, stds)."""
    n = len(rows)
    means, stds = [], []
    for j in idx:
        col = [r[j] for r in rows]
        m = sum(col) / n
        sd = (sum((x - m) ** 2 for x in col) / n) ** 0.5 or 1.0
        means.append(m); stds.append(sd)
    return means, stds


def sigmoid(z):
    if z < -30: return 1e-13
    if z > 30: return 1.0
    return 1.0 / (1.0 + math.exp(-z))


def auc(scores, labels):
    """Mann-Whitney AUC: P(score(payer) > score(non-payer))."""
    pos = [s for s, y in zip(scores, labels) if y == 1]
    neg = [s for s, y in zip(scores, labels) if y == 0]
    if not pos or not neg:
        return None
    order = sorted(range(len(scores)), key=lambda i: scores[i])
    ranks = [0.0] * len(scores)
    i = 0
    while i < len(order):
        j = i
        while j < len(order) and scores[order[j]] == scores[order[i]]:
            j += 1
        avg = (i + j - 1) / 2.0 + 1
        for k in range(i, j):
            ranks[order[k]] = avg
        i = j
    rank_pos = sum(ranks[i] for i in range(len(scores)) if labels[i] == 1)
    return (rank_pos - len(pos) * (len(pos) + 1) / 2.0) / (len(pos) * len(neg))


def train():
    header, data = load()
    fidx = [header.index(c) for c in FEATURES]
    yi, ti = header.index("y"), header.index("is_test")

    train_all = [r for r in data if r[ti] == 0]
    test = [r for r in data if r[ti] == 1]
    means, stds = standardize(train_all, fidx)

    def vec(r):
        return [(r[fidx[k]] - means[k]) / stds[k] for k in range(len(FEATURES))]

    # class-balance the TRAIN set: all payers + ~4x non-payers (deterministic stride sample)
    pos = [r for r in train_all if r[yi] == 1]
    neg = [r for r in train_all if r[yi] == 0]
    stride = max(1, len(neg) // (len(pos) * 4))
    neg_s = neg[::stride]
    train = [(vec(r), 1) for r in pos] + [(vec(r), 0) for r in neg_s]

    # full-batch gradient descent with L2
    w = [0.0] * len(FEATURES); b = 0.0
    lr, lam, epochs = 0.3, 1e-3, 400
    n = len(train)
    for _ in range(epochs):
        gw = [0.0] * len(FEATURES); gb = 0.0
        for x, y in train:
            p = sigmoid(sum(wi * xi for wi, xi in zip(w, x)) + b)
            err = p - y
            for k in range(len(w)):
                gw[k] += err * x[k]
            gb += err
        w = [wi - lr * (gw[k] / n + lam * wi) for k, wi in enumerate(w)]
        b -= lr * gb / n

    # evaluate on the held-out natural distribution
    tx = [vec(r) for r in test]; ty = [int(r[yi]) for r in test]
    scores = [sigmoid(sum(wi * xi for wi, xi in zip(w, x)) + b) for x in tx]
    model_auc = auc(scores, ty)
    # top-decile lift
    order = sorted(range(len(scores)), key=lambda i: -scores[i])
    k = len(order) // 10
    base = sum(ty) / len(ty)
    top_rate = sum(ty[i] for i in order[:k]) / k
    coeffs = sorted(({"feature": FEATURES[j], "coef": round(w[j], 3),
                      "odds_per_sd": round(math.exp(w[j]), 2)} for j in range(len(FEATURES))),
                    key=lambda d: -abs(d["coef"]))

    report = {
        "model": "logistic regression (from scratch, no ML libraries)",
        "train_rows": len(train), "test_rows": len(test),
        "class_balance": f"trained on {len(pos)} payers + {len(neg_s)} sampled non-payers",
        "test_auc": round(model_auc, 3),
        "test_base_rate_pct": round(100 * base, 2),
        "top_decile_rate_pct": round(100 * top_rate, 2),
        "top_decile_lift": round(top_rate / base, 1),
        "coefficients_by_importance": coeffs,
        "note": "Coefficients are standardized (per +1 SD); odds_per_sd>1 means the feature raises pay odds.",
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "model_report.json"), "w") as f:
        json.dump(report, f, indent=2)
    print(f"AUC={report['test_auc']}  top-decile lift={report['top_decile_lift']}x")
    print("Top predictors:", ", ".join(f"{c['feature']}({c['odds_per_sd']}x)" for c in coeffs[:5]))
    print(f"-> wrote outputs/model_report.json")
    return report


if __name__ == "__main__":
    train()
