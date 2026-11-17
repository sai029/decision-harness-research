"""PreToolUse フック (E7): 不可逆/A2 操作を静的規則で検出し、ai_decision(park_task) として記録 → キュー行はトリガが作る。
deny + 理由を返して、エージェントを止めずに別タスクへ進ませる。AI の分類は使わない (静的規則だけ)。
環境変数 F_CC_DB に SQLite のパス。全て合成の検証用。"""
import json, os, re, sqlite3, sys, datetime

inp = json.load(sys.stdin)
db = os.environ["F_CC_DB"]
with open(os.path.join(os.path.dirname(db), "hook.log"), "a", encoding="utf-8") as f:
    f.write(json.dumps({k: inp.get(k) for k in ("hook_event_name", "tool_name", "tool_input", "session_id", "agent_id", "agent_type")}, ensure_ascii=False) + "\n")
cmd = (inp.get("tool_input") or {}).get("command", "") if inp.get("tool_name") == "Bash" else ""
RULES = [(r"\bgit\s+push\b", "c_deploy"), (r"\brm\s+-rf\b", "c_deploy"), (r"\bterraform\s+apply\b", "c_deploy")]
for pat, cls in RULES:
    if re.search(pat, cmd):
        conn = sqlite3.connect(db)
        conn.execute("PRAGMA foreign_keys=ON")
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        cur = conn.execute("INSERT INTO ai_decision (task_id,class_code,scope,confidence,action,decided_at,question) VALUES (?,?,?,?,?,?,?)",
                           (inp.get("session_id", "s")[:12] + ":publish", cls, "proj-x", 0.0, "park_task", now, f"Allow irreversible command: {cmd[:120]}"))
        did = cur.lastrowid
        qid = conn.execute("SELECT id FROM review_queue WHERE decision_id=?", (did,)).fetchone()[0]
        conn.commit()
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
              "permissionDecisionReason": f"Irreversible command parked (review_queue #{qid}). Do NOT retry. Record it as pending and continue with other tasks."}}))
        sys.exit(0)
sys.exit(0)
