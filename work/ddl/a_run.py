"""A 原版 DDL (a_schema.sql) の実行と、E の指摘 (E2/E3) の再現。合成データのみ。 python -I work/ddl/a_run.py"""
import os, sqlite3, sys
sys.stdout.reconfigure(encoding="utf-8")
H = os.path.dirname(os.path.abspath(__file__)); out = []
def log(s=""): print(s); out.append(s)
def tryit(name, fn):
    try: fn(); log("accepted: " + name)
    except Exception as e: log("rejected: %s -> %s" % (name, e))
c = sqlite3.connect(":memory:", isolation_level=None)
log("sqlite " + sqlite3.sqlite_version)
c.executescript(open(os.path.join(H, "a_schema.sql"), encoding="utf-8").read()); log("DDL OK")
c.executescript("""INSERT INTO role VALUES ('owner',80,'none','x'),('senior',60,'two_way','x'),('agent',0,'none','x');""")
def dec(i, st, ep, role, vf, ap=None):
    c.execute("""INSERT INTO decision(decision_id,title,kind,status,epistemic,decision_text,rationale,card,decider_role,reversibility,
      confidence,confidence_basis,agent_mode,valid_from,recorded_at,approved_by,approved_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
      (i,'t','technical',st,ep,'d','r','c',role,'two_way',0.9,'stated_explicitly','follow',vf,'2026-11-01',ap,'2026-11-01' if ap else None))
dec("DR-0001","accepted","confirmed","owner","2025-01-01","owner-a"); log("seed OK")
log("\n--- 原版の5検証 ---")
tryit("edit accepted text", lambda: c.execute("UPDATE decision SET decision_text='x' WHERE decision_id='DR-0001'"))
tryit("accept hypothesis w/o approval", lambda: c.execute("UPDATE decision SET status='accepted' WHERE decision_id='DR-0002'") if dec("DR-0002","proposed","hypothesis","agent","2026-01-01") is None else None)
tryit("one_way with follow", lambda: c.execute("INSERT INTO decision(decision_id,title,kind,decision_text,rationale,card,decider_role,reversibility,confidence,confidence_basis,agent_mode,valid_from,recorded_at) VALUES ('X','t','technical','d','r','c','owner','one_way',0.9,'stated_explicitly','follow','2026-01-01','2026-01-01')"))
tryit("rejected option w/o reason", lambda: c.execute("INSERT INTO decision_option VALUES ('DR-0001','b',0,NULL,NULL)"))
tryit("card too long", lambda: c.execute("UPDATE decision SET card=? WHERE decision_id='DR-0002'", ("a"*301,)))
log("\n--- E2 の再現: approved_by は自由文字列 ---")
tryit("INSERT status='accepted' with forged approved_by='anyone' (agent writes it)", lambda: dec("DR-0003","accepted","confirmed","agent","2026-02-01","anyone"))
log("   DR-0003 status=%s approved_by=%s" % c.execute("SELECT status, approved_by FROM decision WHERE decision_id='DR-0003'").fetchone())
log("   v_effective に出る: %s" % [r[0] for r in c.execute("SELECT decision_id FROM v_effective ORDER BY 1")])
log("\n--- E3 の再現: proposed が accepted を失効させる ---")
c.execute("DELETE FROM decision WHERE decision_id='DR-0003'")
dec("DR-0004","proposed","hypothesis","agent","2026-06-01")
c.execute("INSERT INTO decision_link VALUES ('DR-0004','DR-0001','supersedes')")
log("   DR-0001 status=%s (DR-0004 は proposed のまま: %s)" % (c.execute("SELECT status FROM decision WHERE decision_id='DR-0001'").fetchone()[0], c.execute("SELECT status FROM decision WHERE decision_id='DR-0004'").fetchone()[0]))
log("   v_effective: %s  <- 承認済み判断が無言で消える" % [r[0] for r in c.execute("SELECT decision_id FROM v_effective")])
log("\n結論: 原版 DDL は E2/E3 の指摘どおりに破れる。修正版は unified_schema.sql / unified_run.log。")
open(os.path.join(H, "a_run.log"), "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
