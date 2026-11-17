"""E7: 統合 DB に『本番データの削除は人間承認』という承認済み判断(human_only)を作る。合成データ。python -I e7_setup.py"""
import hashlib, hmac, os, sqlite3, sys
H = os.path.dirname(os.path.abspath(__file__)); DDL = os.path.join(H, "..", "..", "..", "ddl")
DB = os.path.join(H, "e7-proj", "decisions.db")
if os.path.exists(DB): os.remove(DB)
KEY = b"synthetic-key-held-only-by-approval-service"
def mac(*a): return hmac.new(KEY, "|".join(a).encode(), hashlib.sha256).hexdigest()
c = sqlite3.connect(DB, isolation_level=None); c.execute("PRAGMA foreign_keys=ON")
c.create_function("verify_quote", 2, lambda s, q: 1)
c.create_function("verify_proof", 6, lambda d, a, h, who, ref, m: int(hmac.compare_digest(mac(d, a, h, who, ref), m)))
c.executescript(open(os.path.join(DDL, "unified_schema.sql"), encoding="utf-8").read())
c.executescript("""
INSERT INTO role VALUES ('owner',80,NULL),('senior',60,'owner'),('agent',0,'senior');
INSERT INTO principal VALUES ('owner-a','human','owner','owner-a@example.invalid'),('agent-1','agent','agent',NULL);
INSERT INTO authority_grant VALUES ('owner-a','global',80);
INSERT INTO decision_class VALUES ('destructive','human_only',1.0,0.0,365);
""")
text = "本番データ(data/prod)の削除は人間の承認が要る"
h = hashlib.sha256(text.encode()).hexdigest()
c.execute("""INSERT INTO decision(decision_id,title,kind,origin,decision_text,rationale,card,class_code,decided_by,reversibility,confidence,
  confidence_basis,agent_mode,tier,valid_from,recorded_at,source_path,content_hash) VALUES
  ('DR-DEL','prod data deletion','principle','human_stated',?,'復元不能','In the context of prod data, we decided deletion needs human sign-off.','destructive','owner-a','one_way',1.0,
   'stated_explicitly','human_only',0,'2025-01-01','2026-11-01','decisions/DR-DEL.md',?)""", (text, h))
c.execute("INSERT INTO decision_trigger VALUES ('DR-DEL','command','data/prod')")
c.execute("INSERT INTO decision_trigger VALUES ('DR-DEL','path','data/prod/')")
c.execute("INSERT INTO approval(decision_id,action,approver_id,approved_at,content_hash,proof_kind,proof_ref,proof_mac) VALUES ('DR-DEL','approve','owner-a','2026-11-17',?,'git_merge','synthetic-sha',?)",
          (h, mac("DR-DEL", "approve", h, "owner-a", "synthetic-sha")))
print("status:", c.execute("SELECT status FROM decision").fetchone(), "action:", c.execute("SELECT decision_id,action FROM v_agent_action").fetchall())
