"""担当F: 評価の集計・閾値決定・持ち帰りガード (E6)。標準ライブラリのみ。全データは合成。

使い方:
  python -I f_eval.py --selftest                       # 合成データでの自己検証 (リポジトリ内で実行)
  python -I f_eval.py --cases C.jsonl --results R.jsonl --classes K.json --out aggregate.json
      -> プライベート環境で実データに対し同じスクリプトを実行。持ち帰るのは aggregate.json だけ。

入出力契約 (プライベート環境側):
  cases.jsonl  : {"case_id":int,"class_code":str,"split":"memory|calibration|test","decided_at":str,"human_choice":str,"retest_choice":str|null}
  results.jsonl: {"case_id":int,"arm":"no_memory|rule_default|shuffled_memory|full_memory","ai_choice":str,"confidence":float|null}
  classes.json : {"<class_code>": {"max_wrong_rate": 0.10}, ...}
  aggregate.json (出力): クラス×腕ごとの数値のみ。文字列は列挙値(腕名・クラスコード)だけ。n<MIN_CELL のセルは値を伏せる。
"""
import argparse, json, math, random, sys

ARMS = ("no_memory", "rule_default", "shuffled_memory", "full_memory")
MIN_CELL = 5
GRID = [round(0.50 + 0.05 * i, 2) for i in range(11)]        # 0.50..1.00
DELTA = 0.05


# ---------- 二項の片側上側限界 (Clopper-Pearson) ----------
def _binom_cdf(k, n, p):
    if p <= 0:
        return 1.0
    if p >= 1:
        return 1.0 if k >= n else 0.0
    s = 0.0
    for i in range(0, k + 1):
        s += math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * math.log(p) + (n - i) * math.log(1 - p))
    return min(1.0, s)


def cp_upper(k, n, delta=DELTA):
    """P(X<=k | p) = delta となる p (誤り率の片側 1-delta 上側限界)"""
    if n == 0:
        return 1.0
    if k >= n:
        return 1.0
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if _binom_cdf(k, n, mid) > delta:
            lo = mid
        else:
            hi = mid
    return hi


def zero_error_n(alpha, delta=DELTA):
    n = 1
    while cp_upper(0, n, delta) > alpha:
        n += 1
    return n


def select_threshold(pairs, alpha, grid=GRID, delta=DELTA):
    """pairs=[(confidence, correct_bool)]。格子上の各 t について「conf>=t のうち誤り」の上側限界が alpha 以下となる
    最小の t を返す。格子点数 m で Bonferroni (delta/m)。取れなければ None (= 自律化しない = min_confidence=1.0)。"""
    m = len(grid)
    for t in sorted(grid):
        sel = [c for conf, c in pairs if conf is not None and conf >= t]
        n, k = len(sel), sum(1 for c in sel if not c)
        if n > 0 and cp_upper(k, n, delta / m) <= alpha:
            return t, n, k
    return None, 0, 0


# ---------- 集計 ----------
def bootstrap_ci(vals, B=2000, seed=7):
    rnd = random.Random(seed)
    n = len(vals)
    ms = sorted(sum(vals[rnd.randrange(n)] for _ in range(n)) / n for _ in range(B))
    return ms[int(0.025 * B)], ms[int(0.975 * B) - 1]


def aggregate(cases, results, classes):
    by_case = {c["case_id"]: c for c in cases if c["split"] == "test"}
    out = {"min_cell": MIN_CELL, "classes": {}}
    for cls in sorted({c["class_code"] for c in by_case.values()}):
        cc = {cid: c for cid, c in by_case.items() if c["class_code"] == cls}
        entry = {"n_test_cases": len(cc), "arms": {}}
        per_arm = {}
        for arm in ARMS:
            rs = [r for r in results if r["arm"] == arm and r["case_id"] in cc]
            vals = [1.0 if r["ai_choice"] == cc[r["case_id"]]["human_choice"] else 0.0 for r in rs]
            per_arm[arm] = (rs, vals)
            if len(vals) < MIN_CELL:
                entry["arms"][arm] = {"n": len(vals), "suppressed": True}
                continue
            lo, hi = bootstrap_ci(vals)
            entry["arms"][arm] = {"n": len(vals), "agree": sum(vals) / len(vals), "ci95": [lo, hi], "suppressed": False}
        rt = [1.0 if c.get("retest_choice") == c["human_choice"] else 0.0 for c in cc.values() if c.get("retest_choice") is not None]
        entry["retest_ceiling"] = (sum(rt) / len(rt)) if len(rt) >= MIN_CELL else None          # 取れなければ null (= 天井不明、正規化しない)
        fm, nm, rd = (entry["arms"].get(a, {}) for a in ("full_memory", "no_memory", "rule_default"))
        if all(not x.get("suppressed", True) for x in (fm, nm, rd)):
            entry["net_gain_vs_best_baseline"] = fm["agree"] - max(nm["agree"], rd["agree"])
            sh = entry["arms"]["shuffled_memory"]
            entry["shuffled_below_full"] = (None if sh.get("suppressed") else fm["agree"] - sh["agree"])
        # 閾値: 較正セット (calibration) の full_memory の (確信度, 正誤)
        cal = {c["case_id"]: c for c in cases if c["split"] == "calibration" and c["class_code"] == cls}
        pairs = [(r["confidence"], r["ai_choice"] == cal[r["case_id"]]["human_choice"]) for r in results
                 if r["arm"] == "full_memory" and r["case_id"] in cal]
        alpha = classes.get(cls, {}).get("max_wrong_rate", 0.0)
        t, n, k = select_threshold(pairs, alpha)
        entry["calibration"] = {"n": len(pairs), "alpha": alpha, "threshold": t if t is not None else 1.0,
                                "autonomy_enabled": t is not None, "n_above": n, "errors_above": k,
                                "zero_error_n_needed": zero_error_n(alpha, DELTA / len(GRID)) if alpha > 0 else None}
        out["classes"][cls] = entry
    return out


# ---------- 持ち帰りガード ----------
ALLOWED_KEYS = {"min_cell", "classes", "n_test_cases", "arms", "n", "agree", "ci95", "suppressed", "retest_ceiling",
                "net_gain_vs_best_baseline", "shuffled_below_full", "calibration", "alpha", "threshold", "autonomy_enabled",
                "n_above", "errors_above", "zero_error_n_needed", "n"} | set(ARMS)


def export_guard(obj, class_codes, path="$"):
    """数値・真偽・null・列挙値(クラスコード)だけを許す。自由文字列や未知のキーがあれば例外。"""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k not in ALLOWED_KEYS and k not in class_codes:
                raise ValueError(f"export_guard: unknown key {path}.{k}")
            export_guard(v, class_codes, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            export_guard(v, class_codes, f"{path}[{i}]")
    elif isinstance(obj, (int, float, bool)) or obj is None:
        return
    else:
        raise ValueError(f"export_guard: non-numeric value at {path}: {type(obj).__name__}")


def read_jsonl(p):
    return [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]


# ---------- 自己検証 (合成) ----------
def selftest():
    ok = True

    def chk(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"[{'PASS' if cond else 'FAIL'}] {name}  {detail}")

    chk("zero-error n (alpha=0.10, 単一検定) = 29", zero_error_n(0.10) == 29, f"got {zero_error_n(0.10)}")
    chk("zero-error n (alpha=0.05, 単一検定) = 59", zero_error_n(0.05) == 59, f"got {zero_error_n(0.05)}")
    print(f"  格子 {len(GRID)} 点の Bonferroni 補正後(delta/m): 誤り0件で alpha=0.10 に必要な n = {zero_error_n(0.10, DELTA / len(GRID))}, alpha=0.05 -> {zero_error_n(0.05, DELTA / len(GRID))}")
    # 既知の値: k=1,n=20 の 95% 片側上限 ~ 0.2161
    chk("cp_upper(1,20) ~= 0.2161 (既知値)", abs(cp_upper(1, 20) - 0.2161) < 0.002, f"got {cp_upper(1,20):.4f}")
    try:
        import scipy.stats as st
        v = st.beta.ppf(1 - 0.05, 1 + 1, 20 - 1)
        chk("scipy の beta 分位点と一致 (k=1,n=20)", abs(cp_upper(1, 20) - v) < 1e-6, f"scipy {v:.6f}")
    except Exception as e:
        print("  (scipy 不在のため照合省略)", type(e).__name__)

    rnd = random.Random(11)

    def synth(n):  # 較正された合成データ: P(correct|conf)=conf
        out = []
        for _ in range(n):
            conf = min(1.0, max(0.5, 0.5 + 0.5 * rnd.random() ** 0.5))
            out.append((conf, rnd.random() < conf))
        return out

    small = select_threshold(synth(20), 0.10)
    chk("n=20 では自律化しない (threshold=None)", small[0] is None, str(small))
    big = select_threshold(synth(600), 0.10)
    print(f"  n=600 (alpha=0.10): threshold={big[0]} n_above={big[1]} errors={big[2]}")
    # 反復: 選ばれた領域の「真の誤り率」が alpha を超える割合 (<= delta 程度であるべき)
    reps, viol, picked = 300, 0, 0
    for _ in range(reps):
        t, n, k = select_threshold(synth(600), 0.10)
        if t is None:
            continue
        picked += 1
        # 真の誤り率: conf>=t の領域での E[1-conf]  (conf = 0.5+0.5*sqrt(U), 数値積分)
        xs = [0.5 + 0.5 * math.sqrt((i + 0.5) / 4000) for i in range(4000)]
        sel = [1 - x for x in xs if x >= t]
        true_err = sum(sel) / len(sel)
        viol += true_err > 0.10
    chk("選ばれた閾値の領域で真の誤り率 > alpha となる割合が 5% 以下 (合成・300反復)", viol / max(picked, 1) <= 0.05,
        f"selected {picked}/{reps}, violations {viol}")

    # 集計 + ガード
    cases, results = [], []
    cid = 0
    for cls in ("c_syn",):
        for split, n in (("test", 40), ("calibration", 200)):
            for i in range(n):
                cid += 1
                cases.append({"case_id": cid, "class_code": cls, "split": split, "decided_at": "2026-01-01", "human_choice": "A", "retest_choice": "A" if i % 10 else "B"})
                for arm, p in (("no_memory", 0.5), ("rule_default", 0.55), ("shuffled_memory", 0.3), ("full_memory", 0.85)):
                    conf = min(1.0, max(0.5, 0.5 + 0.5 * rnd.random() ** 0.5))
                    good = rnd.random() < (conf if arm == "full_memory" else p)
                    results.append({"case_id": cid, "arm": arm, "ai_choice": "A" if good else "B", "confidence": conf})
    agg = aggregate(cases, results, {"c_syn": {"max_wrong_rate": 0.10}})
    export_guard(agg, {"c_syn"})
    chk("集計出力が export_guard を通る (数値のみ)", True)
    a = agg["classes"]["c_syn"]
    print("  agreement:", {k: round(v.get("agree", float('nan')), 3) for k, v in a["arms"].items()},
          "ceiling:", a["retest_ceiling"], "net_gain:", round(a["net_gain_vs_best_baseline"], 3), "cal:", a["calibration"])
    chk("shuffled_memory は full_memory より低い (合成で腕が機能)", a["shuffled_below_full"] > 0.2)
    leak = json.loads(json.dumps(agg))
    leak["classes"]["c_syn"]["note"] = "decider-001 chose structlog because ..."
    try:
        export_guard(leak, {"c_syn"})
        chk("自由文字列(判断本文の漏洩)は export_guard が拒否", False)
    except ValueError as e:
        chk("自由文字列(判断本文の漏洩)は export_guard が拒否", True, str(e))
    leak2 = json.loads(json.dumps(agg))
    leak2["classes"]["c_syn"]["arms"]["full_memory"]["example"] = 3
    try:
        export_guard(leak2, {"c_syn"})
        chk("未知キーは export_guard が拒否", False)
    except ValueError as e:
        chk("未知キーは export_guard が拒否", True, str(e))
    # n<MIN_CELL の伏せ
    agg_small = aggregate([c for c in cases if c["split"] != "test" or c["case_id"] <= 3], [r for r in results if r["case_id"] <= 3 or True], {"c_syn": {"max_wrong_rate": 0.10}})
    chk("n<5 のセルは suppressed", agg_small["classes"]["c_syn"]["arms"]["full_memory"].get("suppressed") is True)
    print("SELFTEST", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--cases"); ap.add_argument("--results"); ap.add_argument("--classes"); ap.add_argument("--out")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())
    classes = json.load(open(a.classes, encoding="utf-8"))
    agg = aggregate(read_jsonl(a.cases), read_jsonl(a.results), classes)
    export_guard(agg, set(classes))
    json.dump(agg, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("wrote", a.out)
