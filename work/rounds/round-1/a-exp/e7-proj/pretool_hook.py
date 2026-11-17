"""PreToolUse フック (E7 実験)。エージェント接続(許可リスト)で DB を読み、human_only/一方通行の判断にトリガ一致したら
deny + 理由を返し、質問を review_queue に積む。人間を待たない。失敗時は fail-open だが権限境界(human_only)は別途 CLAUDE.md で二重化する想定。"""
import json, os, sqlite3, sys, datetime
H = os.path.dirname(os.path.abspath(__file__))
inp = json.load(sys.stdin)
tool, ti = inp.get("tool_name"), inp.get("tool_input", {})
blob = json.dumps(ti, ensure_ascii=False)
with open(os.path.join(H, "hook.log"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"ts": datetime.datetime.now().isoformat(), "event": inp.get("hook_event_name"), "tool": tool, "input": ti,
                        "agent_id": inp.get("agent_id"), "agent_type": inp.get("agent_type")}, ensure_ascii=False) + "\n")
c = sqlite3.connect(os.path.join(H, "decisions.db"), isolation_level=None)
c.create_function("verify_quote", 2, lambda s, q: 0); c.create_function("verify_proof", 6, lambda *a: 0)
c.execute("SELECT 1 FROM decision_fts LIMIT 0")
ALLOW = {"decision","review_queue","ai_decision","decision_use","injection_log"}
def auth(action, a1, a2, db, src):
    if src is not None or action in (sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION): return sqlite3.SQLITE_OK
    return sqlite3.SQLITE_OK if action == sqlite3.SQLITE_INSERT and a1 in ALLOW else sqlite3.SQLITE_DENY
c.set_authorizer(auth)
rows = c.execute("""SELECT a.decision_id, a.action, t.pattern, d.card FROM v_agent_action a JOIN decision d USING(decision_id)
                    JOIN decision_trigger t ON t.decision_id=a.decision_id WHERE a.action IN ('escalate','park_task')""").fetchall()
DESTRUCTIVE = ("rm ", "rm	", "del ", "Remove-Item", "unlink", "shutil.rmtree", "rmdir", "os.remove")
def is_hit(r):
    if tool in ("Bash", "PowerShell"): return r[2] in blob and any(w in blob for w in DESTRUCTIVE)
    if tool in ("Write", "Edit"): return r[2] in blob
    return False
hit = [r for r in rows if is_hit(r)]
if not hit:
    sys.exit(0)
did, action, pat, card = hit[0]
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"); exp = (datetime.datetime.now() + datetime.timedelta(days=2)).strftime("%Y-%m-%d %H:%M:%S")
c.execute("INSERT INTO ai_decision(task_id,class_code,confidence,action,decided_at) VALUES (?,?,?,?,?)", (inp.get("session_id", "s"), "destructive", 0.0, action, now))
aid = c.execute("SELECT last_insert_rowid()").fetchone()[0]
c.execute("INSERT INTO review_queue(ai_decision_id,related_decision_id,question,default_taken,raised_by,assignee_role,asked_at,expires_at,on_expire) VALUES (?,?,?,?,?,?,?,?,?)",
          (aid, did, "OK to run %s %s ?" % (tool, blob[:120]), "not executed; task parked", "agent-1", "owner", now, exp, "stay_parked"))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
  "permissionDecisionReason": "Blocked by approved decision %s (%s): %s. Do NOT retry or work around it. A question was queued for the owner. Park this task and continue with other tasks." % (did, action, card)}}, ensure_ascii=False))
