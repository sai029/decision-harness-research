"""統合スキーマの検証 (E1/E2/E3/E9/E7)。合成データのみ。
実行: python -I work/ddl/unified_test.py   (ログは work/ddl/unified_run.log に書く)
"""
import hashlib, hmac, os, sqlite3, subprocess, sys, tempfile, datetime
sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "unified_schema.sql")
LOG = os.path.join(HERE, "unified_run.log")
MAC_KEY = b"synthetic-key-held-only-by-approval-service"   # 実運用では CI の秘密。エージェントは持たない
EMAIL_AGENT = "agent-1@example.invalid"

out = []
fails = []
def log(s=""):
    print(s); out.append(s)
def check(name, cond, detail=""):
    log(("PASS " if cond else "FAIL ") + name + (("  -> " + detail) if detail else ""))
    if not cond: fails.append(name)
def expect_error(name, fn, needle):
    try:
        fn()
    except Exception as e:                     # noqa
        msg = str(e)
        needles = needle if isinstance(needle, tuple) else (needle,)
        check(name, any(n in msg for n in needles), "rejected: " + msg)
        return
    check(name, False, "NOT rejected (statement succeeded)")

# ---------------------------------------------------------------- 接続
BODIES = {1: "synthetic chat: senior-b said we will keep the retry count at 3 for batch jobs because backoff hides outages.",
          2: "synthetic adr: boss-a wrote that customer data deletion needs a human sign-off.",
          3: "synthetic agent trace: I decided deletion is fine without sign-off.",
          4: "synthetic chat from a person who withdrew consent: use tabs."}
def verify_quote(source_id, quote):
    return int(quote in BODIES.get(source_id, ""))
def mac_for(decision_id, action, content_hash, approver_id, proof_ref, key=MAC_KEY):
    msg = "|".join([decision_id, action, content_hash, approver_id, proof_ref]).encode()
    return hmac.new(key, msg, hashlib.sha256).hexdigest()
def verify_proof(decision_id, action, content_hash, approver_id, proof_ref, proof_mac):
    return int(hmac.compare_digest(mac_for(decision_id, action, content_hash, approver_id, proof_ref), proof_mac or ""))

def full_conn(path, with_funcs=True, with_proof_key=True):
    c = sqlite3.connect(path, isolation_level=None)
    c.execute("PRAGMA foreign_keys=ON")
    if with_funcs:
        c.create_function("verify_quote", 2, verify_quote)
        if with_proof_key:
            c.create_function("verify_proof", 6, verify_proof)
        else:   # 鍵を持たない接続が自作する関数 = 常に MAC を検証できず 0
            c.create_function("verify_proof", 6, lambda *a: 0)
    return c

AGENT_INSERT = {"decision","evidence","decision_link","decision_tag","decision_trigger","decision_scope",
                "decision_option","decision_assumption","ai_decision","decision_use","review_queue",
                "conflict_ticket","injection_log","decision_fts"}
def agent_conn(path):
    """エージェントに渡す接続 (L1)。ツール境界での許可リスト。トリガ内の文は通す。"""
    c = full_conn(path, with_funcs=True, with_proof_key=False)
    c.execute("SELECT 1 FROM decision_fts LIMIT 0")   # 仮想表の接続(内部で sqlite_master を触る)を認可前に済ませる
    def auth(action, a1, a2, dbname, source):
        if os.environ.get("AUTHDBG"): print("AUTH", action, a1, a2, dbname, source)
        if source is not None:                       # トリガ/ビュー内の文
            return sqlite3.SQLITE_OK
        if action in (sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION):
            return sqlite3.SQLITE_OK
        if action == sqlite3.SQLITE_INSERT and a1 in AGENT_INSERT:
            return sqlite3.SQLITE_OK
        return sqlite3.SQLITE_DENY
    c.set_authorizer(auth)
    return c

# ---------------------------------------------------------------- Git 証明 (承認サービス)
def git(repo, *args, env=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True, env=e).stdout.strip()

KEYDIR = None; ALLOWED = None; KEYS = {}
def setup_keys(tmpdir, humans):
    """合成の ssh-ed25519 鍵。allowed_signers には human principal の鍵だけを載せる。agent の鍵は載せない。"""
    global KEYDIR, ALLOWED
    KEYDIR = os.path.join(tmpdir, "keys"); os.makedirs(KEYDIR); ALLOWED = os.path.join(KEYDIR, "allowed_signers")
    lines = []
    for email in humans + [EMAIL_AGENT]:
        k = os.path.join(KEYDIR, email.split("@")[0])
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", k, "-q"], check=True)
        KEYS[email] = k
        if email != EMAIL_AGENT:
            lines.append('%s namespaces="git" %s' % (email, " ".join(open(k + ".pub").read().split()[:2])))
    open(ALLOWED, "w").write("\n".join(lines) + "\n")

def commit_file(repo, relpath, content, claimed_email, signer_email=None, sign=True):
    """claimed_email = コミットの author/committer メール (自己申告できる)。signer_email = 署名に使う鍵の持ち主。"""
    p = os.path.join(repo, relpath); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="") as f: f.write(content)
    git(repo, "add", ".")
    env = {"GIT_AUTHOR_NAME": "x", "GIT_AUTHOR_EMAIL": claimed_email, "GIT_COMMITTER_NAME": "x", "GIT_COMMITTER_EMAIL": claimed_email}
    if sign:
        args = ["-c", "gpg.format=ssh", "-c", "user.signingkey=" + KEYS[signer_email or claimed_email], "commit", "-q", "--allow-empty", "-S"]
    else:
        args = ["commit", "-q", "--allow-empty"]
    git(repo, *args, "-m", "change " + relpath, env=env)
    return git(repo, "rev-parse", "HEAD")
def merge_commit(repo, decision_id, content, author_email, signer_email=None, sign=True):
    return commit_file(repo, "decisions/%s.md" % decision_id, content, author_email, signer_email, sign)

def approval_service(conn, repo, decision_id, action, sha):
    """承認サービス。Git コミットが (1) 許可署名者リスト(allowed_signers)の鍵で署名されている (2) その署名者が human principal
    (3) 内容ハッシュが DB と一致、を確かめた時だけ MAC を作り approval 行を挿入する。
    approver_id は DB の自由入力ではなく、署名検証で得た署名者から決まる。作成者メールの自己申告は信用しない。"""
    st, signer = git(repo, "-c", "gpg.ssh.allowedSignersFile=" + ALLOWED, "log", "-1", "--format=%G?|%GS", sha).split("|", 1)
    if st != "G":
        raise PermissionError("commit %s has no valid signature from an allowed signer (status=%s)" % (sha[:8], st))
    row = conn.execute("SELECT principal_id, kind FROM principal WHERE git_email=?", (signer,)).fetchone()
    if row is None or row[1] != "human":
        raise PermissionError("signer %s is not a registered human principal" % signer)
    if action == "approve":
        body = subprocess.run(["git", "-C", repo, "show", "%s:decisions/%s.md" % (sha, decision_id)],
                              capture_output=True, check=True).stdout
        h = hashlib.sha256(body).hexdigest()
    else:   # revoke: そのコミットに decisions/<id>.revoked があること。ハッシュは DB の現行内容に結びつく
        subprocess.run(["git", "-C", repo, "show", "%s:decisions/%s.revoked" % (sha, decision_id)], capture_output=True, check=True)
        h = conn.execute("SELECT content_hash FROM decision WHERE decision_id=?", (decision_id,)).fetchone()[0]
    approver = row[0]
    mac = mac_for(decision_id, action, h, approver, sha)
    conn.execute("INSERT INTO approval(decision_id,action,approver_id,approved_at,content_hash,proof_kind,proof_ref,proof_mac)"
                 " VALUES (?,?,?,?,?,?,?,?)", (decision_id, action, approver, "2026-11-17", h, "signed_commit", sha, mac))

# ---------------------------------------------------------------- 準備
tmp = tempfile.mkdtemp(prefix="unified_")
DB = os.path.join(tmp, "u.db")
REPO = os.path.join(tmp, "repo")
os.makedirs(REPO); git(REPO, "init", "-q")
setup_keys(tmp, ["boss-a@example.invalid", "senior-b@example.invalid", "senior-c@example.invalid", "junior-d@example.invalid"])
db = full_conn(DB)
with open(SCHEMA, encoding="utf-8") as f: db.executescript(f.read())
log("sqlite %s / python %s / date %s" % (sqlite3.sqlite_version, sys.version.split()[0], datetime.date.today()))
log("DDL OK (unified_schema.sql)")
tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'decision_fts_%' ORDER BY 1")]
log("tables: %d, triggers: %d, views: %d" % (len(tables),
    db.execute("SELECT count(*) FROM sqlite_master WHERE type='trigger'").fetchone()[0],
    db.execute("SELECT count(*) FROM sqlite_master WHERE type='view'").fetchone()[0]))

db.executescript("""
INSERT INTO role VALUES ('boss',90,NULL),('owner',80,'boss'),('senior',60,'owner'),('peer',50,'owner'),('junior',10,'senior'),('agent',0,'senior');
INSERT INTO principal VALUES
 ('boss-a','human','boss','boss-a@example.invalid'),
 ('senior-b','human','senior','senior-b@example.invalid'),
 ('senior-c','human','senior','senior-c@example.invalid'),
 ('deptY-boss','human','boss','deptY-boss@example.invalid'),
 ('junior-d','human','junior','junior-d@example.invalid'),
 ('nobody-e','human',NULL,'nobody-e@example.invalid'),
 ('agent-1','agent','agent','agent-1@example.invalid');
INSERT INTO authority_grant VALUES
 ('boss-a','global',90),('senior-b','demo',60),('senior-c','demo',60),('deptY-boss','deptY',90),('junior-d','demo',10);
INSERT INTO decision_class VALUES ('default','follow',0.7,0.10,365),('destructive','human_only',1.0,0.0,365);
INSERT INTO consent(consent_id,subject_id,purposes,scope,external_llm_allowed,granted_at,withdrawn_at) VALUES
 (1,'senior-b','decision reference','demo',0,'2026-01-01',NULL),
 (2,'senior-c','decision reference','demo',0,'2026-01-01','2026-06-01');
INSERT INTO source(source_id,ref,kind,trust_tier,author_id,body_sha256,consent_id,redaction_done,ingest_state,ingested_at) VALUES
 (1,'synthetic://chat/1','chat','human_authored_unverified','senior-b','h1',1,1,'full','2026-02-01'),
 (2,'synthetic://adr/2','adr','human_authored_verified','boss-a','h2',NULL,1,'full','2026-02-01'),
 (3,'synthetic://trace/3','agent_trace','agent_asserted','agent-1','h3',NULL,1,'anonymized_only','2026-02-01'),
 (4,'synthetic://chat/4','chat','human_authored_unverified','senior-c','h4',2,1,'full','2026-02-01');
INSERT INTO extraction_run VALUES ('run-1','synthetic-extractor','synthetic-model','p1','2026-02-01');
""")
log("seed OK")

seq = [0]
def mk(conn, did, decided_by="senior-b", scope="demo", valid_from="2025-01-01", valid_until=None, conf=0.9,
       origin="extracted", agent_mode="follow", rev="two_way", status="candidate", class_code="default",
       path=None, required_role=None, text=None, tier=2):
    text = text or ("decision text of " + did)
    h = hashlib.sha256(text.encode()).hexdigest()
    conn.execute("""INSERT INTO decision(decision_id,title,kind,status,origin,extraction_run_id,decision_text,rationale,card,
        class_code,decided_by,required_role,reversibility,confidence,confidence_basis,agent_mode,tier,scope_project,scope_path,
        valid_from,valid_until,recorded_at,source_path,content_hash)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (did, "t-" + did, "technical", status, origin, "run-1" if origin == "extracted" else None, text, "because synthetic",
         "In the context of X, we decided Y.", class_code, decided_by, required_role, rev, conf, "stated_explicitly", agent_mode, tier,
         scope, path, valid_from, valid_until, "2026-11-01", "decisions/%s.md" % did, h))
    return text
def evidence(conn, did, source_id=1, role="decision", quote="keep the retry count at 3", verified=1):
    conn.execute("INSERT INTO evidence(decision_id,source_id,role,quote,quote_verified) VALUES (?,?,?,?,?)",
                 (did, source_id, role, quote, verified))
def approve(conn, did, text, author_email):
    sha = merge_commit(REPO, did, text, author_email)
    approval_service(conn, REPO, did, "approve", sha)
def mk_approved(did, approver="senior-b@example.invalid", **kw):
    text = mk(db, did, **kw)
    if kw.get("origin", "extracted") == "extracted":
        evidence(db, did, 1, "decision"); evidence(db, did, 1, "decider", quote="senior-b said")
    approve(db, did, text, approver)
def status(did): return db.execute("SELECT status FROM decision WHERE decision_id=?", (did,)).fetchone()[0]

# ================================================================ A. 状態遷移・基本制約 (A の5件を統合版で再現)
log("\n=== 1. A の既存5検証 (統合スキーマで再現) ===")
mk_approved("DR-0001")
check("approved via Git-proof service", status("DR-0001") == "approved")
expect_error("edit approved text rejected", lambda: db.execute("UPDATE decision SET decision_text='x' WHERE decision_id='DR-0001'"), "immutable")
expect_error("one_way with follow rejected", lambda: mk(db, "DR-X1", rev="one_way", agent_mode="follow"), "CHECK constraint failed")
expect_error("rejected option w/o reason", lambda: db.execute("INSERT INTO decision_option VALUES ('DR-0001','b',0,NULL,NULL)"), "CHECK constraint failed")
def long_card():
    mk(db, "DR-X2"); db.execute("UPDATE decision SET card=? WHERE decision_id='DR-X2'", ("a" * 301,))
expect_error("card too long rejected", long_card, "CHECK constraint failed")
db.execute("DELETE FROM decision WHERE decision_id='DR-X2'")
expect_error("delete approved rejected", lambda: db.execute("DELETE FROM decision WHERE decision_id='DR-0001'"), "never deleted")
expect_error("destructive class must be human_only", lambda: mk(db, "DR-X3", class_code="destructive", agent_mode="follow"), "human_only")

# ================================================================ E2: 承認の偽造
log("\n=== 2. E2: 承認の偽造 (INSERT / UPDATE 両経路) ===")
text = mk(db, "DR-0010"); evidence(db, "DR-0010", 1, "decision"); evidence(db, "DR-0010", 1, "decider", quote="senior-b said")
h = hashlib.sha256(text.encode()).hexdigest()
ins = "INSERT INTO approval(decision_id,action,approver_id,approved_at,content_hash,proof_kind,proof_ref,proof_mac) VALUES ('DR-0010','approve',?,'2026-11-17',?,'git_merge','deadbeef',?)"
ag = agent_conn(DB)
expect_error("E2-a agent tool boundary: INSERT approval denied by authorizer", lambda: ag.execute(ins, ("senior-b", h, "x")), "not authorized")
expect_error("E2-b agent INSERT decision with status='approved' (INSERT path)", lambda: mk(ag, "DR-0011", status="approved"), "only be inserted as candidate")
expect_error("E2-c agent UPDATE status='approved' denied by authorizer", lambda: ag.execute("UPDATE decision SET status='approved' WHERE decision_id='DR-0010'"), "not authorized")
nokey = full_conn(DB, with_funcs=False)     # 関数を登録していない生の書込み接続
expect_error("E2-d raw writer without verify_proof: fails closed", lambda: nokey.execute(ins, ("senior-b", h, "x")), "no such function")
nokey.close()
fake = full_conn(DB, with_proof_key=False)  # 自作の関数(常に0)を登録した書込み接続
expect_error("E2-e writer w/o MAC key forges approved_by=boss-a: proof invalid", lambda: fake.execute(ins, ("boss-a", h, "0" * 64)), "proof invalid")
expect_error("E2-f direct UPDATE status candidate->approved (no approval row)", lambda: fake.execute("UPDATE decision SET status='approved' WHERE decision_id='DR-0010'"), "no approval row")
expect_error("E2-g agent principal as approver even with valid MAC", lambda: db.execute(ins, ("agent-1", h, mac_for("DR-0010","approve",h,"agent-1","deadbeef"))), ("human principal", "lacks authority"))
expect_error("E2-h human without authority in scope (nobody-e) with valid MAC", lambda: db.execute(ins, ("nobody-e", h, mac_for("DR-0010","approve",h,"nobody-e","deadbeef"))), "lacks authority")
expect_error("E2-i content_hash mismatch (approving other content)", lambda: db.execute(ins, ("senior-b", "f" * 64, mac_for("DR-0010","approve","f"*64,"senior-b","deadbeef"))), "does not match")
def forged(claimed, signer, sign):
    def f():
        sha = merge_commit(REPO, "DR-0010", text, claimed, signer, sign)
        approval_service(db, REPO, "DR-0010", "approve", sha)
    return f
expect_error("E2-j1 commit by agent (own key, not in allowed_signers): service refuses", forged(EMAIL_AGENT, EMAIL_AGENT, True), "no valid signature")
expect_error("E2-j2 agent claims senior-b's email but does not sign: service refuses", forged("senior-b@example.invalid", None, False), "no valid signature")
expect_error("E2-j3 agent claims senior-b's email, signs with the agent's key: service refuses", forged("senior-b@example.invalid", EMAIL_AGENT, True), "no valid signature")
expect_error("E2-k approval rows append-only (UPDATE)", lambda: db.execute("UPDATE approval SET approver_id='boss-a'"), "append-only")
expect_error("E2-l approval rows append-only (DELETE)", lambda: db.execute("DELETE FROM approval"), "append-only")
check("E2-m DR-0010 still candidate after all forgeries", status("DR-0010") == "candidate")
approve(db, "DR-0010", text, "senior-b@example.invalid")
check("E2-n legit path (signed Git commit by human, service, MAC) -> approved", status("DR-0010") == "approved")
ap = db.execute("SELECT approver_id, proof_kind, substr(proof_ref,1,8) FROM approval WHERE decision_id='DR-0010'").fetchone()
log("      approver_id derived from the verified Git signature: %s" % (ap,))

log("\n--- 2b. 証拠条件 (B quote 検証 / F consent・trust_tier) ---")
t = mk(db, "DR-0020")
expect_error("quote not in body but quote_verified=1 (agent forging flag)", lambda: evidence(db, "DR-0020", 1, "decision", quote="NOT IN BODY", verified=1), "not found in the source")
ag2 = agent_conn(DB)
expect_error("agent writer without verify_quote registered? (agent conn has it, wrong quote)", lambda: ag2.execute("INSERT INTO evidence(decision_id,source_id,role,quote,quote_verified) VALUES ('DR-0020',1,'decision','zzz',1)"), "not found in the source")
nof = full_conn(DB, with_funcs=False)
expect_error("raw writer without verify_quote: fails closed", lambda: nof.execute("INSERT INTO evidence(decision_id,source_id,role,quote,quote_verified) VALUES ('DR-0020',1,'decision','x',1)"), "no such function")
nof.close()
evidence(db, "DR-0020", 1, "decision", quote="keep the retry count at 3", verified=0)   # 未検証
expect_error("approval with only unverified evidence", lambda: approve(db, "DR-0020", t, "senior-b@example.invalid"), "verified")
# 証拠条件だけを切り出すため decided_by=NULL の候補で試す (decider 条件は発火しない)
t2 = mk(db, "DR-0021", decided_by=None); evidence(db, "DR-0021", 3, "decision", quote="deletion is fine without sign-off", verified=1)   # agent_asserted
expect_error("approval with agent-asserted evidence only", lambda: approve(db, "DR-0021", t2, "senior-b@example.invalid"), "verified, non-agent")
t3 = mk(db, "DR-0022", decided_by=None); evidence(db, "DR-0022", 4, "decision", quote="use tabs", verified=1)   # 同意撤回
expect_error("approval with consent-withdrawn evidence only", lambda: approve(db, "DR-0022", t3, "senior-b@example.invalid"), "verified, non-agent")
db.execute("DELETE FROM evidence WHERE decision_id='DR-0020'")
evidence(db, "DR-0020", 1, "decision", quote="keep the retry count at 3", verified=1)
expect_error("approval without verified decider evidence (decided_by set)", lambda: approve(db, "DR-0020", t, "senior-b@example.invalid"), "decider attribution")
evidence(db, "DR-0020", 1, "decider", quote="senior-b said", verified=1)
approve(db, "DR-0020", t, "senior-b@example.invalid")
check("approval with verified+consented+human evidence -> approved", status("DR-0020") == "approved")

log("\n--- 2c. 状態遷移 ---")
mk(db, "DR-0030")
db.execute("UPDATE decision SET status='rejected' WHERE decision_id='DR-0030'")
expect_error("rejected -> candidate illegal", lambda: db.execute("UPDATE decision SET status='candidate' WHERE decision_id='DR-0030'"), "illegal status transition")
expect_error("approved -> candidate illegal", lambda: db.execute("UPDATE decision SET status='candidate' WHERE decision_id='DR-0010'"), "illegal status transition")
expect_error("approved -> quarantined needs revoke approval", lambda: db.execute("UPDATE decision SET status='quarantined' WHERE decision_id='DR-0010'"), "no revoke approval")
expect_error("approved -> expired before valid_until", lambda: db.execute("UPDATE decision SET status='expired' WHERE decision_id='DR-0010'"), "has not passed")
db.execute("UPDATE decision SET valid_until='2030-01-01' WHERE decision_id='DR-0010'")   # 短縮(NULL->日付)は可
expect_error("valid_until extension rejected", lambda: db.execute("UPDATE decision SET valid_until='2099-01-01' WHERE decision_id='DR-0010'"), "shortened")
mk_approved("DR-0031", valid_from="2020-01-01", valid_until="2020-12-31")
db.execute("UPDATE decision SET status='expired' WHERE decision_id='DR-0031'")
check("approved -> expired after valid_until passed", status("DR-0031") == "expired")
mk_approved("DR-0032")
sha = commit_file(REPO, "decisions/DR-0032.revoked", "revoked by human\n", "senior-b@example.invalid")
approval_service(db, REPO, "DR-0032", "revoke", sha)
check("approved -> revoked via revoke approval", status("DR-0032") == "revoked")
inv = db.execute("SELECT invalidated_at IS NOT NULL FROM decision WHERE decision_id='DR-0032'").fetchone()[0]
check("bitemporal: invalidated_at set on revoke", inv == 1)

# ================================================================ E3: supersede
log("\n=== 3. E3: supersede は両方承認済み+権限条件でのみ有効 ===")
mk_approved("DR-0100", decided_by="senior-b", scope="demo", valid_from="2025-01-01")
mk(db, "DR-0101", decided_by="senior-c", scope="demo", valid_from="2026-03-01")          # candidate のまま
ag3 = agent_conn(DB)
expect_error("E3-a candidate(proposed) supersedes approved: rejected", lambda: ag3.execute("INSERT INTO decision_link VALUES ('DR-0101','DR-0100','supersedes')"), "both decisions must be approved")
check("E3-a' old decision still approved/effective", status("DR-0100") == "approved" and db.execute("SELECT count(*) FROM v_effective WHERE decision_id='DR-0100'").fetchone()[0] == 1)
ag3.execute("INSERT INTO decision_link VALUES ('DR-0101','DR-0100','proposes_supersede')")
check("E3-b proposes_supersede is accepted but has no effect", status("DR-0100") == "approved")
# 低権限の承認者 (junior-d, rank10) が承認した新判断は、senior-b(60) の判断を supersede できない
mk_approved("DR-0102", approver="junior-d@example.invalid", decided_by="junior-d", scope="demo", valid_from="2026-04-01")
expect_error("E3-c approved but lower-authority approver supersedes: rejected", lambda: db.execute("INSERT INTO decision_link VALUES ('DR-0102','DR-0100','supersedes')"), "lower authority")
# 別 scope は supersede 不可 (overrides を使う)
mk_approved("DR-0103", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", valid_from="2026-04-01", origin="human_stated")
expect_error("E3-d different scope supersedes: rejected", lambda: db.execute("INSERT INTO decision_link VALUES ('DR-0103','DR-0100','supersedes')"), "scope_project must match")
# required_role (owner=80) を持つ判断は peer 以下の承認では覆せない
mk_approved("DR-0104", approver="boss-a@example.invalid", decided_by="boss-a", scope="proj-r", valid_from="2025-01-01", origin="human_stated", required_role="owner")
mk_approved("DR-0105", approver="boss-a@example.invalid", decided_by="boss-a", scope="proj-r", valid_from="2026-05-01", origin="human_stated")
db.execute("INSERT INTO decision_link VALUES ('DR-0105','DR-0104','supersedes')")
check("E3-e same scope, equal authority, both approved: superseded", status("DR-0104") == "superseded")
vu = db.execute("SELECT valid_until FROM decision WHERE decision_id='DR-0104'").fetchone()[0]
check("E3-e' old valid_until shortened to day before new.valid_from", vu == "2026-04-30", vu)
check("E3-e'' superseded decision disappears from v_effective only after a legit supersede",
      db.execute("SELECT count(*) FROM v_effective WHERE decision_id='DR-0104'").fetchone()[0] == 0)
mk_approved("DR-0106", approver="senior-c@example.invalid", decided_by="senior-c", scope="demo", valid_from="2026-06-01")
db.execute("INSERT INTO decision_link VALUES ('DR-0106','DR-0100','supersedes')")
check("E3-f equal-rank peers in same scope: supersede accepted", status("DR-0100") == "superseded")
expect_error("E3-g direct UPDATE status='superseded' without link (agent/raw)", lambda: db.execute("UPDATE decision SET status='superseded' WHERE decision_id='DR-0106'"), "no supersedes link")

# ================================================================ E9: 優先規則
log("\n=== 4. E9: 単一の優先規則と合成シナリオ ===")
# S1 上司 vs 先輩 (同 scope demo)
mk_approved("S1-boss", approver="boss-a@example.invalid", decided_by="boss-a", scope="demo", valid_from="2026-01-01", origin="human_stated", conf=0.8)
mk_approved("S1-senior", approver="senior-b@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-09-01", origin="human_stated", conf=0.95)
# S2 global vs project (同一判断者 senior-b。grant: demo=60 のみ → global の判断は grant 外で rank0)
mk_approved("S2-global", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", valid_from="2026-01-01", origin="human_stated", conf=0.8)
mk_approved("S2-project", approver="boss-a@example.invalid", decided_by="boss-a", scope="proj-p", valid_from="2026-01-01", origin="human_stated", conf=0.8)
# S3 新旧 (同一判断者・同 scope・supersede 関係なし=別観点の矛盾)
mk_approved("S3-old", approver="senior-b@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-01-01", origin="human_stated", conf=0.9)
mk_approved("S3-new", approver="senior-b@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-08-01", origin="human_stated", conf=0.7)
# S4 別部署の上司 (deptY-boss は demo に grant なし → rank0) vs 先輩 senior-b
mk_approved("S4-deptY", approver="boss-a@example.invalid", decided_by="deptY-boss", scope="demo", valid_from="2026-10-01")
mk_approved("S4-senior", approver="senior-b@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-02-01", origin="human_stated")
# S5 完全同順位 (同権限・同 scope・同日・同確信度)
mk_approved("S5-x", approver="senior-b@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-03-03", origin="human_stated", conf=0.8, path="db/**")
mk_approved("S5-y", approver="senior-c@example.invalid", decided_by="senior-c", scope="demo", valid_from="2026-03-03", origin="human_stated", conf=0.8, path="db/**")
# S6 明示 overrides (project owner の判断を上司の global より優先したい)
mk_approved("S6-boss", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", valid_from="2026-01-01", origin="human_stated", conf=0.9)
mk_approved("S6-owner", approver="boss-a@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-01-01", conf=0.9)
for a, b in [("S1-boss","S1-senior"),("S2-global","S2-project"),("S3-old","S3-new"),("S4-deptY","S4-senior"),("S5-x","S5-y"),("S6-boss","S6-owner")]:
    db.execute("INSERT INTO decision_link VALUES (?,?,'conflicts_with')", (a, b))
def show(title):
    log(title)
    for r in db.execute("SELECT a_id,b_id,winner,rule FROM v_conflict_resolution ORDER BY a_id"): log("   %s" % (r,))
show("-- overrides 前")
exp = {("S1-boss","S1-senior"): ("S1-boss","1_authority"), ("S2-global","S2-project"): ("S2-project","2_specificity"),
       ("S3-new","S3-old"): ("S3-new","3_recency"), ("S4-deptY","S4-senior"): ("S4-senior","1_authority"),
       ("S5-x","S5-y"): (None,"5_tie_open_ticket"), ("S6-boss","S6-owner"): ("S6-boss","1_authority")}
got = {(r[0], r[1]): (r[2], r[3]) for r in db.execute("SELECT a_id,b_id,winner,rule FROM v_conflict_resolution")}
for (a, b), (w, rule) in exp.items():
    k = (a, b) if (a, b) in got else (b, a)
    check("E9 %s vs %s -> winner=%s by %s" % (a, b, w, rule), got.get(k) == (w, rule), str(got.get(k)))
log("-- S6: 承認済み overrides (S6-owner が S6-boss に優先) を、上位権限 boss-a が承認した判断として追加")
mk_approved("S6-ovr", approver="boss-a@example.invalid", decided_by="boss-a", scope="demo", valid_from="2026-11-01", origin="human_stated")
mk_approved("S6-low", approver="senior-b@example.invalid", decided_by="senior-b", scope="demo", valid_from="2026-11-01", origin="human_stated")
expect_error("overrides from lower-authority approver (senior-b 60 vs boss-a 90) rejected", lambda: db.execute("INSERT INTO decision_link VALUES ('S6-low','S6-boss','overrides')"), "lower authority")
log("   (S6-owner の承認者は boss-a で rank90。S6-boss の承認者も 90 なので overrides は許可される)")
try:
    db.execute("INSERT INTO decision_link VALUES ('S6-owner','S6-boss','overrides')"); log("   overrides inserted")
except Exception as e: log("   overrides rejected: %s" % e)
r = db.execute("SELECT winner, rule FROM v_conflict_resolution WHERE a_id IN ('S6-boss','S6-owner') AND b_id IN ('S6-boss','S6-owner')").fetchone()
check("E9 S6 explicit overrides -> S6-owner by 0_overrides", r == ("S6-owner", "0_overrides"), str(r))

log("-- 決まらない場合 (S5): 矛盾チケットを開き、動作が proceed → proceed_with_assumption に下がる")
before = dict(db.execute("SELECT decision_id, action FROM v_agent_action WHERE decision_id IN ('S5-x','S5-y')").fetchall())
ag5 = agent_conn(DB)
ag5.execute("""INSERT INTO conflict_ticket(a_id,b_id,opened_at,reason)
   SELECT a_id,b_id,datetime('now'),rule FROM v_conflict_resolution r WHERE winner IS NULL
   AND NOT EXISTS (SELECT 1 FROM conflict_ticket t WHERE t.a_id=r.a_id AND t.b_id=r.b_id AND t.state='open')""")
after = dict(db.execute("SELECT decision_id, action FROM v_agent_action WHERE decision_id IN ('S5-x','S5-y')").fetchall())
log("   before=%s  after=%s" % (before, after))
check("E9 tie: ticket opened (agent connection may open tickets)", db.execute("SELECT count(*) FROM conflict_ticket WHERE state='open'").fetchone()[0] == 1)
check("E9 tie: both parties drop to proceed_with_assumption", set(after.values()) == {"proceed_with_assumption"} and set(before.values()) == {"proceed"})
expect_error("E9 tie ticket cannot be resolved by flipping state", lambda: db.execute("UPDATE conflict_ticket SET state='resolved'"), "only be resolved")
mk_approved("S5-z", approver="boss-a@example.invalid", decided_by="boss-a", scope="demo", valid_from="2026-11-02", origin="human_stated", path="db/**")
db.execute("INSERT INTO decision_link VALUES ('S5-z','S5-x','supersedes')")
db.execute("INSERT INTO decision_link VALUES ('S5-z','S5-y','supersedes')")
check("E9 tie resolved by new approved decisions (boss supersedes both): x,y superseded", status("S5-x") == "superseded" and status("S5-y") == "superseded")

log("\n-- v_agent_action (単一の動作規則) 一覧")
for r in db.execute("SELECT decision_id, agent_mode, reversibility, confidence, min_confidence, conflict_open, action FROM v_agent_action WHERE decision_id LIKE 'S%' ORDER BY 1"):
    log("   %s" % (r,))
mk_approved("AM-onew", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", origin="human_stated", rev="one_way", agent_mode="ask_async")
mk_approved("AM-human", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", origin="human_stated", class_code="destructive", agent_mode="human_only", conf=1.0)
mk_approved("AM-low", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", origin="human_stated", conf=0.3)
act = dict(db.execute("SELECT decision_id, action FROM v_agent_action WHERE decision_id LIKE 'AM-%'").fetchall())
check("action: one_way -> park_task", act["AM-onew"] == "park_task")
check("action: human_only class -> escalate", act["AM-human"] == "escalate")
check("action: low confidence -> proceed_with_assumption", act["AM-low"] == "proceed_with_assumption")

# ================================================================ 注入対象 / bitemporal / 質問キュー / 評価
log("\n=== 5. 有効性 (v_effective) / bitemporal / 質問キュー / 評価 ===")
mk_approved("V-future", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", origin="human_stated", valid_from="2099-01-01")
mk_approved("V-expired", approver="boss-a@example.invalid", decided_by="boss-a", scope="global", origin="human_stated", valid_from="2020-01-01", valid_until="2020-06-30")
mk(db, "V-cand")
eff = {r[0] for r in db.execute("SELECT decision_id FROM v_effective")}
check("v_effective excludes candidate / future / expired(unswept) / superseded",
      not ({"V-cand","V-future","V-expired","DR-0100","S5-x"} & eff) and "DR-0106" in eff)
asof = db.execute("""SELECT decision_id FROM decision WHERE status IN ('approved','superseded','expired','revoked')
   AND valid_from <= :v AND (valid_until IS NULL OR valid_until >= :v) AND recorded_at <= :k ORDER BY 1 LIMIT 3""",
   {"v": "2026-02-01", "k": "2026-11-17"}).fetchall()
log("   bitemporal as-of (valid=2026-02-01, known<=2026-11-17), first rows: %s" % asof)
check("bitemporal query returns the superseded DR-0100 as valid on 2026-02-01", ("DR-0100",) in db.execute(
   "SELECT decision_id FROM decision WHERE valid_from<='2026-02-01' AND (valid_until IS NULL OR valid_until>='2026-02-01') AND status IN ('approved','superseded')").fetchall())

q = agent_conn(DB)
q.execute("INSERT INTO ai_decision(ai_decision_id,task_id,class_code,confidence,action,decided_at) VALUES (1,'t1','default',0.4,'proceed_with_assumption','2026-11-17')")
q.execute("INSERT INTO review_queue(ai_decision_id,related_decision_id,question,default_taken,raised_by,assignee_role,asked_at,expires_at,on_expire) VALUES (1,'AM-low','Is retry=3 ok?','retry=3','agent-1','senior','2026-11-01','2026-11-10 00:00:00','continue_and_renotify')")
due = q.execute("SELECT queue_id, on_expire, assignee_role, responsible_role FROM v_queue_due").fetchall()
log("   v_queue_due: %s" % due)
check("queue: expired item is routed to escalates_to(senior->owner)", due == [(1, "continue_and_renotify", "senior", "owner")])
expect_error("queue: agent cannot answer", lambda: q.execute("UPDATE review_queue SET state='answered', answered_by='senior-b', answer='ok'"), "not authorized")
expect_error("queue: non-human answerer rejected even on a raw writer", lambda: db.execute("UPDATE review_queue SET state='answered', answered_by='agent-1', answer='ok'"), "human principal")
db.execute("UPDATE review_queue SET state='answered', answered_by='senior-b', answer='ok'")
check("queue: human answer accepted", db.execute("SELECT state FROM review_queue").fetchone()[0] == "answered")

db.execute("INSERT INTO decision_use VALUES (1,'AM-low')"); db.execute("INSERT INTO decision_use VALUES (1,'DR-0001')")
db.execute("UPDATE source SET revoked_at='2026-11-01' WHERE source_id=1")
br = db.execute("SELECT count(DISTINCT decision_id), count(DISTINCT ai_decision_id) FROM v_blast_radius WHERE source_id=1").fetchone()
check("v_blast_radius lists decisions backed by the revoked source and the AI decision that used one", br[0] >= 3 and br[1] == 1, str(br))

db.execute("INSERT INTO eval_case VALUES (1,'S1-boss','default','test','2026-10-01','A','A'),(2,'S1-senior','default','test','2026-10-02','B','B')")
db.execute("INSERT INTO eval_result VALUES (1,'no_memory','A',0.5),(2,'no_memory','A',0.5),(1,'full_memory','A',0.9),(2,'full_memory','B',0.9)")
log("   v_agreement: %s" % db.execute("SELECT * FROM v_agreement ORDER BY arm").fetchall())

mk(db, "FTS-1", text="本番データの削除は人間の承認を要する")
hit = db.execute("SELECT d.decision_id FROM decision_fts f JOIN decision d ON d.rowid=f.rowid WHERE decision_fts MATCH '本番データ'").fetchall()
check("FTS5 trigram (external content) finds Japanese phrase >=3 chars", ("FTS-1",) in hit, str(hit))


log("\n=== 6. 既知の限界の実演 (E2 の境界条件) ===")
ag6 = agent_conn(DB)
for stmt in ("DROP TRIGGER trg_ap_proof", "DELETE FROM status_transition", "INSERT INTO authority_grant VALUES ('agent-1','global',99)",
             "UPDATE principal SET kind='human' WHERE principal_id='agent-1'"):
    expect_error("agent connection (authorizer) denies: " + stmt, lambda s_=stmt: ag6.execute(s_), "not authorized")
bk = os.path.join(tmp, "copy.db"); dst = sqlite3.connect(bk); db.backup(dst); dst.close()
raw = full_conn(bk, with_funcs=False)
mk(raw, "LIM-1")
for trg in ("trg_ap_proof", "trg_ap_evidence", "trg_ap_decider_evidence", "trg_ap_rank", "trg_ap_human"):
    raw.execute("DROP TRIGGER " + trg)
hh = hashlib.sha256(b"decision text of LIM-1").hexdigest()
raw.execute("INSERT INTO approval(decision_id,action,approver_id,approved_at,content_hash,proof_kind,proof_ref,proof_mac) VALUES ('LIM-1','approve','agent-1','2026-11-17',?,'signed_commit','x','x')", (hh,))
log("LIMIT (by design, not a PASS): a writer allowed to change the schema can DROP the guard triggers and forge an approval. LIM-1 status in the COPY = %s" %
    raw.execute("SELECT status FROM decision WHERE decision_id='LIM-1'").fetchone()[0])
log("   -> guard = (1) the agent only gets the authorizer-restricted connection, (2) the DB file is not writable by the agent process, (3) MAC key and signing keys stay outside the agent.")
check("original DB unaffected by the copy's tampering", status("DR-0010") == "approved" and db.execute("SELECT count(*) FROM decision WHERE decision_id='LIM-1'").fetchone()[0] == 0)

log("\n=== 結果 ===")
log("FAILED: %d  %s" % (len(fails), fails))
with open(LOG, "w", encoding="utf-8", newline="\n") as f: f.write("\n".join(out) + "\n")
sys.exit(1 if fails else 0)
