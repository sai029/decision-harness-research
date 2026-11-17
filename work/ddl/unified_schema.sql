-- 統合スキーマ v1 (担当A, round-1 再調査 E1/E2/E3/E9). SQLite >= 3.39.
-- 方針:
--  * 正本は Git 上の Markdown。この DB は再構築可能な索引 + エージェントの作業記録 (ai_decision 等)。
--  * 'approved' への遷移は approval 行の INSERT だけが起こす。approval は証明 (proof) を要する。
--    proof の検証はアプリ定義関数 verify_proof() で行う。関数を登録していない接続では
--    トリガが "no such function" で失敗する (fail closed)。MAC 鍵は承認サービス(CI)だけが持つ。
--  * アプリ定義関数: verify_proof(decision_id, action, content_hash, approver_id, proof_ref, proof_mac)
--                    verify_quote(source_id, quote)
--  * content_hash は valid_until / review_by を含めない (valid_until は短縮のみ可で、承認後に動くため)。
PRAGMA foreign_keys = ON;

---------------------------------------------------------------- 主体・権限
CREATE TABLE role (
  role_id     TEXT PRIMARY KEY,
  rank        INTEGER NOT NULL CHECK (rank >= 0),
  escalates_to TEXT REFERENCES role(role_id)      -- 期限切れ質問の責任の移し先
);

CREATE TABLE principal (                           -- 実名は入れない (alias)。実名対応表は別DB・別権限
  principal_id TEXT PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN ('human','agent','service')),
  role_id      TEXT REFERENCES role(role_id),
  git_email    TEXT UNIQUE                         -- 承認サービスが Git のコミットと突き合わせる
);

CREATE TABLE authority_grant (                     -- 権限ランクは (主体, scope) ごと。'global' は全体
  principal_id  TEXT NOT NULL REFERENCES principal(principal_id),
  scope_project TEXT NOT NULL,
  rank          INTEGER NOT NULL CHECK (rank > 0),
  PRIMARY KEY (principal_id, scope_project)
);

CREATE TABLE decision_class (                      -- F: 判断の種類別ポリシー
  class_code         TEXT PRIMARY KEY,
  floor_agent_mode   TEXT NOT NULL DEFAULT 'follow'
                     CHECK (floor_agent_mode IN ('follow','follow_and_log','ask_async','human_only')),
  min_confidence     REAL NOT NULL CHECK (min_confidence BETWEEN 0 AND 1),
  max_wrong_rate     REAL NOT NULL CHECK (max_wrong_rate BETWEEN 0 AND 1),
  default_ttl_days   INTEGER,
  CHECK (floor_agent_mode <> 'human_only' OR min_confidence = 1)   -- 確信度で解除できない
);

---------------------------------------------------------------- 同意・出所
CREATE TABLE consent (                             -- F
  consent_id          INTEGER PRIMARY KEY,
  subject_id          TEXT NOT NULL REFERENCES principal(principal_id),
  purposes            TEXT NOT NULL,
  scope               TEXT NOT NULL,
  external_llm_allowed INTEGER NOT NULL DEFAULT 0 CHECK (external_llm_allowed IN (0,1)),
  granted_at          TEXT NOT NULL,
  withdrawn_at        TEXT
);

CREATE TABLE source (                              -- B.source_item + F.source + C.evidence.sensitivity
  source_id    INTEGER PRIMARY KEY,
  ref          TEXT NOT NULL UNIQUE,               -- 例 synthetic://slack/C1/170936
  kind         TEXT NOT NULL CHECK (kind IN
               ('adr','pr_review','chat','meeting','minutes','mail','interview','agent_trace')),
  trust_tier   TEXT NOT NULL CHECK (trust_tier IN
               ('human_authored_verified','human_authored_unverified','third_party','agent_asserted')),
  author_id    TEXT REFERENCES principal(principal_id),
  sensitivity  TEXT NOT NULL DEFAULT 'internal' CHECK (sensitivity IN ('public','internal','restricted')),
  body_sha256  TEXT NOT NULL,
  consent_id   INTEGER REFERENCES consent(consent_id),
  redaction_done INTEGER NOT NULL DEFAULT 0 CHECK (redaction_done IN (0,1)),
  ingest_state TEXT NOT NULL DEFAULT 'not_ingested'
               CHECK (ingest_state IN ('full','anonymized_only','not_ingested')),   -- E10: 同意が取れない場合
  ingested_at  TEXT,
  revoked_at   TEXT,
  CHECK (ingest_state <> 'full' OR consent_id IS NOT NULL OR kind = 'adr')
);

CREATE TABLE extraction_run (                      -- F: ラン単位で一括 quarantine できる
  run_id   TEXT PRIMARY KEY,
  extractor TEXT NOT NULL,
  model    TEXT,
  prompt_version TEXT,
  run_at   TEXT NOT NULL
);

---------------------------------------------------------------- 判断本体
CREATE TABLE decision (
  decision_id  TEXT PRIMARY KEY,                   -- = Markdown ファイル名 (例 DR-0002)
  title        TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN
               ('principle','technical','product','process','preference','criterion')),
  status       TEXT NOT NULL DEFAULT 'candidate' CHECK (status IN
               ('candidate','quarantined','approved','rejected','superseded','expired','revoked')),
  origin       TEXT NOT NULL CHECK (origin IN ('human_stated','extracted','agent_proposed')),
  extraction_run_id TEXT REFERENCES extraction_run(run_id),
  decision_text TEXT NOT NULL,                     -- A.decision_text / B.decision / C.body / D.rule
  rationale    TEXT NOT NULL,
  tradeoff     TEXT,
  card         TEXT NOT NULL,                      -- 注入用 Y-statement (<=300字)
  class_code   TEXT NOT NULL REFERENCES decision_class(class_code),
  decided_by   TEXT REFERENCES principal(principal_id),     -- 候補段階では NULL 可 (B)
  required_role TEXT REFERENCES role(role_id),              -- 覆すのに必要な最小ロール
  reversibility TEXT NOT NULL CHECK (reversibility IN ('two_way','costly','one_way','unknown')),
  confidence   REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  confidence_basis TEXT NOT NULL CHECK (confidence_basis IN
               ('stated_explicitly','inferred_from_behavior','extracted_single_source','extracted_multi_source')),
  agent_mode   TEXT NOT NULL DEFAULT 'ask_async'
               CHECK (agent_mode IN ('follow','follow_and_log','ask_async','human_only')),
  fallback     TEXT,
  tier         INTEGER NOT NULL DEFAULT 2 CHECK (tier IN (0,1,2)),      -- D: 注入層
  scope_project TEXT NOT NULL DEFAULT 'global',
  scope_path   TEXT,                                -- glob。NULL=全パス
  valid_from   TEXT NOT NULL,                       -- bitemporal: 実世界で有効になった日
  valid_until  TEXT,                                -- 実世界で無効になる日(含む)。短縮のみ可
  review_by    TEXT,
  recorded_at  TEXT NOT NULL,                       -- bitemporal: 記録した日
  invalidated_at TEXT,                              -- bitemporal: 無効と知った(記録した)日
  source_path  TEXT NOT NULL,                       -- 正本 Markdown の相対パス
  content_hash TEXT NOT NULL,
  CHECK (valid_until IS NULL OR valid_until >= valid_from),
  CHECK (length(card) <= 300),
  CHECK (reversibility NOT IN ('one_way','unknown') OR agent_mode IN ('ask_async','human_only')),
  CHECK (status NOT IN ('approved','superseded','expired','revoked')
         OR (reversibility <> 'unknown' AND decided_by IS NOT NULL)),
  CHECK (origin <> 'extracted' OR extraction_run_id IS NOT NULL)
);
CREATE INDEX ix_decision_eff ON decision(status, scope_project, valid_until);

CREATE TABLE decision_scope (                      -- A: 複数次元の scope (path 以外の task_type 等)
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  dim TEXT NOT NULL CHECK (dim IN ('path','task_type')),
  pattern TEXT NOT NULL,
  exclude INTEGER NOT NULL DEFAULT 0 CHECK (exclude IN (0,1)),
  PRIMARY KEY (decision_id, dim, pattern)
);
CREATE TABLE decision_tag (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  PRIMARY KEY (decision_id, tag)
);
CREATE TABLE decision_trigger (                    -- D
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('tool','path','command','keyword')),
  pattern TEXT NOT NULL
);
CREATE TABLE decision_option (                     -- A: 却下案
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  chosen INTEGER NOT NULL CHECK (chosen IN (0,1)),
  why_not TEXT,
  reconsider_if TEXT,
  PRIMARY KEY (decision_id, label),
  CHECK (chosen = 1 OR why_not IS NOT NULL)
);
CREATE TABLE decision_assumption (                 -- A
  assumption_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('assumption','constraint')),
  text TEXT NOT NULL,
  check_hint TEXT,
  status TEXT NOT NULL DEFAULT 'holds' CHECK (status IN ('holds','unverified','broken'))
);

CREATE TABLE evidence (                            -- B.evidence + C.evidence + F.evidence
  evidence_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  source_id   INTEGER NOT NULL REFERENCES source(source_id),
  role        TEXT NOT NULL CHECK (role IN ('decision','rationale','decider','reversal')),
  quote       TEXT NOT NULL CHECK (length(quote) <= 300),   -- 抜粋の上限 (E12: 本文複製を避ける)
  quote_verified INTEGER NOT NULL DEFAULT 0 CHECK (quote_verified IN (0,1)),
  UNIQUE (decision_id, source_id, role)
);

CREATE TABLE decision_link (
  from_id TEXT NOT NULL REFERENCES decision(decision_id),
  to_id   TEXT NOT NULL REFERENCES decision(decision_id),
  link_type TEXT NOT NULL CHECK (link_type IN
    ('supersedes','proposes_supersede','overrides','conflicts_with','depends_on','refines')),
  PRIMARY KEY (from_id, to_id, link_type),
  CHECK (from_id <> to_id)
);

CREATE TABLE conflict_ticket (                     -- E9: 決まらない矛盾
  ticket_id INTEGER PRIMARY KEY,
  a_id TEXT NOT NULL REFERENCES decision(decision_id),
  b_id TEXT NOT NULL REFERENCES decision(decision_id),
  opened_at TEXT NOT NULL,
  reason TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','resolved')),
  CHECK (a_id < b_id)
);
CREATE UNIQUE INDEX ux_ticket_open ON conflict_ticket(a_id, b_id) WHERE state = 'open';

---------------------------------------------------------------- 承認 (E2)
CREATE TABLE approval (
  approval_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id),
  action      TEXT NOT NULL CHECK (action IN ('approve','revoke')),
  approver_id TEXT NOT NULL REFERENCES principal(principal_id),
  approved_at TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  proof_kind  TEXT NOT NULL CHECK (proof_kind IN ('git_merge','signed_commit')),
  proof_ref   TEXT NOT NULL,                       -- コミット SHA 等 (DB の外の事実)
  proof_mac   TEXT NOT NULL                        -- 承認サービスだけが作れる HMAC
);

---------------------------------------------------------------- 状態遷移 (E1)
CREATE TABLE status_transition (
  from_status TEXT NOT NULL,
  to_status   TEXT NOT NULL,
  gate TEXT NOT NULL CHECK (gate IN ('none','approve','revoke','supersede_link','expiry_time','never_approved')),
  PRIMARY KEY (from_status, to_status)
);
INSERT INTO status_transition VALUES
 ('candidate','approved','approve'),
 ('candidate','rejected','none'),
 ('candidate','quarantined','none'),
 ('quarantined','candidate','never_approved'),
 ('quarantined','rejected','none'),
 ('approved','superseded','supersede_link'),
 ('approved','expired','expiry_time'),
 ('approved','revoked','revoke'),
 ('approved','quarantined','revoke');
CREATE TRIGGER trg_st_lock_i BEFORE INSERT ON status_transition BEGIN SELECT RAISE(ABORT,'status_transition is locked'); END;
CREATE TRIGGER trg_st_lock_u BEFORE UPDATE ON status_transition BEGIN SELECT RAISE(ABORT,'status_transition is locked'); END;
CREATE TRIGGER trg_st_lock_d BEFORE DELETE ON status_transition BEGIN SELECT RAISE(ABORT,'status_transition is locked'); END;

---------------------------------------------------------------- 運用・評価 (F, C)
CREATE TABLE ai_decision (
  ai_decision_id INTEGER PRIMARY KEY,
  task_id TEXT NOT NULL,
  class_code TEXT NOT NULL REFERENCES decision_class(class_code),
  confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  action TEXT NOT NULL CHECK (action IN ('proceed','proceed_with_assumption','park_task','escalate')),
  decided_at TEXT NOT NULL,
  human_outcome TEXT NOT NULL DEFAULT 'unreviewed' CHECK (human_outcome IN ('agree','overturned','unreviewed'))
);
CREATE TABLE decision_use (
  ai_decision_id INTEGER NOT NULL REFERENCES ai_decision(ai_decision_id),
  decision_id TEXT NOT NULL REFERENCES decision(decision_id),
  PRIMARY KEY (ai_decision_id, decision_id)
);

CREATE TABLE review_queue (                        -- C.open_question + F.review_queue を1本化 (E7)
  queue_id INTEGER PRIMARY KEY,
  ai_decision_id INTEGER REFERENCES ai_decision(ai_decision_id),
  related_decision_id TEXT REFERENCES decision(decision_id),
  question TEXT NOT NULL,
  default_taken TEXT NOT NULL,                     -- 待たずに採った既定
  rollback_plan TEXT,
  raised_by TEXT NOT NULL REFERENCES principal(principal_id),     -- 書く人 (エージェント)
  assignee_role TEXT NOT NULL REFERENCES role(role_id),           -- 読む人 (人間のロール)
  asked_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  on_expire TEXT NOT NULL CHECK (on_expire IN ('confirm_default','continue_and_renotify','stay_parked')),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','answered','expired','dropped')),
  escalated_to_role TEXT REFERENCES role(role_id),
  answered_by TEXT REFERENCES principal(principal_id),
  answer TEXT,
  CHECK (ai_decision_id IS NOT NULL OR related_decision_id IS NOT NULL),
  CHECK (state <> 'answered' OR (answered_by IS NOT NULL AND answer IS NOT NULL))
);

CREATE TABLE eval_case (
  case_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id),
  class_code TEXT NOT NULL REFERENCES decision_class(class_code),
  split TEXT NOT NULL CHECK (split IN ('memory','calibration','test')),
  decided_at TEXT NOT NULL,
  human_choice TEXT NOT NULL,
  retest_choice TEXT
);
CREATE TABLE eval_result (
  case_id INTEGER NOT NULL REFERENCES eval_case(case_id),
  arm TEXT NOT NULL CHECK (arm IN ('no_memory','rule_default','shuffled_memory','full_memory')),
  ai_choice TEXT, confidence REAL,
  PRIMARY KEY (case_id, arm)
);

CREATE TABLE injection_log (                       -- D
  ts TEXT NOT NULL DEFAULT (datetime('now')),
  session_id TEXT, event TEXT, decision_id TEXT, rank INTEGER, chars INTEGER, latency_ms REAL
);

---------------------------------------------------------------- FTS (C: external content + trigram)
CREATE VIRTUAL TABLE decision_fts USING fts5(
  title, decision_text, rationale, content='decision', content_rowid='rowid', tokenize='trigram');
CREATE TRIGGER decision_fts_ai AFTER INSERT ON decision BEGIN
  INSERT INTO decision_fts(rowid,title,decision_text,rationale) VALUES (new.rowid,new.title,new.decision_text,new.rationale);
END;
CREATE TRIGGER decision_fts_ad AFTER DELETE ON decision BEGIN
  INSERT INTO decision_fts(decision_fts,rowid,title,decision_text,rationale) VALUES('delete',old.rowid,old.title,old.decision_text,old.rationale);
END;
CREATE TRIGGER decision_fts_au AFTER UPDATE OF title,decision_text,rationale ON decision BEGIN
  INSERT INTO decision_fts(decision_fts,rowid,title,decision_text,rationale) VALUES('delete',old.rowid,old.title,old.decision_text,old.rationale);
  INSERT INTO decision_fts(rowid,title,decision_text,rationale) VALUES (new.rowid,new.title,new.decision_text,new.rationale);
END;

---------------------------------------------------------------- 承認ランク (helper view)
CREATE VIEW v_decider_rank AS                      -- 判断者の、その判断の scope での権限ランク。権限なし=0
SELECT d.decision_id,
  COALESCE((SELECT MAX(g.rank) FROM authority_grant g
            WHERE g.principal_id = d.decided_by AND g.scope_project IN (d.scope_project,'global')), 0) AS rank
FROM decision d;

CREATE VIEW v_approver_rank AS                     -- 承認者の、その判断の scope での権限ランク
SELECT a.approval_id, a.decision_id, a.action, a.approver_id,
  COALESCE((SELECT MAX(g.rank) FROM authority_grant g
            WHERE g.principal_id = a.approver_id
              AND g.scope_project IN ((SELECT scope_project FROM decision WHERE decision_id = a.decision_id),'global')), 0) AS rank
FROM approval a;

---------------------------------------------------------------- トリガ: decision (E2, E3)
CREATE TRIGGER trg_dec_insert_status BEFORE INSERT ON decision
WHEN new.status NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'decision rows can only be inserted as candidate/quarantined; approval is a separate gated step'); END;

CREATE TRIGGER trg_dec_class_floor_i BEFORE INSERT ON decision
WHEN (SELECT floor_agent_mode FROM decision_class WHERE class_code=new.class_code)='human_only' AND new.agent_mode<>'human_only'
BEGIN SELECT RAISE(ABORT,'class floor is human_only'); END;
CREATE TRIGGER trg_dec_class_floor_u BEFORE UPDATE OF agent_mode, class_code ON decision
WHEN (SELECT floor_agent_mode FROM decision_class WHERE class_code=new.class_code)='human_only' AND new.agent_mode<>'human_only'
BEGIN SELECT RAISE(ABORT,'class floor is human_only'); END;

CREATE TRIGGER trg_dec_immutable BEFORE UPDATE OF
  decision_id, title, kind, origin, extraction_run_id, decision_text, rationale, tradeoff, card, class_code,
  decided_by, required_role, reversibility, confidence, confidence_basis, agent_mode, fallback, tier,
  scope_project, scope_path, valid_from, recorded_at, source_path, content_hash ON decision
WHEN old.status IN ('approved','superseded','expired','revoked')
BEGIN SELECT RAISE(ABORT,'approved decision is immutable: write a superseding record'); END;

CREATE TRIGGER trg_dec_valid_until_shrink BEFORE UPDATE OF valid_until ON decision
WHEN old.status <> 'candidate' AND old.status <> 'quarantined'
 AND (new.valid_until IS NULL OR (old.valid_until IS NOT NULL AND new.valid_until > old.valid_until))
BEGIN SELECT RAISE(ABORT,'valid_until may only be shortened after approval'); END;

CREATE TRIGGER trg_dec_delete BEFORE DELETE ON decision
WHEN old.status NOT IN ('candidate','quarantined','rejected')
BEGIN SELECT RAISE(ABORT,'approved decisions are never deleted'); END;

CREATE TRIGGER trg_dec_st_illegal BEFORE UPDATE OF status ON decision
WHEN new.status <> old.status AND NOT EXISTS
  (SELECT 1 FROM status_transition t WHERE t.from_status=old.status AND t.to_status=new.status)
BEGIN SELECT RAISE(ABORT,'illegal status transition'); END;

CREATE TRIGGER trg_dec_st_gate_approve BEFORE UPDATE OF status ON decision
WHEN new.status <> old.status
 AND (SELECT gate FROM status_transition t WHERE t.from_status=old.status AND t.to_status=new.status)='approve'
 AND NOT EXISTS (SELECT 1 FROM approval a WHERE a.decision_id=new.decision_id AND a.action='approve' AND a.content_hash=new.content_hash)
BEGIN SELECT RAISE(ABORT,'status gate: no approval row for this content'); END;

CREATE TRIGGER trg_dec_st_gate_revoke BEFORE UPDATE OF status ON decision
WHEN new.status <> old.status
 AND (SELECT gate FROM status_transition t WHERE t.from_status=old.status AND t.to_status=new.status)='revoke'
 AND NOT EXISTS (SELECT 1 FROM approval a WHERE a.decision_id=new.decision_id AND a.action='revoke' AND a.content_hash=new.content_hash)
BEGIN SELECT RAISE(ABORT,'status gate: no revoke approval row'); END;

CREATE TRIGGER trg_dec_st_gate_supersede BEFORE UPDATE OF status ON decision
WHEN new.status <> old.status
 AND (SELECT gate FROM status_transition t WHERE t.from_status=old.status AND t.to_status=new.status)='supersede_link'
 AND NOT EXISTS (SELECT 1 FROM decision_link l JOIN decision f ON f.decision_id=l.from_id
                 WHERE l.to_id=new.decision_id AND l.link_type='supersedes' AND f.status='approved')
BEGIN SELECT RAISE(ABORT,'status gate: no supersedes link from an approved decision'); END;

CREATE TRIGGER trg_dec_st_gate_expiry BEFORE UPDATE OF status ON decision
WHEN new.status <> old.status
 AND (SELECT gate FROM status_transition t WHERE t.from_status=old.status AND t.to_status=new.status)='expiry_time'
 AND (old.valid_until IS NULL OR old.valid_until >= date('now'))
BEGIN SELECT RAISE(ABORT,'status gate: valid_until has not passed'); END;

CREATE TRIGGER trg_dec_st_gate_never_approved BEFORE UPDATE OF status ON decision
WHEN new.status <> old.status
 AND (SELECT gate FROM status_transition t WHERE t.from_status=old.status AND t.to_status=new.status)='never_approved'
 AND EXISTS (SELECT 1 FROM approval a WHERE a.decision_id=new.decision_id)
BEGIN SELECT RAISE(ABORT,'status gate: decision was approved once; cannot return to candidate'); END;

CREATE TRIGGER trg_dec_invalidated AFTER UPDATE OF status ON decision
WHEN new.status IN ('superseded','expired','revoked','quarantined') AND new.invalidated_at IS NULL
BEGIN UPDATE decision SET invalidated_at = datetime('now') WHERE decision_id = new.decision_id; END;

---------------------------------------------------------------- トリガ: evidence (B: quote 検証)
CREATE TRIGGER trg_ev_quote_i BEFORE INSERT ON evidence
WHEN new.quote_verified = 1 AND verify_quote(new.source_id, new.quote) <> 1
BEGIN SELECT RAISE(ABORT,'quote_verified=1 but quote is not found in the source body'); END;
CREATE TRIGGER trg_ev_quote_u BEFORE UPDATE OF quote, quote_verified, source_id ON evidence
WHEN new.quote_verified = 1 AND verify_quote(new.source_id, new.quote) <> 1
BEGIN SELECT RAISE(ABORT,'quote_verified=1 but quote is not found in the source body'); END;
CREATE TRIGGER trg_ev_frozen_u BEFORE UPDATE ON evidence
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'evidence of an approved decision is frozen'); END;
CREATE TRIGGER trg_ev_frozen_d BEFORE DELETE ON evidence
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined','rejected')
BEGIN SELECT RAISE(ABORT,'evidence of an approved decision is frozen'); END;

---------------------------------------------------------------- トリガ: approval (E2)
CREATE TRIGGER trg_ap_human BEFORE INSERT ON approval
WHEN (SELECT kind FROM principal WHERE principal_id=new.approver_id) IS NOT 'human'
BEGIN SELECT RAISE(ABORT,'approver must be a human principal'); END;

CREATE TRIGGER trg_ap_proof BEFORE INSERT ON approval
WHEN verify_proof(new.decision_id, new.action, new.content_hash, new.approver_id, new.proof_ref, new.proof_mac) <> 1
BEGIN SELECT RAISE(ABORT,'approval proof invalid'); END;

CREATE TRIGGER trg_ap_hash BEFORE INSERT ON approval
WHEN new.content_hash IS NOT (SELECT content_hash FROM decision WHERE decision_id=new.decision_id)
BEGIN SELECT RAISE(ABORT,'approval content_hash does not match the decision'); END;

CREATE TRIGGER trg_ap_state BEFORE INSERT ON approval
WHEN (new.action='approve' AND (SELECT status FROM decision WHERE decision_id=new.decision_id) IS NOT 'candidate')
  OR (new.action='revoke'  AND (SELECT status FROM decision WHERE decision_id=new.decision_id) IS NOT 'approved')
BEGIN SELECT RAISE(ABORT,'approval: decision is not in the state this action applies to'); END;

CREATE TRIGGER trg_ap_rank BEFORE INSERT ON approval
WHEN COALESCE((SELECT MAX(g.rank) FROM authority_grant g WHERE g.principal_id=new.approver_id
               AND g.scope_project IN ((SELECT scope_project FROM decision WHERE decision_id=new.decision_id),'global')),0)
     < MAX(1, COALESCE((SELECT r.rank FROM role r WHERE r.role_id=(SELECT required_role FROM decision WHERE decision_id=new.decision_id)),0))
BEGIN SELECT RAISE(ABORT,'approver lacks authority in this scope / for required_role'); END;

CREATE TRIGGER trg_ap_evidence BEFORE INSERT ON approval
WHEN new.action='approve'
 AND (SELECT origin FROM decision WHERE decision_id=new.decision_id)='extracted'
 AND NOT EXISTS (
   SELECT 1 FROM evidence e JOIN source s ON s.source_id=e.source_id
   LEFT JOIN consent c ON c.consent_id=s.consent_id
   WHERE e.decision_id=new.decision_id AND e.quote_verified=1
     AND s.trust_tier <> 'agent_asserted' AND s.revoked_at IS NULL
     AND s.ingest_state='full' AND s.redaction_done=1
     AND (s.consent_id IS NULL OR c.withdrawn_at IS NULL))
BEGIN SELECT RAISE(ABORT,'approval needs verified, non-agent, consented, redacted, non-revoked evidence'); END;

CREATE TRIGGER trg_ap_decider_evidence BEFORE INSERT ON approval
WHEN new.action='approve'
 AND (SELECT origin FROM decision WHERE decision_id=new.decision_id)='extracted'
 AND (SELECT decided_by FROM decision WHERE decision_id=new.decision_id) IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM evidence e WHERE e.decision_id=new.decision_id AND e.role='decider' AND e.quote_verified=1)
BEGIN SELECT RAISE(ABORT,'decider attribution needs verified role=decider evidence'); END;

CREATE TRIGGER trg_ap_human_stated BEFORE INSERT ON approval
WHEN new.action='approve'
 AND (SELECT origin FROM decision WHERE decision_id=new.decision_id)='human_stated'
 AND new.approver_id IS NOT (SELECT decided_by FROM decision WHERE decision_id=new.decision_id)
BEGIN SELECT RAISE(ABORT,'human_stated decision must be approved by its own decider'); END;

CREATE TRIGGER trg_ap_apply AFTER INSERT ON approval
BEGIN
  UPDATE decision SET status='approved' WHERE decision_id=new.decision_id AND new.action='approve';
  UPDATE decision SET status='revoked'  WHERE decision_id=new.decision_id AND new.action='revoke';
END;
CREATE TRIGGER trg_ap_frozen_u BEFORE UPDATE ON approval BEGIN SELECT RAISE(ABORT,'approval rows are append-only'); END;
CREATE TRIGGER trg_ap_frozen_d BEFORE DELETE ON approval BEGIN SELECT RAISE(ABORT,'approval rows are append-only'); END;

---------------------------------------------------------------- トリガ: link (E3)
CREATE TRIGGER trg_link_gate BEFORE INSERT ON decision_link
WHEN new.link_type IN ('supersedes','overrides')
BEGIN
  SELECT RAISE(ABORT,'supersedes/overrides: both decisions must be approved')
   WHERE (SELECT status FROM decision WHERE decision_id=new.from_id) IS NOT 'approved'
      OR (SELECT status FROM decision WHERE decision_id=new.to_id)   IS NOT 'approved';
  SELECT RAISE(ABORT,'supersedes: scope_project must match (use overrides across scopes)')
   WHERE new.link_type='supersedes'
     AND (SELECT scope_project FROM decision WHERE decision_id=new.from_id)
         IS NOT (SELECT scope_project FROM decision WHERE decision_id=new.to_id);
  SELECT RAISE(ABORT,'supersedes/overrides: approver of the new decision has lower authority than the old one')
   WHERE (SELECT MAX(rank) FROM v_approver_rank WHERE decision_id=new.from_id AND action='approve')
       < (SELECT MAX(rank) FROM v_approver_rank WHERE decision_id=new.to_id AND action='approve');
  SELECT RAISE(ABORT,'supersedes/overrides: new approver does not satisfy old required_role')
   WHERE (SELECT MAX(rank) FROM v_approver_rank WHERE decision_id=new.from_id AND action='approve')
       < COALESCE((SELECT r.rank FROM role r WHERE r.role_id=(SELECT required_role FROM decision WHERE decision_id=new.to_id)),0);
END;

CREATE TRIGGER trg_link_supersede_apply AFTER INSERT ON decision_link
WHEN new.link_type='supersedes'
BEGIN
  UPDATE decision SET status='superseded',
    valid_until = MAX(valid_from, MIN(COALESCE(valid_until,'9999-12-31'),
                   date((SELECT valid_from FROM decision WHERE decision_id=new.from_id),'-1 day')))
  WHERE decision_id=new.to_id;
END;

CREATE TRIGGER trg_ticket_resolve BEFORE UPDATE OF state ON conflict_ticket
WHEN new.state='resolved'
 AND (SELECT winner FROM v_conflict_resolution r WHERE r.a_id=new.a_id AND r.b_id=new.b_id) IS NULL
BEGIN SELECT RAISE(ABORT,'ticket can only be resolved by an approved decision that yields a winner'); END;

CREATE TRIGGER trg_queue_answer BEFORE UPDATE OF state ON review_queue
WHEN new.state='answered' AND (SELECT kind FROM principal WHERE principal_id=new.answered_by) IS NOT 'human'
BEGIN SELECT RAISE(ABORT,'queue answers must come from a human principal'); END;

---------------------------------------------------------------- ビュー
CREATE VIEW v_effective AS                          -- 注入・適用してよい判断 (E3/E4)
SELECT d.*, (d.review_by IS NOT NULL AND d.review_by < date('now')) AS review_overdue
FROM decision d
WHERE d.status='approved' AND d.valid_from <= date('now')
  AND (d.valid_until IS NULL OR d.valid_until >= date('now'));

-- E9: 唯一の優先規則 (lex superior > lex specialis > lex posterior > 確信度 > 矛盾チケット)
--   0. 承認済みの overrides リンクがあれば、それ
--   1. 権限ランク (判断者の、その判断の scope での grant の最大値。grant なし=0)
--   2. scope の具体性 (project 指定=+1, path 指定=+1)
--   3. 新しい valid_from
--   4. 高い confidence
--   5. 以上で決まらない → winner NULL (conflict_ticket を開く)
CREATE VIEW v_conflict_resolution AS
WITH p AS (
  SELECT MIN(l.from_id,l.to_id) AS a_id, MAX(l.from_id,l.to_id) AS b_id
  FROM decision_link l
  JOIN v_effective x ON x.decision_id=l.from_id
  JOIN v_effective y ON y.decision_id=l.to_id
  WHERE l.link_type='conflicts_with'
  GROUP BY 1,2
), m AS (
  SELECT p.a_id, p.b_id,
    (SELECT rank FROM v_decider_rank WHERE decision_id=p.a_id) AS ra,
    (SELECT rank FROM v_decider_rank WHERE decision_id=p.b_id) AS rb,
    (SELECT (scope_project<>'global')+(scope_path IS NOT NULL) FROM decision WHERE decision_id=p.a_id) AS sa,
    (SELECT (scope_project<>'global')+(scope_path IS NOT NULL) FROM decision WHERE decision_id=p.b_id) AS sb,
    (SELECT valid_from FROM decision WHERE decision_id=p.a_id) AS va,
    (SELECT valid_from FROM decision WHERE decision_id=p.b_id) AS vb,
    (SELECT confidence FROM decision WHERE decision_id=p.a_id) AS ca,
    (SELECT confidence FROM decision WHERE decision_id=p.b_id) AS cb,
    EXISTS (SELECT 1 FROM decision_link o WHERE o.link_type='overrides' AND o.from_id=p.a_id AND o.to_id=p.b_id) AS a_over,
    EXISTS (SELECT 1 FROM decision_link o WHERE o.link_type='overrides' AND o.from_id=p.b_id AND o.to_id=p.a_id) AS b_over
  FROM p
)
SELECT a_id, b_id,
  CASE WHEN a_over THEN a_id WHEN b_over THEN b_id
       WHEN ra<>rb THEN CASE WHEN ra>rb THEN a_id ELSE b_id END
       WHEN sa<>sb THEN CASE WHEN sa>sb THEN a_id ELSE b_id END
       WHEN va<>vb THEN CASE WHEN va>vb THEN a_id ELSE b_id END
       WHEN ca<>cb THEN CASE WHEN ca>cb THEN a_id ELSE b_id END
  END AS winner,
  CASE WHEN a_over OR b_over THEN '0_overrides' WHEN ra<>rb THEN '1_authority' WHEN sa<>sb THEN '2_specificity'
       WHEN va<>vb THEN '3_recency' WHEN ca<>cb THEN '4_confidence' ELSE '5_tie_open_ticket' END AS rule
FROM m;

-- 矛盾チケットを開く (承認サービス/スイーパが実行する文)。エージェント接続でも書ける(保守側に倒す操作)。
-- INSERT INTO conflict_ticket(a_id,b_id,opened_at,reason)
--   SELECT a_id,b_id,datetime('now'),rule FROM v_conflict_resolution r
--   WHERE winner IS NULL AND NOT EXISTS (SELECT 1 FROM conflict_ticket t WHERE t.a_id=r.a_id AND t.b_id=r.b_id AND t.state='open');

-- E7/E1: 単一の動作規則。エージェントはこのビューを引く。
--   人間専用 → escalate / 一方通行・不明 → park_task / 負けた側 → overridden /
--   矛盾チケット未解決・確信度不足・ask_async → proceed_with_assumption / それ以外 → proceed
CREATE VIEW v_agent_action AS
SELECT e.decision_id, e.agent_mode, e.reversibility, e.confidence, c.min_confidence,
  EXISTS (SELECT 1 FROM conflict_ticket t WHERE t.state='open' AND e.decision_id IN (t.a_id,t.b_id)) AS conflict_open,
  CASE
    WHEN e.decision_id IN (SELECT CASE WHEN winner=a_id THEN b_id ELSE a_id END
                           FROM v_conflict_resolution WHERE winner IS NOT NULL) THEN 'overridden'
    WHEN e.agent_mode='human_only' THEN 'escalate'
    WHEN e.reversibility IN ('one_way','unknown') THEN 'park_task'
    WHEN EXISTS (SELECT 1 FROM conflict_ticket t WHERE t.state='open' AND e.decision_id IN (t.a_id,t.b_id))
      THEN 'proceed_with_assumption'
    WHEN e.confidence < c.min_confidence THEN 'proceed_with_assumption'
    WHEN e.agent_mode='ask_async' THEN 'proceed_with_assumption'
    ELSE 'proceed' END AS action
FROM v_effective e JOIN decision_class c ON c.class_code=e.class_code;

-- E7: 質問キューの期限切れ処理。責任者 = assignee_role の escalates_to (無ければ同ロール)
CREATE VIEW v_queue_due AS
SELECT q.queue_id, q.question, q.on_expire, q.assignee_role,
  COALESCE(r.escalates_to, q.assignee_role) AS responsible_role,
  CASE q.on_expire WHEN 'confirm_default' THEN 'mark default as final, state=expired'
                   WHEN 'continue_and_renotify' THEN 'keep default, renotify responsible_role'
                   ELSE 'stay parked, renotify responsible_role' END AS next_step
FROM review_queue q JOIN role r ON r.role_id=q.assignee_role
WHERE q.state='open' AND q.expires_at < datetime('now');

CREATE VIEW v_blast_radius AS                       -- F: ソース失効/同意撤回の影響範囲
SELECT s.source_id, d.decision_id, d.status, u.ai_decision_id
FROM source s
JOIN evidence e ON e.source_id=s.source_id
JOIN decision d ON d.decision_id=e.decision_id
LEFT JOIN consent c ON c.consent_id=s.consent_id
LEFT JOIN decision_use u ON u.decision_id=d.decision_id
WHERE s.revoked_at IS NOT NULL OR c.withdrawn_at IS NOT NULL;

CREATE VIEW v_agreement AS                          -- F
SELECT c.class_code, r.arm, COUNT(*) AS n,
       AVG(r.ai_choice = c.human_choice) AS agree,
       AVG(c.retest_choice = c.human_choice) AS retest_ceiling
FROM eval_case c JOIN eval_result r ON r.case_id=c.case_id
WHERE c.split='test'
GROUP BY c.class_code, r.arm;
