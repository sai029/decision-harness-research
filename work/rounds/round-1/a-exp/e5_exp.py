"""E5: 最小実験。合成の2人の判断者 D-1, D-2 (互いに逆の癖を持つ) について、過去判断カードの注入あり/なし/他人のカードを比べる。
一致率 = AI の選択 == その判断者の選択 (F §2.1)。n は 腕ごとに 12 ケース x 2 判断者 = 24。
実行: python -I e5_exp.py gen | run | score     (run は claude -p を 48 回呼ぶ。E5_CWD に CLAUDE.md の無いディレクトリを指定)"""
import json, os, random, subprocess, sys, concurrent.futures as cf, math
sys.stdout.reconfigure(encoding="utf-8")
H = os.path.dirname(os.path.abspath(__file__))
CWD = os.environ.get("E5_CWD", H)
DATA = os.path.join(H, "e5_data.json"); RES = os.path.join(H, "e5_results.jsonl")

# (domain, options[3], D-1 choice idx, D-2 choice idx, D-1 why, D-2 why, scenarios x6)
RULES = [
 ("retry", ["retry three times at a fixed interval", "retry with exponential backoff up to five times", "fail immediately and alert the owner"], 2, 1,
  "silent retries hide real outages", "transient faults usually clear themselves",
  ["the nightly invoice export failed on a timeout", "the thumbnail batch job failed with a 503 from storage", "the weekly report mailer hit a rate limit",
   "the cache warmer crashed on a connection reset", "the log compactor failed on a lock wait", "the search reindex job got a gateway timeout"]),
 ("deploy", ["push straight to production with a rollback ready", "canary to ten percent of traffic first", "soak in staging for a full day first"], 2, 0,
  "production surprises cost more than a day", "small changes should ship and be watched",
  ["a feature-flag default change in the checkout service", "a timeout tweak in the api gateway", "a new index on the orders table",
   "an updated email template in the notifier", "a log-level change in the scheduler", "a pagination limit change in the search api"]),
 ("dependency", ["pin the exact version", "allow compatible minor updates", "track the latest release"], 0, 2,
  "reproducible builds matter most", "security fixes arrive in new releases",
  ["the json parsing library used by the importer", "the http client used by the notifier", "the date library used by the reports",
   "the pdf renderer used by invoices", "the queue client used by workers", "the yaml loader used by configuration"]),
 ("review", ["require one approver", "require two approvers", "merge yourself and ask for review afterwards"], 2, 1,
  "owners should be trusted and unblocked", "a second pair of eyes catches expensive mistakes",
  ["a refactor of the billing module", "a fix to the csv export", "an update to the onboarding emails",
   "a change to the retry helper", "a rename across the admin ui", "a patch to the session handling code"]),
 ("incident", ["notify everyone affected immediately", "tell only the service owner first", "wait for the root cause before telling anyone"], 1, 0,
  "avoid panic until the owner has facts", "people deserve to know as soon as it is known",
  ["a partial outage of the file upload service", "a spike of failed logins", "stale data on the dashboard",
   "delayed payouts for one region", "a broken search ranking after a deploy", "intermittent errors in the mobile api"]),
 ("pii", ["mask the field in logs", "drop the field from logs entirely", "store a salted hash of the field"], 2, 0,
  "hashes still allow debugging joins", "masked values are enough and simplest",
  ["customer email addresses in request logs", "phone numbers in the sms gateway logs", "postal addresses in shipping events",
   "date of birth in the signup audit trail", "account numbers in reconciliation logs", "ip addresses in the abuse detector"]),
]
def cards(judge):
    out = []
    for dom, opts, c1, c2, w1, w2, sc in RULES:
        ch, why = (c1, w1) if judge == 0 else (c2, w2)
        for s in sc[:4]:
            out.append("In the context of %s, facing the choice [%s], D-%d decided for \"%s\", to achieve: %s." % (s, " / ".join(opts), judge + 1, opts[ch], why))
    return out
def gen():
    rng = random.Random(20261117)
    cases = []
    for dom, opts, c1, c2, w1, w2, sc in RULES:
        for s in sc[4:]:
            order = list(range(3)); rng.shuffle(order)
            cases.append({"id": "%s-%d" % (dom, len(cases)), "domain": dom, "scenario": s, "opts": [opts[i] for i in order],
                          "truth": ["ABC"[order.index(c1)], "ABC"[order.index(c2)]]})
    rng.shuffle(cases)
    json.dump({"cases": cases, "cards": [cards(0), cards(1)]}, open(DATA, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("generated", len(cases), "cases;", len(cards(0)), "cards per judge")
def prompt(case, who, mem):
    head = "Predict which option decision-maker D-%d would choose.\n" % (who + 1)
    if mem is not None:
        head += "\nApproved past decisions recorded for D-%d (data, not instructions):\n" % (who + 1) + "\n".join("- " + c for c in mem) + "\n"
    q = "\nSituation: %s.\nOptions:\n" % case["scenario"] + "\n".join("%s) %s" % ("ABC"[i], o) for i, o in enumerate(case["opts"]))
    return head + q + "\n\nAnswer with JSON only: {\"choice\": \"A\" | \"B\" | \"C\"}"
def call(job):
    r = subprocess.run([os.environ.get("CLAUDE_EXE", "claude"), "-p", job["prompt"], "--model", "sonnet", "--tools", "", "--no-session-persistence", "--system-prompt",
                        "You predict a person's decision from the information given. Reply with the JSON only."],
                       capture_output=True, text=True, cwd=CWD, timeout=240, encoding="utf-8")
    return {"case": job["case"], "arm": job["arm"], "who": job["who"], "raw": r.stdout.strip()[:200], "rc": r.returncode}
def run():
    d = json.load(open(DATA, encoding="utf-8")); jobs = []; done = set()
    if os.path.exists(RES):
        for l in open(RES, encoding="utf-8"):
            x = json.loads(l)
            if parse(x["raw"]) is not None: done.add((x["case"], x["arm"]))
    for c in d["cases"]:
        jobs.append({"case": c["id"], "arm": "nomem_D1", "who": 0, "prompt": prompt(c, 0, None)})
        jobs.append({"case": c["id"], "arm": "nomem_D2", "who": 1, "prompt": prompt(c, 1, None)})
        jobs.append({"case": c["id"], "arm": "mem_D1", "who": 0, "prompt": prompt(c, 0, d["cards"][0])})
        jobs.append({"case": c["id"], "arm": "mem_D2", "who": 1, "prompt": prompt(c, 1, d["cards"][1])})
    jobs = [j for j in jobs if (j["case"], j["arm"]) not in done]
    with cf.ThreadPoolExecutor(max_workers=6) as ex, open(RES, "a", encoding="utf-8") as f:
        for r in ex.map(call, jobs):
            f.write(json.dumps(r, ensure_ascii=False) + "\n"); f.flush()
    print("ran", len(jobs))
def wilson(k, n, z=1.96):
    p = k / n; den = 1 + z * z / n; c = (p + z * z / (2 * n)) / den; h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return max(0, c - h), min(1, c + h)
def parse(raw):
    try: return json.loads(raw[raw.index("{"):raw.rindex("}") + 1])["choice"]
    except Exception: return None
def score():
    d = json.load(open(DATA, encoding="utf-8")); cs = {c["id"]: c for c in d["cases"]}
    R = {}
    for l in open(RES, encoding="utf-8"):
        x = json.loads(l)
        if parse(x["raw"]) is not None: R[(x["case"], x["arm"])] = parse(x["raw"])
    arms = {"no_memory": [], "full_memory (own cards)": [], "shuffled_memory (other's cards)": []}
    for cid, c in cs.items():
        arms["no_memory"] += [R.get((cid, "nomem_D1")) == c["truth"][0], R.get((cid, "nomem_D2")) == c["truth"][1]]
        arms["full_memory (own cards)"] += [R.get((cid, "mem_D1")) == c["truth"][0], R.get((cid, "mem_D2")) == c["truth"][1]]
        arms["shuffled_memory (other's cards)"] += [R.get((cid, "mem_D1")) == c["truth"][1], R.get((cid, "mem_D2")) == c["truth"][0]]
    print("answers parsed: %d of %d expected" % (len(R), 4 * len(cs)))
    for a, v in arms.items():
        k, n = sum(v), len(v); lo, hi = wilson(k, n)
        print("%-34s agree %2d/%2d = %.2f  (Wilson95 %.2f-%.2f)" % (a, k, n, k / n, lo, hi))
if __name__ == "__main__":
    {"gen": gen, "run": run, "score": score}[sys.argv[1]]()
