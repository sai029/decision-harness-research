-- 統合スキーマ v2 (担当A, round-2: E1仕上げ / E2承認方式の統一 / E9優先規則の統一). SQLite >= 3.39. 旧版 unified_schema.sql は残してある。
-- 方針:
--  * 正本は Git 上の Markdown。この DB は再構築可能な索引 (decision 系) + 追記専用の台帳 (approval, decision_history, ai_decision 等)。
--  * 承認は「承認者が自分の SSH 鍵 (ed25519) で署名した 1 行」だけ (SSHSIG, namespace=decision-approval)。
--    検証は公開鍵だけで行える (allowed_signers は DB の外・Git の CODEOWNERS 配下)。HMAC は使わない (検証者が偽造できてしまう)。
--  * アプリ定義関数 (接続ごとに登録する。未登録の接続ではトリガが "no such function" で失敗する = fail closed):
--      全接続   : canon_hash(27 args) / sha256_text(text) / verify_span(source_id, start, end, sha256)   (純粋な関数。書込みの権限は与えない)
--      承認系   : verify_sig(principal_id, message, sig)   (承認サービスと再検証プロセスの接続だけ)
--  * content_hash = canon_hash(意味を持つ列)。DB の列とハッシュは常に一致する (人が承認したものと DB の中身が食い違えない)。
--  * evidence は本文を複製しない: 参照(source) + 範囲(start,end) + sha256 だけ。抜粋は派生キャッシュ (evidence_excerpt, 期限つき, Git/再構築の対象外)。
--  * kind='adr' の source は consent なしで full 取り込みできる例外を残す。【法務未確認】(人間の判断 2026-11-17: 法務確認は後回し)
PRAGMA foreign_keys = ON;

---------------------------------------------------------------- 主体・権限・scope 木
CREATE TABLE role (
  role_id     TEXT PRIMARY KEY,
  rank        INTEGER NOT NULL CHECK (rank >= 0),
  escalates_to TEXT REFERENCES role(role_id)
);

CREATE TABLE principal (                           -- 実名は入れない (alias)。実名対応表は別DB・別権限
  principal_id TEXT PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN ('human','agent','service')),
  role_id      TEXT REFERENCES role(role_id),
  git_email    TEXT UNIQUE                         -- 監査用 (コミットとの突き合わせ)。承認の根拠にはしない
);

CREATE TABLE scope_node (                          -- F.scope_node: global > 部署 > プロジェクト の木
  scope  TEXT PRIMARY KEY,
  parent TEXT REFERENCES scope_node(scope),
  CHECK ((scope = 'global' AND parent IS NULL) OR (scope <> 'global' AND parent IS NOT NULL AND parent <> scope))
);
INSERT INTO scope_node VALUES ('global', NULL);
CREATE TRIGGER trg_scope_lock_u BEFORE UPDATE ON scope_node BEGIN SELECT RAISE(ABORT,'scope_node is append-only (no re-parenting)'); END;
CREATE TRIGGER trg_scope_lock_d BEFORE DELETE ON scope_node BEGIN SELECT RAISE(ABORT,'scope_node is append-only'); END;

CREATE TABLE authority_grant (                     -- F.scope_authority: 権限ランクは (主体, scope)。子 scope に継承される
  principal_id  TEXT NOT NULL REFERENCES principal(principal_id),
  scope_project TEXT NOT NULL REFERENCES scope_node(scope),
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
  queue_ttl_hours    INTEGER NOT NULL DEFAULT 48,    -- F R-F6
  renotify_hours     INTEGER NOT NULL DEFAULT 24,
  CHECK (floor_agent_mode <> 'human_only' OR min_confidence = 1)
);

CREATE VIEW v_scope_closure AS                     -- scope と、その祖先 (自分を含む)。dist=0 が自分
WITH RECURSIVE c(scope, ancestor, dist) AS (
  SELECT scope, scope, 0 FROM scope_node
  UNION
  SELECT c.scope, n.parent, c.dist + 1 FROM c JOIN scope_node n ON n.scope = c.ancestor WHERE n.parent IS NOT NULL)
SELECT scope, ancestor, dist FROM c;

CREATE VIEW v_scope_depth AS
SELECT scope, MAX(dist) AS depth FROM v_scope_closure WHERE ancestor = 'global' GROUP BY scope;

CREATE VIEW v_authority AS                         -- 主体の、ある scope での権限ランク (祖先の grant の最大値)。grant なしの組は行が無い
SELECT g.principal_id, c.scope, MAX(g.rank) AS rank
FROM authority_grant g JOIN v_scope_closure c ON c.ancestor = g.scope_project
GROUP BY g.principal_id, c.scope;

---------------------------------------------------------------- 同意・出所
CREATE TABLE consent (
  consent_id          INTEGER PRIMARY KEY,
  subject_id          TEXT NOT NULL REFERENCES principal(principal_id),
  purposes            TEXT NOT NULL,
  scope               TEXT NOT NULL,
  external_llm_allowed INTEGER NOT NULL DEFAULT 0 CHECK (external_llm_allowed IN (0,1)),
  granted_at          TEXT NOT NULL,
  withdrawn_at        TEXT
);

CREATE TABLE service_terms (                       -- F R-F3: 取り込み元サービスの規約確認状態
  service       TEXT PRIMARY KEY,
  ai_processing TEXT NOT NULL DEFAULT 'unverified' CHECK (ai_processing IN ('allowed','restricted','prohibited','unverified')),
  checked_at    TEXT,
  evidence_url  TEXT,
  CHECK (ai_processing <> 'allowed' OR (checked_at IS NOT NULL AND evidence_url IS NOT NULL))
);

CREATE TABLE source (                              -- B.source_item + F.source + C.evidence.sensitivity
  source_id    INTEGER PRIMARY KEY,
  ref          TEXT NOT NULL UNIQUE,               -- 例 synthetic://slack/C1/170936
  kind         TEXT NOT NULL CHECK (kind IN
               ('adr','pr_review','chat','meeting','minutes','mail','interview','agent_trace')),
  trust_tier   TEXT NOT NULL DEFAULT 'human_authored_unverified' CHECK (trust_tier IN   -- B.trust の既定 untrusted に相当
               ('human_authored_verified','human_authored_unverified','third_party','agent_asserted')),
  author_id    TEXT REFERENCES principal(principal_id),
  sensitivity  TEXT NOT NULL DEFAULT 'internal' CHECK (sensitivity IN ('public','internal','restricted')),
  body_sha256  TEXT NOT NULL,
  consent_id   INTEGER REFERENCES consent(consent_id),
  service      TEXT REFERENCES service_terms(service),
  processor    TEXT NOT NULL DEFAULT 'local' CHECK (processor IN ('local','external_llm')),
  redaction_done INTEGER NOT NULL DEFAULT 0 CHECK (redaction_done IN (0,1)),
  anonymization_reviewed_by TEXT REFERENCES principal(principal_id),
  ingest_state TEXT NOT NULL DEFAULT 'not_ingested'
               CHECK (ingest_state IN ('full','anonymized_only','not_ingested')),
  ingested_at  TEXT,
  revoked_at   TEXT,
  CHECK (ingest_state <> 'full' OR consent_id IS NOT NULL OR kind = 'adr'),          -- adr 例外 (法務未確認)
  CHECK (kind <> 'agent_trace' OR trust_tier = 'agent_asserted'),
  CHECK (ingest_state <> 'anonymized_only' OR anonymization_reviewed_by IS NOT NULL)
);
CREATE TRIGGER trg_src_terms_i BEFORE INSERT ON source
WHEN new.service IS NOT NULL AND new.ingest_state <> 'not_ingested'
 AND (SELECT ai_processing FROM service_terms WHERE service = new.service) <> 'allowed'
BEGIN SELECT RAISE(ABORT,'source: service terms not verified as allowed; only not_ingested is possible'); END;
CREATE TRIGGER trg_src_terms_u BEFORE UPDATE ON source
WHEN new.service IS NOT NULL AND new.ingest_state <> 'not_ingested'
 AND (SELECT ai_processing FROM service_terms WHERE service = new.service) <> 'allowed'
BEGIN SELECT RAISE(ABORT,'source: service terms not verified as allowed; only not_ingested is possible'); END;
CREATE TRIGGER trg_src_extllm_i BEFORE INSERT ON source
WHEN new.processor = 'external_llm' AND new.ingest_state = 'full'
 AND COALESCE((SELECT external_llm_allowed FROM consent WHERE consent_id = new.consent_id), 0) <> 1
BEGIN SELECT RAISE(ABORT,'source: external_llm processing needs consent.external_llm_allowed=1 (no adr exception)'); END;
CREATE TRIGGER trg_src_extllm_u BEFORE UPDATE ON source
WHEN new.processor = 'external_llm' AND new.ingest_state = 'full'
 AND COALESCE((SELECT external_llm_allowed FROM consent WHERE consent_id = new.consent_id), 0) <> 1
BEGIN SELECT RAISE(ABORT,'source: external_llm processing needs consent.external_llm_allowed=1 (no adr exception)'); END;
CREATE TRIGGER trg_consent_withdraw AFTER UPDATE OF withdrawn_at ON consent   -- F R-F1: 撤回は source に伝播
WHEN new.withdrawn_at IS NOT NULL
BEGIN UPDATE source SET ingest_state = 'not_ingested', revoked_at = COALESCE(revoked_at, new.withdrawn_at)
      WHERE consent_id = new.consent_id; END;

CREATE TABLE extraction_run (
  run_id   TEXT PRIMARY KEY,
  extractor TEXT NOT NULL,
  model    TEXT,
  prompt_version TEXT,
  run_at   TEXT NOT NULL
);

---------------------------------------------------------------- 判断本体
CREATE TABLE decision (
  decision_id  TEXT PRIMARY KEY,
  title        TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN
               ('principle','technical','product','process','preference','criterion')),
  status       TEXT NOT NULL DEFAULT 'candidate' CHECK (status IN
               ('candidate','quarantined','approved','rejected','superseded','expired','revoked')),
  origin       TEXT NOT NULL CHECK (origin IN ('human_stated','extracted','agent_proposed')),
  extraction_run_id TEXT REFERENCES extraction_run(run_id),
  created_by   TEXT NOT NULL REFERENCES principal(principal_id),   -- F: 作成者 (承認者と別人であること)
  decision_text TEXT NOT NULL,
  rationale    TEXT,                                 -- B: 発言に無ければ NULL (捏造しない)
  criterion_hypothesis TEXT,                         -- B: 推測は事実欄から隔離。注入しない
  tradeoff     TEXT,
  card         TEXT NOT NULL,                        -- 注入用 Y-statement (<=300字)
  class_code   TEXT NOT NULL REFERENCES decision_class(class_code),
  topic_key    TEXT,                                 -- C.topic_key / F.topic_key / D.topic: 同一論点の矛盾検出キー
  choice       TEXT,                                 -- F.choice: その論点での結論 (同一 topic_key で choice が違えば矛盾)
  strength     TEXT NOT NULL DEFAULT 'default' CHECK (strength IN ('default','mandatory')),  -- F.strength = C の overridable=0 に相当
  supersedes_ids TEXT,                               -- 'DR-1,DR-2'。承認者が署名した内容の一部。decision_link(supersedes) はこの宣言があるときだけ挿入できる
  overrides_ids  TEXT,                               -- 同上 (overrides)
  decided_by   TEXT REFERENCES principal(principal_id),
  required_role TEXT REFERENCES role(role_id),
  reversibility TEXT NOT NULL CHECK (reversibility IN ('two_way','costly','one_way','unknown')),
  confidence   REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  confidence_basis TEXT NOT NULL CHECK (confidence_basis IN
               ('stated_explicitly','inferred_from_behavior','extracted_single_source','extracted_multi_source')),
  agent_mode   TEXT NOT NULL DEFAULT 'ask_async'
               CHECK (agent_mode IN ('follow','follow_and_log','ask_async','human_only')),
  fallback     TEXT,
  tier         INTEGER NOT NULL DEFAULT 2 CHECK (tier IN (0,1,2)),
  scope_project TEXT NOT NULL DEFAULT 'global' REFERENCES scope_node(scope),
  scope_path   TEXT,
  valid_from   TEXT NOT NULL CHECK (valid_from GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  valid_until  TEXT CHECK (valid_until IS NULL OR valid_until GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  review_by    TEXT CHECK (review_by IS NULL OR review_by GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  recorded_at  TEXT NOT NULL CHECK (recorded_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  invalidated_at TEXT,
  source_path  TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  CHECK (valid_until IS NULL OR valid_until >= valid_from),
  CHECK (length(card) <= 300),
  CHECK (choice IS NULL OR topic_key IS NOT NULL),
  CHECK (reversibility NOT IN ('one_way','unknown') OR agent_mode IN ('ask_async','human_only')),
  CHECK (status NOT IN ('approved','superseded','expired','revoked')
         OR (reversibility <> 'unknown' AND decided_by IS NOT NULL)),
  CHECK (origin <> 'extracted' OR extraction_run_id IS NOT NULL)
);
CREATE INDEX ix_decision_eff ON decision(status, scope_project, valid_until);
CREATE INDEX ix_decision_topic ON decision(topic_key);

CREATE TABLE decision_scope (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  dim TEXT NOT NULL CHECK (dim IN ('path','task_type')),
  pattern TEXT NOT NULL,
  exclude INTEGER NOT NULL DEFAULT 0 CHECK (exclude IN (0,1)),
  PRIMARY KEY (decision_id, dim, pattern)
);
CREATE TABLE decision_tag (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  not_followed_by TEXT,                              -- D: 複合語の誤発火ガード (空白区切り)
  PRIMARY KEY (decision_id, tag)
);
CREATE TABLE decision_trigger (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('tool','path','command','keyword')),
  pattern TEXT NOT NULL,
  action TEXT NOT NULL DEFAULT 'inject' CHECK (action IN ('inject','ask','deny')),   -- D: フックでの強制の種類
  CHECK (action = 'inject' OR kind <> 'keyword')     -- D: タグ/キーワードでは deny/ask しない (誤発火で止めない)
);
CREATE TABLE decision_option (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  chosen INTEGER NOT NULL CHECK (chosen IN (0,1)),
  why_not TEXT,
  reconsider_if TEXT,
  PRIMARY KEY (decision_id, label),
  CHECK (chosen = 1 OR why_not IS NOT NULL)
);
CREATE TABLE decision_assumption (
  assumption_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('assumption','constraint')),
  text TEXT NOT NULL,
  check_hint TEXT,
  status TEXT NOT NULL DEFAULT 'holds' CHECK (status IN ('holds','unverified','broken'))
);

CREATE TABLE evidence (                            -- 本文を持たない。参照 + 範囲 + sha256 (C の方針) で B の quote 検証も満たす
  evidence_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  source_id   INTEGER NOT NULL REFERENCES source(source_id),
  role        TEXT NOT NULL CHECK (role IN ('decision','rationale','decider','reversal')),
  quote_start INTEGER NOT NULL CHECK (quote_start >= 0),                 -- 本文の文字オフセット [start, end)
  quote_end   INTEGER NOT NULL,
  quote_sha256 TEXT NOT NULL,                                            -- 本文[start,end) の sha256
  quote_verified INTEGER NOT NULL DEFAULT 0 CHECK (quote_verified IN (0,1)),   -- 1 = 機械が本文を再読して一致を確認
  UNIQUE (decision_id, source_id, role),
  CHECK (quote_end > quote_start AND quote_end - quote_start <= 300)
);
CREATE TABLE evidence_excerpt (                    -- 派生キャッシュ。Git/再構築の対象外。期限つきで削除できる
  evidence_id INTEGER PRIMARY KEY REFERENCES evidence(evidence_id) ON DELETE CASCADE,
  excerpt     TEXT NOT NULL CHECK (length(excerpt) <= 300),
  expires_at  TEXT NOT NULL
);

CREATE TABLE decision_link (
  from_id TEXT NOT NULL REFERENCES decision(decision_id),
  to_id   TEXT NOT NULL REFERENCES decision(decision_id),
  link_type TEXT NOT NULL CHECK (link_type IN
    ('supersedes','proposes_supersede','overrides','conflicts_with','depends_on','refines')),
  PRIMARY KEY (from_id, to_id, link_type),
  CHECK (from_id <> to_id)
);

CREATE TABLE conflict_ticket (
  ticket_id INTEGER PRIMARY KEY,
  a_id TEXT NOT NULL REFERENCES decision(decision_id),
  b_id TEXT NOT NULL REFERENCES decision(decision_id),
  opened_at TEXT NOT NULL,
  reason TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','resolved')),
  CHECK (a_id < b_id)
);
CREATE UNIQUE INDEX ux_ticket_open ON conflict_ticket(a_id, b_id) WHERE state = 'open';

---------------------------------------------------------------- 承認 (E2: 統一方式 = SSH 署名)
CREATE TABLE approval (
  approval_id INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(decision_id),
  action      TEXT NOT NULL CHECK (action IN ('approve','revoke','shorten')),
  approver_id TEXT NOT NULL REFERENCES principal(principal_id),
  approved_at TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  new_valid_until TEXT CHECK (new_valid_until IS NULL OR new_valid_until GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  sig         TEXT NOT NULL,                       -- ssh-keygen -Y sign -n decision-approval の出力 (SSHSIG)。署名対象は下の message
  commit_ref  TEXT,                                -- 任意: 同じ変更を含む Git コミット SHA (監査用。DB は信用しない)
  CHECK ((action = 'shorten') = (new_valid_until IS NOT NULL))
);
-- 署名対象 message (トリガが列から組み立てる。呼び出し側が別の文字列を渡すことはできない):
--   'decision-approval/v2|' || decision_id || '|' || action || '|' || content_hash || '|' || COALESCE(new_valid_until,'') || '|' || approver_id || '|' || approved_at

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

---------------------------------------------------------------- 版履歴 (C R-C1: bitemporal を版ごとに残す)
CREATE TABLE decision_history (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id),
  version_no  INTEGER NOT NULL,
  status      TEXT NOT NULL,
  valid_from  TEXT NOT NULL,
  valid_until TEXT,
  recorded_from TEXT NOT NULL,                     -- この版を知った(記録した)時刻 (UTC, ミリ秒)
  recorded_to   TEXT,                              -- この版が次の版に置き換わった時刻。NULL = 現行
  cause       TEXT NOT NULL,
  PRIMARY KEY (decision_id, version_no)
);
CREATE TRIGGER trg_hist_u BEFORE UPDATE ON decision_history
WHEN NOT (old.recorded_to IS NULL AND new.recorded_to IS NOT NULL
          AND new.decision_id = old.decision_id AND new.version_no = old.version_no AND new.status = old.status
          AND new.valid_from = old.valid_from AND new.valid_until IS old.valid_until
          AND new.recorded_from = old.recorded_from AND new.cause = old.cause)
BEGIN SELECT RAISE(ABORT,'decision_history is append-only (only closing recorded_to is allowed)'); END;
CREATE TRIGGER trg_hist_d BEFORE DELETE ON decision_history BEGIN SELECT RAISE(ABORT,'decision_history is append-only'); END;
CREATE TRIGGER trg_hist_ai AFTER INSERT ON decision
BEGIN INSERT INTO decision_history VALUES (new.decision_id, 1, new.status, new.valid_from, new.valid_until,
       strftime('%Y-%m-%dT%H:%M:%f','now'), NULL, 'insert'); END;
CREATE TRIGGER trg_hist_au AFTER UPDATE OF status, valid_until ON decision
WHEN new.status IS NOT old.status OR new.valid_until IS NOT old.valid_until
BEGIN
  UPDATE decision_history SET recorded_to = strftime('%Y-%m-%dT%H:%M:%f','now')
   WHERE decision_id = new.decision_id AND recorded_to IS NULL;
  INSERT INTO decision_history
  SELECT new.decision_id, COALESCE(MAX(version_no),0) + 1, new.status, new.valid_from, new.valid_until,
         strftime('%Y-%m-%dT%H:%M:%f','now'), NULL,
         CASE WHEN new.status IS NOT old.status THEN 'status:' || old.status || '>' || new.status ELSE 'valid_until' END
  FROM decision_history WHERE decision_id = new.decision_id;
END;
-- as-of クエリ (valid 時点 :v 'YYYY-MM-DD'、知識時点 :k ISO 時刻)。status は「その時点で知っていた状態」:
--   SELECT decision_id FROM decision_history WHERE valid_from <= :v AND (valid_until IS NULL OR valid_until >= :v)
--     AND recorded_from <= :k AND (recorded_to IS NULL OR recorded_to > :k) AND status IN ('approved','superseded','expired');

---------------------------------------------------------------- 運用・評価 (F, C)
CREATE TABLE ai_decision (
  ai_decision_id INTEGER PRIMARY KEY,
  task_id TEXT NOT NULL,
  class_code TEXT NOT NULL REFERENCES decision_class(class_code),
  scope_project TEXT NOT NULL DEFAULT 'global' REFERENCES scope_node(scope),    -- F R-F8
  topic_key TEXT,
  reversibility TEXT NOT NULL DEFAULT 'unknown' CHECK (reversibility IN ('two_way','costly','one_way','unknown')),
  confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  action TEXT NOT NULL CHECK (action IN ('proceed','proceed_with_assumption','park_task','escalate')),
  question TEXT,
  default_taken TEXT,
  rollback_plan TEXT,
  decided_at TEXT NOT NULL,
  human_outcome TEXT NOT NULL DEFAULT 'unreviewed' CHECK (human_outcome IN ('agree','overturned','unreviewed')),
  CHECK (action <> 'proceed_with_assumption' OR default_taken IS NOT NULL)
);
CREATE TABLE decision_use (
  ai_decision_id INTEGER NOT NULL REFERENCES ai_decision(ai_decision_id),
  decision_id TEXT NOT NULL REFERENCES decision(decision_id),
  PRIMARY KEY (ai_decision_id, decision_id)
);

CREATE TABLE review_queue (                        -- C.open_question + F.review_queue + D.open_question(spool) を1本化
  queue_id INTEGER PRIMARY KEY,
  ai_decision_id INTEGER REFERENCES ai_decision(ai_decision_id),
  related_decision_id TEXT REFERENCES decision(decision_id),
  question TEXT NOT NULL,
  default_taken TEXT NOT NULL,
  rollback_plan TEXT,
  raised_by TEXT NOT NULL REFERENCES principal(principal_id),
  assignee_role TEXT NOT NULL REFERENCES role(role_id),
  asked_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  on_expire TEXT NOT NULL CHECK (on_expire IN ('confirm_default','continue_and_renotify','stay_parked')),
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','answered','expired','dropped')),
  escalated_to_role TEXT REFERENCES role(role_id),
  answered_by TEXT REFERENCES principal(principal_id),
  answered_at TEXT,
  answer TEXT,
  answer_sig TEXT,                                 -- F R-F8: 回答は承認と同じ SSH 署名 (namespace decision-approval)
  CHECK (ai_decision_id IS NOT NULL OR related_decision_id IS NOT NULL),
  CHECK (state <> 'answered' OR (answered_by IS NOT NULL AND answer IS NOT NULL AND answered_at IS NOT NULL AND answer_sig IS NOT NULL))
);

CREATE TABLE eval_run (                            -- F R-F9
  run_id TEXT PRIMARY KEY,
  environment TEXT NOT NULL CHECK (environment IN ('synthetic','private')),
  code_version TEXT NOT NULL,
  model TEXT,
  k_samples INTEGER NOT NULL DEFAULT 1 CHECK (k_samples >= 1),
  run_at TEXT NOT NULL
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
  run_id TEXT NOT NULL REFERENCES eval_run(run_id),
  case_id INTEGER NOT NULL REFERENCES eval_case(case_id),
  arm TEXT NOT NULL CHECK (arm IN ('no_memory','rule_default','shuffled_memory','full_memory')),
  ai_choice TEXT, confidence REAL,
  PRIMARY KEY (run_id, case_id, arm)
);

---------------------------------------------------------------- 別ファイルのログ DB (D の要件: 判断DBと別ファイル)
-- 判断DBにはフックに書込み権限を与えない (承認経路と取り込みプロセスだけが書く)。フックは判断DBを mode=ro で開き、この DB にだけ書く。
-- 判断DBへの展開では @@LOG_DB の区間を除く。ここに残すのは、1ファイルで DDL を検査できるようにするため。
-- @@LOG_DB_BEGIN
CREATE TABLE injection_log (
  ts TEXT NOT NULL DEFAULT (datetime('now')),
  session_id TEXT NOT NULL,
  agent_id   TEXT,                                 -- D: subagent の帰属 (フック入力の agent_id。メインスレッドは NULL)
  agent_type TEXT,
  event TEXT NOT NULL,
  decision_id TEXT,                                -- 別ファイルのため FK なし
  rank INTEGER, chars INTEGER, latency_ms REAL
);
CREATE INDEX ix_inj_session ON injection_log(session_id, decision_id);
CREATE TABLE question_spool (                      -- D §2.5b: フックが deny 時に積む。取り込みプロセスだけが review_queue に移す
  spool_id INTEGER PRIMARY KEY,
  ts TEXT NOT NULL DEFAULT (datetime('now')),
  session_id TEXT NOT NULL,
  agent_id TEXT, agent_type TEXT,
  decision_id TEXT,
  question TEXT NOT NULL,
  default_taken TEXT NOT NULL,
  assignee_role TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  on_expire TEXT NOT NULL CHECK (on_expire IN ('confirm_default','continue_and_renotify','stay_parked')),
  imported INTEGER NOT NULL DEFAULT 0 CHECK (imported IN (0,1))
);
-- @@LOG_DB_END

---------------------------------------------------------------- FTS (C: external content + trigram)
CREATE VIRTUAL TABLE decision_fts USING fts5(
  title, decision_text, rationale, content='decision', content_rowid='rowid', tokenize='trigram');
CREATE TRIGGER decision_fts_ai AFTER INSERT ON decision BEGIN
  INSERT INTO decision_fts(rowid,title,decision_text,rationale) VALUES (new.rowid,new.title,new.decision_text,COALESCE(new.rationale,''));
END;
CREATE TRIGGER decision_fts_ad AFTER DELETE ON decision BEGIN
  INSERT INTO decision_fts(decision_fts,rowid,title,decision_text,rationale) VALUES('delete',old.rowid,old.title,old.decision_text,COALESCE(old.rationale,''));
END;
CREATE TRIGGER decision_fts_au AFTER UPDATE OF title,decision_text,rationale ON decision BEGIN
  INSERT INTO decision_fts(decision_fts,rowid,title,decision_text,rationale) VALUES('delete',old.rowid,old.title,old.decision_text,COALESCE(old.rationale,''));
  INSERT INTO decision_fts(rowid,title,decision_text,rationale) VALUES (new.rowid,new.title,new.decision_text,COALESCE(new.rationale,''));
END;

---------------------------------------------------------------- ランクのヘルパ・ビュー
CREATE VIEW v_decider_rank AS                      -- 判断者の、その判断の scope での権限ランク。権限なし=0
SELECT d.decision_id,
  COALESCE((SELECT a.rank FROM v_authority a WHERE a.principal_id = d.decided_by AND a.scope = d.scope_project), 0) AS rank
FROM decision d;

CREATE VIEW v_approver_rank AS
SELECT ap.approval_id, ap.decision_id, ap.action, ap.approver_id,
  COALESCE((SELECT a.rank FROM v_authority a WHERE a.principal_id = ap.approver_id
            AND a.scope = (SELECT scope_project FROM decision WHERE decision_id = ap.decision_id)), 0) AS rank
FROM approval ap;

---------------------------------------------------------------- トリガ: decision
CREATE TRIGGER trg_dec_insert_status BEFORE INSERT ON decision
WHEN new.status NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'decision rows can only be inserted as candidate/quarantined; approval is a separate gated step'); END;

CREATE TRIGGER trg_dec_hash_i BEFORE INSERT ON decision
WHEN new.content_hash IS NOT canon_hash(new.decision_id, new.title, new.kind, new.origin, new.decision_text, new.rationale, new.tradeoff, new.card,
     new.class_code, new.decided_by, new.required_role, new.reversibility, new.confidence, new.confidence_basis, new.agent_mode, new.fallback,
     new.tier, new.scope_project, new.scope_path, new.valid_from, new.topic_key, new.choice, new.strength, new.created_by, new.criterion_hypothesis,
     new.supersedes_ids, new.overrides_ids)
BEGIN SELECT RAISE(ABORT,'content_hash does not match the row (canon_hash)'); END;
CREATE TRIGGER trg_dec_hash_u BEFORE UPDATE ON decision
WHEN new.content_hash IS NOT canon_hash(new.decision_id, new.title, new.kind, new.origin, new.decision_text, new.rationale, new.tradeoff, new.card,
     new.class_code, new.decided_by, new.required_role, new.reversibility, new.confidence, new.confidence_basis, new.agent_mode, new.fallback,
     new.tier, new.scope_project, new.scope_path, new.valid_from, new.topic_key, new.choice, new.strength, new.created_by, new.criterion_hypothesis,
     new.supersedes_ids, new.overrides_ids)
BEGIN SELECT RAISE(ABORT,'content_hash does not match the row (canon_hash)'); END;

CREATE TRIGGER trg_dec_class_floor_i BEFORE INSERT ON decision
WHEN (SELECT floor_agent_mode FROM decision_class WHERE class_code=new.class_code)='human_only' AND new.agent_mode<>'human_only'
BEGIN SELECT RAISE(ABORT,'class floor is human_only'); END;
CREATE TRIGGER trg_dec_class_floor_u BEFORE UPDATE OF agent_mode, class_code ON decision
WHEN (SELECT floor_agent_mode FROM decision_class WHERE class_code=new.class_code)='human_only' AND new.agent_mode<>'human_only'
BEGIN SELECT RAISE(ABORT,'class floor is human_only'); END;

CREATE TRIGGER trg_dec_immutable BEFORE UPDATE OF
  decision_id, title, kind, origin, extraction_run_id, created_by, decision_text, rationale, criterion_hypothesis, tradeoff, card, class_code,
  topic_key, choice, strength, supersedes_ids, overrides_ids, decided_by, required_role, reversibility, confidence, confidence_basis, agent_mode, fallback, tier,
  scope_project, scope_path, valid_from, recorded_at, source_path, content_hash ON decision
WHEN old.status IN ('approved','superseded','expired','revoked')
BEGIN SELECT RAISE(ABORT,'approved decision is immutable: write a superseding record'); END;

-- valid_until: 承認後は短縮のみ。短縮は署名付き shorten 承認か supersede でだけ起き、版履歴 (decision_history) に残る
CREATE TRIGGER trg_dec_valid_until_gate BEFORE UPDATE OF valid_until ON decision
WHEN old.status NOT IN ('candidate','quarantined') AND new.valid_until IS NOT old.valid_until
BEGIN
  SELECT RAISE(ABORT,'valid_until may only be shortened after approval')
   WHERE new.valid_until IS NULL OR (old.valid_until IS NOT NULL AND new.valid_until > old.valid_until);
  SELECT RAISE(ABORT,'valid_until change after approval needs a signed shorten approval (or a legit supersede)')
   WHERE NOT (old.status = 'approved' AND new.status = 'superseded')
     AND NOT EXISTS (SELECT 1 FROM approval a WHERE a.decision_id = new.decision_id AND a.action = 'shorten'
                     AND a.new_valid_until = new.valid_until
                     AND a.approval_id = (SELECT MAX(approval_id) FROM approval WHERE decision_id = new.decision_id));
END;

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

-- 承認後は、効果を持つ子表も凍結 (deny を後から足して作業を止める / 適用範囲を広げる、を防ぐ)。tag と assumption.status は索引・点検用なので可変。
CREATE TRIGGER trg_trigger_frozen_i BEFORE INSERT ON decision_trigger
WHEN (SELECT status FROM decision WHERE decision_id=new.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'triggers of an approved decision are frozen'); END;
CREATE TRIGGER trg_trigger_frozen_u BEFORE UPDATE ON decision_trigger
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'triggers of an approved decision are frozen'); END;
CREATE TRIGGER trg_trigger_frozen_d BEFORE DELETE ON decision_trigger
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined','rejected')
BEGIN SELECT RAISE(ABORT,'triggers of an approved decision are frozen'); END;
CREATE TRIGGER trg_dscope_frozen_i BEFORE INSERT ON decision_scope
WHEN (SELECT status FROM decision WHERE decision_id=new.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'scope of an approved decision is frozen'); END;
CREATE TRIGGER trg_dscope_frozen_u BEFORE UPDATE ON decision_scope
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'scope of an approved decision is frozen'); END;
CREATE TRIGGER trg_dscope_frozen_d BEFORE DELETE ON decision_scope
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined','rejected')
BEGIN SELECT RAISE(ABORT,'scope of an approved decision is frozen'); END;
CREATE TRIGGER trg_option_frozen_i BEFORE INSERT ON decision_option
WHEN (SELECT status FROM decision WHERE decision_id=new.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'options of an approved decision are frozen'); END;
CREATE TRIGGER trg_option_frozen_u BEFORE UPDATE ON decision_option
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'options of an approved decision are frozen'); END;
CREATE TRIGGER trg_option_frozen_d BEFORE DELETE ON decision_option
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined','rejected')
BEGIN SELECT RAISE(ABORT,'options of an approved decision are frozen'); END;

---------------------------------------------------------------- トリガ: evidence (B: 本文の範囲検証 / F: decider は full ソースのみ)
CREATE TRIGGER trg_ev_span_i BEFORE INSERT ON evidence
WHEN new.quote_verified = 1 AND verify_span(new.source_id, new.quote_start, new.quote_end, new.quote_sha256) <> 1
BEGIN SELECT RAISE(ABORT,'quote_verified=1 but the span of the source body does not hash to quote_sha256'); END;
CREATE TRIGGER trg_ev_span_u BEFORE UPDATE OF quote_start, quote_end, quote_sha256, quote_verified, source_id ON evidence
WHEN new.quote_verified = 1 AND verify_span(new.source_id, new.quote_start, new.quote_end, new.quote_sha256) <> 1
BEGIN SELECT RAISE(ABORT,'quote_verified=1 but the span of the source body does not hash to quote_sha256'); END;
CREATE TRIGGER trg_ev_decider_full BEFORE INSERT ON evidence
WHEN new.role = 'decider' AND (SELECT ingest_state FROM source WHERE source_id = new.source_id) <> 'full'
BEGIN SELECT RAISE(ABORT,'decider attribution needs a fully ingested (non-anonymized) source'); END;
CREATE TRIGGER trg_ev_frozen_u BEFORE UPDATE ON evidence
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined')
BEGIN SELECT RAISE(ABORT,'evidence of an approved decision is frozen'); END;
CREATE TRIGGER trg_ev_frozen_d BEFORE DELETE ON evidence
WHEN (SELECT status FROM decision WHERE decision_id=old.decision_id) NOT IN ('candidate','quarantined','rejected')
BEGIN SELECT RAISE(ABORT,'evidence of an approved decision is frozen'); END;

CREATE TRIGGER trg_exc_i BEFORE INSERT ON evidence_excerpt
BEGIN
  SELECT RAISE(ABORT,'excerpt of a restricted source is not stored (hash only)')
   WHERE (SELECT s.sensitivity FROM evidence e JOIN source s ON s.source_id = e.source_id WHERE e.evidence_id = new.evidence_id) = 'restricted';
  SELECT RAISE(ABORT,'excerpt does not match evidence.quote_sha256')
   WHERE sha256_text(new.excerpt) IS NOT (SELECT quote_sha256 FROM evidence WHERE evidence_id = new.evidence_id);
END;

---------------------------------------------------------------- トリガ: approval (E2)
CREATE TRIGGER trg_ap_human BEFORE INSERT ON approval
WHEN (SELECT kind FROM principal WHERE principal_id=new.approver_id) IS NOT 'human'
BEGIN SELECT RAISE(ABORT,'approver must be a human principal'); END;

CREATE TRIGGER trg_ap_sig BEFORE INSERT ON approval
WHEN verify_sig(new.approver_id,
      'decision-approval/v2|' || new.decision_id || '|' || new.action || '|' || new.content_hash || '|' ||
      COALESCE(new.new_valid_until,'') || '|' || new.approver_id || '|' || new.approved_at, new.sig) IS NOT 1
BEGIN SELECT RAISE(ABORT,'approval signature invalid'); END;

CREATE TRIGGER trg_ap_hash BEFORE INSERT ON approval
WHEN new.content_hash IS NOT (SELECT content_hash FROM decision WHERE decision_id=new.decision_id)
BEGIN SELECT RAISE(ABORT,'approval content_hash does not match the decision'); END;

CREATE TRIGGER trg_ap_state BEFORE INSERT ON approval
WHEN (new.action='approve' AND (SELECT status FROM decision WHERE decision_id=new.decision_id) IS NOT 'candidate')
  OR (new.action IN ('revoke','shorten') AND (SELECT status FROM decision WHERE decision_id=new.decision_id) IS NOT 'approved')
BEGIN SELECT RAISE(ABORT,'approval: decision is not in the state this action applies to'); END;

CREATE TRIGGER trg_ap_shorten_range BEFORE INSERT ON approval
WHEN new.action='shorten'
 AND NOT (new.new_valid_until >= (SELECT valid_from FROM decision WHERE decision_id=new.decision_id)
          AND (SELECT valid_until FROM decision WHERE decision_id=new.decision_id) IS NULL
          OR new.new_valid_until < (SELECT valid_until FROM decision WHERE decision_id=new.decision_id)
             AND new.new_valid_until >= (SELECT valid_from FROM decision WHERE decision_id=new.decision_id))
BEGIN SELECT RAISE(ABORT,'shorten: new_valid_until must be >= valid_from and earlier than the current valid_until'); END;

CREATE TRIGGER trg_ap_rank BEFORE INSERT ON approval
WHEN COALESCE((SELECT a.rank FROM v_authority a WHERE a.principal_id=new.approver_id
               AND a.scope=(SELECT scope_project FROM decision WHERE decision_id=new.decision_id)),0)
     < MAX(1, COALESCE((SELECT r.rank FROM role r WHERE r.role_id=(SELECT required_role FROM decision WHERE decision_id=new.decision_id)),0))
BEGIN SELECT RAISE(ABORT,'approver lacks authority in this scope / for required_role'); END;

CREATE TRIGGER trg_ap_rank_down BEFORE INSERT ON approval
WHEN new.action IN ('revoke','shorten')
 AND COALESCE((SELECT a.rank FROM v_authority a WHERE a.principal_id=new.approver_id
               AND a.scope=(SELECT scope_project FROM decision WHERE decision_id=new.decision_id)),0)
     < COALESCE((SELECT MAX(rank) FROM v_approver_rank WHERE decision_id=new.decision_id AND action='approve'),0)
BEGIN SELECT RAISE(ABORT,'revoke/shorten needs authority >= the original approver (others raise a review_queue item)'); END;

CREATE TRIGGER trg_ap_creator BEFORE INSERT ON approval
WHEN new.action='approve'
 AND (SELECT origin FROM decision WHERE decision_id=new.decision_id) <> 'human_stated'
 AND new.approver_id = (SELECT created_by FROM decision WHERE decision_id=new.decision_id)
BEGIN SELECT RAISE(ABORT,'creator cannot approve their own non-human_stated decision'); END;

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
  UPDATE decision SET valid_until=new.new_valid_until WHERE decision_id=new.decision_id AND new.action='shorten';
END;
CREATE TRIGGER trg_ap_frozen_u BEFORE UPDATE ON approval BEGIN SELECT RAISE(ABORT,'approval rows are append-only'); END;
CREATE TRIGGER trg_ap_frozen_d BEFORE DELETE ON approval BEGIN SELECT RAISE(ABORT,'approval rows are append-only'); END;

---------------------------------------------------------------- トリガ: link (E3)
CREATE TRIGGER trg_link_gate BEFORE INSERT ON decision_link
WHEN new.link_type IN ('supersedes','overrides')
BEGIN
  SELECT RAISE(ABORT,'supersedes/overrides must be declared in the approved new decision (supersedes_ids/overrides_ids)')
   WHERE (new.link_type='supersedes' AND instr(',' || COALESCE((SELECT supersedes_ids FROM decision WHERE decision_id=new.from_id),'') || ',', ',' || new.to_id || ',') = 0)
      OR (new.link_type='overrides'  AND instr(',' || COALESCE((SELECT overrides_ids  FROM decision WHERE decision_id=new.from_id),'') || ',', ',' || new.to_id || ',') = 0);
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
  SELECT RAISE(ABORT,'supersedes/overrides: a human-needed decision (ask_async/human_only) cannot be replaced by an agent-ok one')   -- C R-C4
   WHERE (SELECT agent_mode FROM decision WHERE decision_id=new.to_id) IN ('ask_async','human_only')
     AND (SELECT agent_mode FROM decision WHERE decision_id=new.from_id) IN ('follow','follow_and_log');
END;

CREATE TRIGGER trg_link_supersede_apply AFTER INSERT ON decision_link
WHEN new.link_type='supersedes'
BEGIN
  UPDATE decision SET status='superseded',
    valid_until = MAX(valid_from, MIN(COALESCE(valid_until,'9999-12-31'),
                   date((SELECT valid_from FROM decision WHERE decision_id=new.from_id),'-1 day')))
  WHERE decision_id=new.to_id;
END;

---------------------------------------------------------------- ビュー: 有効性
CREATE VIEW v_effective AS                          -- 注入・適用してよい判断
SELECT d.*, (d.review_by IS NOT NULL AND d.review_by < date('now')) AS review_overdue
FROM decision d
WHERE d.status='approved' AND d.valid_from <= date('now')
  AND (d.valid_until IS NULL OR d.valid_until >= date('now'))
  AND (d.origin <> 'extracted' OR EXISTS (          -- F: 根拠が全て失効 (同意撤回・ソース失効) した抽出判断は status を待たず除外
        SELECT 1 FROM evidence e JOIN source s ON s.source_id = e.source_id LEFT JOIN consent c ON c.consent_id = s.consent_id
        WHERE e.decision_id = d.decision_id AND e.quote_verified = 1 AND s.revoked_at IS NULL AND s.ingest_state = 'full'
          AND (s.consent_id IS NULL OR c.withdrawn_at IS NULL)));

---------------------------------------------------------------- E9: 唯一の優先規則 (A/C/F を統合)
--   P0  適用範囲: 2件の scope が祖先-子孫 (同一を含む) のときだけ競合。兄弟 scope は競合しない
--   P-1 承認済みの overrides リンク (人間が明示的に決めた優先) があればそれ
--   P1  strength: mandatory が default に勝つ (C の overridable=0, F の P1)
--   P2  scope の深さ: default 同士は深い (具体的な) 方、mandatory 同士は浅い (広い) 方
--   P3  同一 scope: その scope での権限ランクが高い方 (継承あり)。どちらかが権限なし(0)なら決めない
--   P4  同位 (ランク同値>0) かつ同一判断者: valid_from が新しい方。別人は決めない
--   P5  決まらない: winner NULL。conflict_ticket を開き、両方を conflict として返し、動作は proceed_with_assumption 止まり
--   confidence は順序に使わない (自己申告で、エージェントが付けうるため。C の主張を採用)
CREATE VIEW v_conflict_resolution AS
WITH p AS (
  SELECT x.decision_id AS a_id, y.decision_id AS b_id
  FROM v_effective x JOIN v_effective y ON x.decision_id < y.decision_id
  WHERE EXISTS (SELECT 1 FROM v_scope_closure c
                WHERE (c.scope = x.scope_project AND c.ancestor = y.scope_project)
                   OR (c.scope = y.scope_project AND c.ancestor = x.scope_project))
    AND ( (x.topic_key IS NOT NULL AND x.topic_key = y.topic_key AND x.choice IS NOT NULL AND y.choice IS NOT NULL AND x.choice <> y.choice)
       OR EXISTS (SELECT 1 FROM decision_link l WHERE l.link_type = 'conflicts_with'
                  AND ((l.from_id = x.decision_id AND l.to_id = y.decision_id) OR (l.from_id = y.decision_id AND l.to_id = x.decision_id))))
), m AS (
  SELECT p.a_id, p.b_id,
    a.scope_project AS a_scope, b.scope_project AS b_scope,
    a.strength AS sta, b.strength AS stb,
    (SELECT depth FROM v_scope_depth WHERE scope = a.scope_project) AS da,
    (SELECT depth FROM v_scope_depth WHERE scope = b.scope_project) AS db,
    (SELECT rank FROM v_decider_rank WHERE decision_id = p.a_id) AS ra,
    (SELECT rank FROM v_decider_rank WHERE decision_id = p.b_id) AS rb,
    a.decided_by AS pa, b.decided_by AS pb, a.valid_from AS va, b.valid_from AS vb,
    EXISTS (SELECT 1 FROM decision_link o WHERE o.link_type='overrides' AND o.from_id=p.a_id AND o.to_id=p.b_id) AS a_over,
    EXISTS (SELECT 1 FROM decision_link o WHERE o.link_type='overrides' AND o.from_id=p.b_id AND o.to_id=p.a_id) AS b_over
  FROM p JOIN decision a ON a.decision_id = p.a_id JOIN decision b ON b.decision_id = p.b_id
)
SELECT a_id, b_id, a_scope, b_scope,
  CASE WHEN a_over THEN a_id WHEN b_over THEN b_id
       WHEN sta <> stb THEN CASE WHEN sta = 'mandatory' THEN a_id ELSE b_id END
       WHEN da <> db THEN CASE WHEN sta = 'mandatory' THEN (CASE WHEN da < db THEN a_id ELSE b_id END)
                                                      ELSE (CASE WHEN da > db THEN a_id ELSE b_id END) END
       WHEN ra > 0 AND rb > 0 AND ra <> rb THEN CASE WHEN ra > rb THEN a_id ELSE b_id END
       WHEN ra > 0 AND rb > 0 AND pa IS pb AND va <> vb THEN CASE WHEN va > vb THEN a_id ELSE b_id END
  END AS winner,
  CASE WHEN a_over OR b_over THEN '0_overrides' WHEN sta <> stb THEN '1_mandatory' WHEN da <> db THEN '2_specificity'
       WHEN ra > 0 AND rb > 0 AND ra <> rb THEN '3_authority'
       WHEN ra > 0 AND rb > 0 AND pa IS pb AND va <> vb THEN '4_recency_same_decider'
       ELSE '5_tie_open_ticket' END AS rule,
  CASE WHEN a_over OR b_over OR sta <> stb OR da <> db OR (ra > 0 AND rb > 0 AND (ra <> rb OR (pa IS pb AND va <> vb))) THEN NULL
       WHEN ra = 0 OR rb = 0 THEN 'no_authority_grant' WHEN pa IS pb THEN 'same_decider_same_date' ELSE 'same_rank_different_person' END AS tie_reason
FROM m;

-- scope 別の有効集合: view_scope から見て適用される判断 (scope が view_scope の祖先または自分)。
-- 負けた側は、勝者が同じ view_scope に適用されるときだけ除外 (global が project に負けても、別の project では global が残る)。
CREATE VIEW v_effective_by_scope AS
SELECT s.scope AS view_scope, e.*,
  EXISTS (SELECT 1 FROM v_conflict_resolution r
          WHERE r.winner IS NULL AND e.decision_id IN (r.a_id, r.b_id)
            AND EXISTS (SELECT 1 FROM v_scope_closure c1 WHERE c1.scope = s.scope AND c1.ancestor = r.a_scope)
            AND EXISTS (SELECT 1 FROM v_scope_closure c2 WHERE c2.scope = s.scope AND c2.ancestor = r.b_scope)) AS conflict_open
FROM scope_node s
JOIN v_scope_closure c ON c.scope = s.scope
JOIN v_effective e ON e.scope_project = c.ancestor
WHERE NOT EXISTS (
  SELECT 1 FROM v_conflict_resolution r
  WHERE r.winner IS NOT NULL
    AND e.decision_id = (CASE WHEN r.winner = r.a_id THEN r.b_id ELSE r.a_id END)
    AND EXISTS (SELECT 1 FROM v_scope_closure c3 WHERE c3.scope = s.scope
                AND c3.ancestor = (CASE WHEN r.winner = r.a_id THEN r.a_scope ELSE r.b_scope END)));

-- E7/E1: 単一の動作規則。エージェントはこのビューを引く (view_scope = 作業中の project)。
CREATE VIEW v_agent_action AS
SELECT e.view_scope, e.decision_id, e.agent_mode, e.reversibility, e.confidence, c.min_confidence, e.conflict_open,
  CASE
    WHEN e.agent_mode = 'human_only' THEN 'escalate'
    WHEN e.reversibility IN ('one_way','unknown') THEN 'park_task'
    WHEN e.conflict_open THEN 'proceed_with_assumption'
    WHEN e.confidence < c.min_confidence THEN 'proceed_with_assumption'
    WHEN e.agent_mode = 'ask_async' THEN 'proceed_with_assumption'
    ELSE 'proceed' END AS action
FROM v_effective_by_scope e JOIN decision_class c ON c.class_code = e.class_code;

CREATE VIEW v_trigger_effective AS                  -- D: フックが読む。有効な判断のトリガだけ
SELECT t.decision_id, t.kind, t.pattern, t.action, e.tier, e.scope_project, e.scope_path
FROM decision_trigger t JOIN v_effective e ON e.decision_id = t.decision_id;

---------------------------------------------------------------- トリガ: 矛盾チケット・ai_decision・review_queue
CREATE TRIGGER trg_ticket_open_check BEFORE INSERT ON conflict_ticket
WHEN new.state = 'open'
BEGIN SELECT RAISE(ABORT,'ticket must refer to a currently unresolved conflicting pair')
  WHERE NOT EXISTS (SELECT 1 FROM v_conflict_resolution r WHERE r.a_id = new.a_id AND r.b_id = new.b_id AND r.winner IS NULL); END;

CREATE TRIGGER trg_ticket_resolve BEFORE UPDATE OF state ON conflict_ticket
WHEN new.state = 'resolved'
 AND EXISTS (SELECT 1 FROM v_conflict_resolution r WHERE r.a_id = new.a_id AND r.b_id = new.b_id AND r.winner IS NULL)
BEGIN SELECT RAISE(ABORT,'ticket can only be resolved when one side is no longer effective or a winner exists'); END;

CREATE TRIGGER trg_ticket_auto_open AFTER UPDATE OF status ON decision
WHEN new.status = 'approved' AND old.status <> 'approved'
BEGIN
  INSERT INTO conflict_ticket(a_id, b_id, opened_at, reason)
  SELECT r.a_id, r.b_id, datetime('now'), r.rule || ':' || COALESCE(r.tie_reason,'')
  FROM v_conflict_resolution r
  WHERE r.winner IS NULL AND new.decision_id IN (r.a_id, r.b_id)
    AND NOT EXISTS (SELECT 1 FROM conflict_ticket t WHERE t.a_id = r.a_id AND t.b_id = r.b_id AND t.state = 'open');
END;
CREATE TRIGGER trg_ticket_auto_open_link AFTER INSERT ON decision_link
WHEN new.link_type = 'conflicts_with'
BEGIN
  INSERT INTO conflict_ticket(a_id, b_id, opened_at, reason)
  SELECT r.a_id, r.b_id, datetime('now'), r.rule || ':' || COALESCE(r.tie_reason,'')
  FROM v_conflict_resolution r
  WHERE r.winner IS NULL AND r.a_id IN (new.from_id, new.to_id) AND r.b_id IN (new.from_id, new.to_id)
    AND NOT EXISTS (SELECT 1 FROM conflict_ticket t WHERE t.a_id = r.a_id AND t.b_id = r.b_id AND t.state = 'open');
END;
CREATE TRIGGER trg_ticket_auto_close AFTER UPDATE OF status ON decision
WHEN new.status IN ('superseded','revoked','expired','quarantined')
BEGIN
  UPDATE conflict_ticket SET state = 'resolved' WHERE state = 'open' AND new.decision_id IN (a_id, b_id);
END;
CREATE TRIGGER trg_ticket_auto_close_over AFTER INSERT ON decision_link
WHEN new.link_type = 'overrides'
BEGIN
  UPDATE conflict_ticket SET state = 'resolved' WHERE state = 'open'
    AND a_id IN (new.from_id, new.to_id) AND b_id IN (new.from_id, new.to_id);
END;

CREATE TRIGGER trg_aid_rules BEFORE INSERT ON ai_decision       -- F R-F8: 申告 action は動作表より保守的でなければならない
BEGIN
  SELECT RAISE(ABORT,'ai_decision: human_only class must escalate')
   WHERE (SELECT floor_agent_mode FROM decision_class WHERE class_code = new.class_code) = 'human_only' AND new.action <> 'escalate';
  SELECT RAISE(ABORT,'ai_decision: one_way/unknown reversibility must park_task or escalate')
   WHERE new.reversibility IN ('one_way','unknown') AND new.action NOT IN ('park_task','escalate');
  SELECT RAISE(ABORT,'ai_decision: confidence below class minimum cannot proceed')
   WHERE new.action = 'proceed' AND new.confidence < (SELECT min_confidence FROM decision_class WHERE class_code = new.class_code);
  SELECT RAISE(ABORT,'ai_decision: open conflict on this topic forbids proceed')
   WHERE new.action = 'proceed' AND new.topic_key IS NOT NULL AND EXISTS (
     SELECT 1 FROM v_conflict_resolution r JOIN decision d ON d.decision_id IN (r.a_id, r.b_id)
     WHERE r.winner IS NULL AND d.topic_key = new.topic_key
       AND EXISTS (SELECT 1 FROM v_scope_closure c1 WHERE c1.scope = new.scope_project AND c1.ancestor = r.a_scope)
       AND EXISTS (SELECT 1 FROM v_scope_closure c2 WHERE c2.scope = new.scope_project AND c2.ancestor = r.b_scope));
END;

CREATE TRIGGER trg_queue_answer BEFORE UPDATE OF state ON review_queue
WHEN new.state = 'answered'
BEGIN
  SELECT RAISE(ABORT,'queue answers must come from a human principal')
   WHERE (SELECT kind FROM principal WHERE principal_id = new.answered_by) IS NOT 'human';
  SELECT RAISE(ABORT,'queue answer signature invalid')
   WHERE verify_sig(new.answered_by, 'queue-answer/v2|' || new.queue_id || '|' || new.answer || '|' || new.answered_by || '|' || new.answered_at, new.answer_sig) IS NOT 1;
END;

---------------------------------------------------------------- ビュー: 運用
CREATE VIEW v_queue_due AS
SELECT q.queue_id, q.question, q.on_expire, q.assignee_role,
  COALESCE(r.escalates_to, q.assignee_role) AS responsible_role,
  CASE q.on_expire WHEN 'confirm_default' THEN 'mark default as final, state=expired'
                   WHEN 'continue_and_renotify' THEN 'keep default, renotify responsible_role'
                   ELSE 'stay parked, renotify responsible_role' END AS next_step
FROM review_queue q JOIN role r ON r.role_id = q.assignee_role
WHERE q.state = 'open' AND q.expires_at < datetime('now');

CREATE VIEW v_blast_radius AS                       -- F: ソース失効/同意撤回の影響範囲
SELECT s.source_id, d.decision_id, d.status, u.ai_decision_id
FROM source s
JOIN evidence e ON e.source_id = s.source_id
JOIN decision d ON d.decision_id = e.decision_id
LEFT JOIN consent c ON c.consent_id = s.consent_id
LEFT JOIN decision_use u ON u.decision_id = d.decision_id
WHERE s.revoked_at IS NOT NULL OR c.withdrawn_at IS NOT NULL;

CREATE VIEW v_agreement AS                          -- F
SELECT r.run_id, u.environment, c.class_code, r.arm, COUNT(*) AS n,
       AVG(r.ai_choice = c.human_choice) AS agree,
       AVG(c.retest_choice = c.human_choice) AS retest_ceiling
FROM eval_case c JOIN eval_result r ON r.case_id = c.case_id JOIN eval_run u ON u.run_id = r.run_id
WHERE c.split = 'test'
GROUP BY r.run_id, u.environment, c.class_code, r.arm;
