-- 担当F round-1 再調査版 (E2/E7/E9/E10 対応)。SQLite 3.39.4 で実行確認。全データは合成。
-- 実行は f_run.py 経由 (verify_sig / entry_hash は Python 側で登録する SQL 関数。未登録の接続では
-- 該当トリガが "no such function" で失敗する = fail closed)。
-- 注意: DB ファイルに書込み権限を持つ主体は DROP TRIGGER や偽関数登録ができる。したがって DB 内の
-- トリガは「善意の誤用と gateway 経由の書込み」を止める第1層に過ぎず、承認の真正性の最終判定は
-- 読み出し側の署名再検証 (f_approval.verified_effective) で行う(第2層)。
PRAGMA foreign_keys = ON;

-- ---------- 時計 (テスト可能にするため上書き可) ----------
CREATE TABLE sys_clock (id INTEGER PRIMARY KEY CHECK (id = 1), now_override TEXT);
INSERT INTO sys_clock VALUES (1, NULL);
CREATE VIEW v_now AS
SELECT COALESCE((SELECT now_override FROM sys_clock WHERE id = 1),
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) AS now;

-- ---------- 人・スコープ・権限 ----------
CREATE TABLE person_alias (alias TEXT PRIMARY KEY, role TEXT NOT NULL);   -- 実名対応表は別DB・別権限

CREATE TABLE approver (                         -- 承認できる人。公開鍵は DB の外 (allowed_signers / Git) に置く
  alias  TEXT PRIMARY KEY REFERENCES person_alias(alias),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1))
);

CREATE TABLE scope_node (                       -- scope は木。global > 部署 > プロジェクト > モジュール
  scope  TEXT PRIMARY KEY,
  parent TEXT REFERENCES scope_node(scope),
  CHECK (parent IS NULL OR parent <> scope)
);

CREATE TABLE scope_authority (                  -- 権限は大域ランクではなく scope ごとの付与。子孫 scope に継承
  alias TEXT NOT NULL REFERENCES person_alias(alias),
  scope TEXT NOT NULL REFERENCES scope_node(scope),
  level INTEGER NOT NULL CHECK (level BETWEEN 1 AND 3),   -- 1=助言者(先輩) 2=責任者(owner) 3=上位責任者
  PRIMARY KEY (alias, scope)
);

CREATE VIEW v_scope_closure AS                  -- sub の祖先 sup と距離 dist (0=自身)
WITH RECURSIVE t(sub, sup, dist) AS (
  SELECT scope, scope, 0 FROM scope_node
  UNION ALL
  SELECT t.sub, n.parent, t.dist + 1 FROM t JOIN scope_node n ON n.scope = t.sup WHERE n.parent IS NOT NULL)
SELECT sub, sup, dist FROM t;

CREATE VIEW v_scope_depth AS SELECT sub AS scope, MAX(dist) AS depth FROM v_scope_closure GROUP BY sub;

CREATE VIEW v_authority AS                      -- alias が scope で持つ有効な権限 (祖先からの継承を含む)
SELECT sa.alias, c.sub AS scope, MAX(sa.level) AS level
FROM scope_authority sa JOIN v_scope_closure c ON c.sup = sa.scope
GROUP BY sa.alias, c.sub;

CREATE VIEW v_responsible AS                    -- 質問の責任者候補。dist が小さい(近い)順が 担当者→エスカレーション先
SELECT c.sub AS scope, sa.alias, c.dist, sa.level
FROM scope_authority sa JOIN v_scope_closure c ON c.sup = sa.scope
WHERE sa.level >= 2;

-- ---------- E10: サービス規約 / 同意 / ソース ----------
CREATE TABLE service_terms (                    -- 規約の AI 処理可否。確認していないものは 'unverified'
  service       TEXT PRIMARY KEY,
  ai_processing TEXT NOT NULL CHECK (ai_processing IN ('allowed','restricted','prohibited','unverified')),
  checked_at    TEXT,
  evidence_url  TEXT,
  note          TEXT,
  CHECK (ai_processing = 'unverified' OR (checked_at IS NOT NULL AND evidence_url IS NOT NULL))
);

CREATE TABLE consent (
  id INTEGER PRIMARY KEY,
  subject_alias TEXT NOT NULL REFERENCES person_alias(alias),
  purposes TEXT NOT NULL,
  scope TEXT NOT NULL,
  external_llm_allowed INTEGER NOT NULL DEFAULT 0 CHECK (external_llm_allowed IN (0,1)),
  granted_at TEXT NOT NULL,
  withdrawn_at TEXT
);

CREATE TABLE source (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('adr','pr_review','chat','meeting','interview','agent_trace','queue_answer')),
  service TEXT REFERENCES service_terms(service),
  -- trust_tier は承認者に見せる表示と隔離の補助。権限の根拠ではない(権限は署名)。
  trust_tier TEXT NOT NULL CHECK (trust_tier IN ('human_authored_verified','human_authored_unverified','third_party','agent_asserted')),
  consent_id INTEGER REFERENCES consent(id),
  -- 同意が取れない/撤回/規約未確認のソースの扱い。既定は excluded(取り込まない)。
  handling TEXT NOT NULL DEFAULT 'excluded' CHECK (handling IN ('excluded','anonymized_only','full')),
  processor TEXT NOT NULL DEFAULT 'local' CHECK (processor IN ('local','external_llm')),
  redaction_done INTEGER NOT NULL DEFAULT 0 CHECK (redaction_done IN (0,1)),
  anonymization_reviewed_by TEXT REFERENCES person_alias(alias),   -- 再識別リスクの人手確認
  ingested_at TEXT NOT NULL,
  revoked_at TEXT,
  CHECK (kind <> 'agent_trace' OR trust_tier = 'agent_asserted')
);

-- handling を excluded 以外にする条件 (INSERT と UPDATE の両方に同じ検査)
CREATE TRIGGER trg_source_handling_ins BEFORE INSERT ON source
WHEN NEW.handling <> 'excluded' BEGIN
  SELECT RAISE(ABORT, 'service terms not verified as allowed for AI processing')
    WHERE NEW.service IS NULL OR (SELECT ai_processing FROM service_terms WHERE service = NEW.service) IS NOT 'allowed';
  SELECT RAISE(ABORT, 'redaction required before ingest') WHERE NEW.redaction_done = 0;
  SELECT RAISE(ABORT, 'full handling needs active consent (and external-LLM consent if processor=external_llm)')
    WHERE NEW.handling = 'full' AND NOT EXISTS (
      SELECT 1 FROM consent c WHERE c.id = NEW.consent_id AND c.withdrawn_at IS NULL
        AND (NEW.processor = 'local' OR c.external_llm_allowed = 1));
  SELECT RAISE(ABORT, 'anonymized_only needs a human re-identification review')
    WHERE NEW.handling = 'anonymized_only' AND NEW.anonymization_reviewed_by IS NULL;
END;
CREATE TRIGGER trg_source_handling_upd BEFORE UPDATE OF handling, consent_id, processor, redaction_done, service ON source
WHEN NEW.handling <> 'excluded' BEGIN
  SELECT RAISE(ABORT, 'service terms not verified as allowed for AI processing')
    WHERE NEW.service IS NULL OR (SELECT ai_processing FROM service_terms WHERE service = NEW.service) IS NOT 'allowed';
  SELECT RAISE(ABORT, 'redaction required before ingest') WHERE NEW.redaction_done = 0;
  SELECT RAISE(ABORT, 'full handling needs active consent (and external-LLM consent if processor=external_llm)')
    WHERE NEW.handling = 'full' AND NOT EXISTS (
      SELECT 1 FROM consent c WHERE c.id = NEW.consent_id AND c.withdrawn_at IS NULL
        AND (NEW.processor = 'local' OR c.external_llm_allowed = 1));
  SELECT RAISE(ABORT, 'anonymized_only needs a human re-identification review')
    WHERE NEW.handling = 'anonymized_only' AND NEW.anonymization_reviewed_by IS NULL;
END;

-- ---------- 判断の種類別ポリシー ----------
CREATE TABLE decision_class (
  code TEXT PRIMARY KEY,
  reversibility TEXT NOT NULL CHECK (reversibility IN ('R0_cheap','R1_costly','R2_irreversible')),
  authority TEXT NOT NULL CHECK (authority IN ('A0_task','A1_owner','A2_human_only')),
  min_confidence REAL NOT NULL DEFAULT 1 CHECK (min_confidence BETWEEN 0 AND 1),  -- 既定1.0 = 自律化なし。較正で下げる
  max_wrong_rate REAL NOT NULL CHECK (max_wrong_rate BETWEEN 0 AND 1),
  default_ttl_days INTEGER,
  queue_ttl_hours INTEGER NOT NULL DEFAULT 24,
  renotify_hours INTEGER NOT NULL DEFAULT 24,
  CHECK (authority <> 'A2_human_only' OR min_confidence = 1)
);

-- ---------- 判断記録 (memory_entry = 統合スキーマの decision に対応) ----------
CREATE TABLE memory_entry (
  id INTEGER PRIMARY KEY,
  class_code TEXT NOT NULL REFERENCES decision_class(code),
  decider_alias TEXT REFERENCES person_alias(alias),
  topic_key TEXT NOT NULL,                      -- 矛盾検出のため結論を構造化 (同じ topic で choice が違えば矛盾)
  choice TEXT NOT NULL,
  statement TEXT NOT NULL,
  scope TEXT NOT NULL REFERENCES scope_node(scope),
  strength TEXT NOT NULL DEFAULT 'default' CHECK (strength IN ('default','mandatory')),  -- mandatory=下位scopeは覆せない制約
  status TEXT NOT NULL DEFAULT 'candidate'
    CHECK (status IN ('candidate','approved','superseded','expired','revoked','quarantined')),
  valid_from TEXT NOT NULL, valid_until TEXT, review_after TEXT,
  supersedes_id INTEGER REFERENCES memory_entry(id),
  extraction_run TEXT NOT NULL,
  created_by TEXT NOT NULL,                     -- 'agent:xxx' など。権威を持たない自己申告
  epoch INTEGER NOT NULL DEFAULT 0,             -- approved から外れるたびに +1。古い承認の再利用(リプレイ)を防ぐ
  CHECK (supersedes_id IS NULL OR supersedes_id <> id),
  CHECK (valid_until IS NULL OR valid_until >= valid_from)
);

CREATE TABLE entry_transition (from_status TEXT NOT NULL, to_status TEXT NOT NULL, PRIMARY KEY (from_status, to_status));
INSERT INTO entry_transition VALUES
 ('candidate','approved'),('candidate','quarantined'),('candidate','revoked'),
 ('approved','superseded'),('approved','expired'),('approved','revoked'),('approved','quarantined'),
 ('quarantined','candidate'),('quarantined','revoked'),('expired','candidate');

CREATE TABLE evidence (
  entry_id INTEGER NOT NULL REFERENCES memory_entry(id) ON DELETE CASCADE,
  source_id INTEGER NOT NULL REFERENCES source(id),
  quote TEXT NOT NULL,                          -- 保管ルール: source.handling が excluded の引用は保存しない。保持期間はソースと同じ
  PRIMARY KEY (entry_id, source_id)
);

-- E2: 承認 = 人間の署名 (ssh-keygen -Y sign, Git の SSH 署名と同じ方式)。DB の外の鍵が真正性の根拠。
CREATE TABLE approval (
  id INTEGER PRIMARY KEY,
  entry_id INTEGER NOT NULL REFERENCES memory_entry(id),
  entry_hash TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  approver_alias TEXT NOT NULL REFERENCES approver(alias),
  approved_at TEXT NOT NULL,
  sig TEXT NOT NULL,
  evidence_ref TEXT                             -- 例: PR URL / マージコミット
);

-- 新規行は必ず candidate (INSERT ... status='approved' を拒否)
CREATE TRIGGER trg_entry_insert_candidate BEFORE INSERT ON memory_entry
WHEN NEW.status <> 'candidate' BEGIN SELECT RAISE(ABORT, 'entries must be inserted as candidate'); END;

-- 承認行の挿入: 署名・内容ハッシュ・epoch・承認者の権限・作成者との分離を検査
CREATE TRIGGER trg_approval_verify BEFORE INSERT ON approval BEGIN
  SELECT RAISE(ABORT, 'approval: entry hash/epoch mismatch')
    WHERE NOT EXISTS (SELECT 1 FROM memory_entry m WHERE m.id = NEW.entry_id AND m.epoch = NEW.epoch
      AND NEW.entry_hash = entry_hash(m.class_code, m.topic_key, m.choice, m.statement, m.scope,
                                      m.decider_alias, m.strength, m.valid_from, m.valid_until));
  SELECT RAISE(ABORT, 'approval: approver is inactive or has no authority on this scope')
    WHERE NOT EXISTS (SELECT 1 FROM approver a JOIN memory_entry m ON m.id = NEW.entry_id
      JOIN v_authority v ON v.alias = a.alias AND v.scope = m.scope WHERE a.alias = NEW.approver_alias AND a.active = 1);
  SELECT RAISE(ABORT, 'approval: creator cannot approve own entry')
    WHERE (SELECT created_by FROM memory_entry WHERE id = NEW.entry_id) = NEW.approver_alias;
  SELECT RAISE(ABORT, 'approval: bad signature')
    WHERE verify_sig(NEW.approver_alias,
      'entry|' || NEW.entry_id || '|' || NEW.entry_hash || '|' || NEW.epoch || '|' || NEW.approver_alias || '|' || NEW.approved_at,
      NEW.sig) <> 1;
END;

-- 状態遷移: 許可された遷移のみ
CREATE TRIGGER trg_entry_transition BEFORE UPDATE OF status ON memory_entry
WHEN OLD.status <> NEW.status AND NOT EXISTS
  (SELECT 1 FROM entry_transition WHERE from_status = OLD.status AND to_status = NEW.status)
BEGIN SELECT RAISE(ABORT, 'illegal status transition'); END;

-- approved への遷移: 現在の内容・epoch に対する署名済み承認が必要 + 非agent・非失効の証拠
CREATE TRIGGER trg_entry_approve BEFORE UPDATE OF status ON memory_entry
WHEN NEW.status = 'approved' AND OLD.status <> 'approved' BEGIN
  SELECT RAISE(ABORT, 'approve: no signed approval for current content/epoch')
    WHERE NOT EXISTS (SELECT 1 FROM approval a WHERE a.entry_id = NEW.id AND a.epoch = NEW.epoch
      AND a.entry_hash = entry_hash(NEW.class_code, NEW.topic_key, NEW.choice, NEW.statement, NEW.scope,
                                    NEW.decider_alias, NEW.strength, NEW.valid_from, NEW.valid_until));
  SELECT RAISE(ABORT, 'approve: needs non-agent, non-revoked evidence')
    WHERE NOT EXISTS (SELECT 1 FROM evidence e JOIN source s ON s.id = e.source_id
      WHERE e.entry_id = NEW.id AND s.trust_tier <> 'agent_asserted' AND s.revoked_at IS NULL AND s.handling <> 'excluded');
END;

-- 承認済みの内容は不変 (変えるなら新エントリで supersede)
CREATE TRIGGER trg_entry_immutable BEFORE UPDATE OF class_code, topic_key, choice, statement, scope,
  decider_alias, strength, valid_from, valid_until ON memory_entry
WHEN OLD.status = 'approved' BEGIN SELECT RAISE(ABORT, 'approved entry is immutable'); END;

-- approved から外れたら epoch を上げる (古い署名の再利用を無効化)
CREATE TRIGGER trg_entry_epoch AFTER UPDATE OF status ON memory_entry
WHEN OLD.status = 'approved' AND NEW.status <> 'approved'
BEGIN UPDATE memory_entry SET epoch = epoch + 1 WHERE id = NEW.id; END;
CREATE TRIGGER trg_entry_epoch2 AFTER UPDATE OF status ON memory_entry
WHEN OLD.status <> 'approved' AND NEW.status IN ('quarantined','revoked')
BEGIN UPDATE memory_entry SET epoch = epoch + 1 WHERE id = NEW.id; END;

-- E3 (F 側の最小限): supersede は「新エントリが approved になった時」にだけ旧エントリへ適用
CREATE TRIGGER trg_apply_supersede AFTER UPDATE OF status ON memory_entry
WHEN NEW.status = 'approved' AND OLD.status <> 'approved' AND NEW.supersedes_id IS NOT NULL
BEGIN UPDATE memory_entry SET status = 'superseded' WHERE id = NEW.supersedes_id AND status = 'approved'; END;
-- 旧エントリが superseded になる遷移は「置換側が approved」のときだけ
CREATE TRIGGER trg_supersede_guard BEFORE UPDATE OF status ON memory_entry
WHEN NEW.status = 'superseded' AND NOT EXISTS
  (SELECT 1 FROM memory_entry n WHERE n.supersedes_id = OLD.id AND n.status = 'approved')
BEGIN SELECT RAISE(ABORT, 'supersede only by an approved entry'); END;

-- 証拠は取り込み可のソースだけ。anonymized_only ソースは判断者を紐づけない
CREATE TRIGGER trg_evidence_guard BEFORE INSERT ON evidence BEGIN
  SELECT RAISE(ABORT, 'evidence: source excluded or revoked')
    WHERE (SELECT handling FROM source WHERE id = NEW.source_id) = 'excluded'
       OR (SELECT revoked_at FROM source WHERE id = NEW.source_id) IS NOT NULL;
  SELECT RAISE(ABORT, 'evidence: anonymized_only source cannot be tied to a named decider')
    WHERE (SELECT handling FROM source WHERE id = NEW.source_id) = 'anonymized_only'
      AND (SELECT decider_alias FROM memory_entry WHERE id = NEW.entry_id) IS NOT NULL;
END;

-- 同意の撤回 → ソースを excluded+revoked → 証拠が全て失効した記録は revoked
CREATE TRIGGER trg_consent_withdraw AFTER UPDATE OF withdrawn_at ON consent
WHEN NEW.withdrawn_at IS NOT NULL AND OLD.withdrawn_at IS NULL BEGIN
  UPDATE source SET handling = 'excluded', revoked_at = NEW.withdrawn_at WHERE consent_id = NEW.id;
  UPDATE memory_entry SET status = 'revoked'
   WHERE status IN ('candidate','approved','quarantined')
     AND id IN (SELECT e.entry_id FROM evidence e JOIN source s ON s.id = e.source_id
                GROUP BY e.entry_id HAVING SUM(CASE WHEN s.revoked_at IS NULL THEN 1 ELSE 0 END) = 0);
END;

-- ---------- E9: 優先規則 (1つ) と矛盾チケット ----------
CREATE TABLE conflict_ticket (
  id INTEGER PRIMARY KEY,
  class_code TEXT NOT NULL, topic_key TEXT NOT NULL,
  entry_a INTEGER NOT NULL REFERENCES memory_entry(id),
  entry_b INTEGER NOT NULL REFERENCES memory_entry(id),
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  opened_at TEXT NOT NULL,
  resolution_note TEXT,
  UNIQUE (entry_a, entry_b)
);

-- 優先規則 (この順。最初に決まった段で止める):
--  P0 適用範囲: 2件の scope が祖先-子孫(同一含む)の関係にあるときだけ競合。無関係な scope 同士は競合しない
--  P1 mandatory 対 default: mandatory が勝つ
--  P2 scope の深さが違う: default 同士は深い(具体的な)方が勝つ。mandatory 同士は浅い(広い)方が勝つ
--  P3 同一 scope・同一判断者: valid_from が新しい方 (自分の判断の改訂)
--  P4 同一 scope・別判断者: その scope での権限 level が高い方。片方でも権限が無い/同位なら決めない
--  P5 決まらない: winner = NULL → 矛盾チケット。両方とも注入から外し、そのトピックの proceed を禁止
CREATE VIEW v_pair AS
SELECT a.id AS a_id, b.id AS b_id, a.class_code, a.topic_key,
  CASE
    WHEN a.strength='mandatory' AND b.strength='default' THEN a.id
    WHEN b.strength='mandatory' AND a.strength='default' THEN b.id
    WHEN da.depth <> db.depth THEN
      CASE WHEN a.strength='mandatory' THEN (CASE WHEN da.depth < db.depth THEN a.id ELSE b.id END)
           ELSE (CASE WHEN da.depth > db.depth THEN a.id ELSE b.id END) END
    WHEN a.decider_alias IS NOT NULL AND a.decider_alias = b.decider_alias THEN
      CASE WHEN a.valid_from > b.valid_from THEN a.id WHEN b.valid_from > a.valid_from THEN b.id END
    WHEN la.level IS NOT NULL AND lb.level IS NOT NULL AND la.level <> lb.level THEN
      CASE WHEN la.level > lb.level THEN a.id ELSE b.id END
  END AS winner,
  CASE
    WHEN a.strength <> b.strength THEN 'P1_mandatory'
    WHEN da.depth <> db.depth THEN 'P2_scope_depth'
    WHEN a.decider_alias IS NOT NULL AND a.decider_alias = b.decider_alias AND a.valid_from <> b.valid_from THEN 'P3_newer_same_decider'
    WHEN la.level IS NOT NULL AND lb.level IS NOT NULL AND la.level <> lb.level THEN 'P4_authority_in_scope'
    ELSE 'P5_unresolved'
  END AS rule
FROM memory_entry a
JOIN memory_entry b ON a.id < b.id AND a.class_code = b.class_code AND a.topic_key = b.topic_key AND a.choice <> b.choice
JOIN v_scope_closure c ON (c.sub = a.scope AND c.sup = b.scope) OR (c.sub = b.scope AND c.sup = a.scope)
JOIN v_scope_depth da ON da.scope = a.scope
JOIN v_scope_depth db ON db.scope = b.scope
LEFT JOIN v_authority la ON la.alias = a.decider_alias AND la.scope = a.scope
LEFT JOIN v_authority lb ON lb.alias = b.decider_alias AND lb.scope = b.scope
CROSS JOIN v_now n
WHERE a.status = 'approved' AND b.status = 'approved'
  AND (a.valid_until IS NULL OR a.valid_until > n.now) AND (b.valid_until IS NULL OR b.valid_until > n.now);

CREATE TRIGGER trg_conflict_open AFTER UPDATE OF status ON memory_entry
WHEN NEW.status = 'approved' AND OLD.status <> 'approved' BEGIN
  INSERT OR IGNORE INTO conflict_ticket (class_code, topic_key, entry_a, entry_b, reason, opened_at)
  SELECT class_code, topic_key, a_id, b_id, rule, (SELECT now FROM v_now)
  FROM v_pair WHERE winner IS NULL AND (a_id = NEW.id OR b_id = NEW.id);
END;
CREATE TRIGGER trg_conflict_close AFTER UPDATE OF status ON memory_entry
WHEN NEW.status IN ('superseded','revoked','expired','quarantined') BEGIN
  UPDATE conflict_ticket SET status = 'resolved', resolution_note = 'entry ' || NEW.id || ' became ' || NEW.status
   WHERE status = 'open' AND (entry_a = NEW.id OR entry_b = NEW.id);
END;

-- 注入してよい記録 (task_scope ごと)。approved・期限内・task_scope に適用可能(entry.scope が task_scope の祖先か同一)・
-- その task_scope で優先規則に負けていない・その task_scope で未解決矛盾に関与していない。
-- global の default 判断が proj-x の判断に負けても、proj-y では有効なまま (scope 別に評価するのがポイント)。
-- これは DB 側の第1層。署名の再検証は読み出し側 f_approval.verified_effective が行う。
CREATE VIEW v_effective_by_scope AS
SELECT s.scope AS task_scope, m.*
FROM scope_node s
JOIN v_scope_closure c ON c.sub = s.scope
JOIN memory_entry m ON m.scope = c.sup
CROSS JOIN v_now n
WHERE m.status = 'approved' AND (m.valid_until IS NULL OR m.valid_until > n.now)
  AND NOT EXISTS (SELECT 1 FROM v_pair p
        JOIN v_scope_closure cw ON cw.sub = s.scope
        JOIN memory_entry w ON w.scope = cw.sup AND w.id = CASE WHEN p.a_id = m.id THEN p.b_id ELSE p.a_id END
        WHERE (p.a_id = m.id OR p.b_id = m.id) AND p.winner = w.id)
  AND NOT EXISTS (SELECT 1 FROM conflict_ticket t
        JOIN v_scope_closure cw ON cw.sub = s.scope
        JOIN memory_entry w ON w.scope = cw.sup AND w.id = CASE WHEN t.entry_a = m.id THEN t.entry_b ELSE t.entry_a END
        WHERE t.status = 'open' AND (t.entry_a = m.id OR t.entry_b = m.id));

-- ---------- E7: AI 判断・動作表・質問キュー ----------
CREATE TABLE ai_decision (
  id INTEGER PRIMARY KEY,
  task_id TEXT NOT NULL,
  class_code TEXT NOT NULL REFERENCES decision_class(code),
  scope TEXT NOT NULL REFERENCES scope_node(scope),
  topic_key TEXT,
  confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  action TEXT NOT NULL CHECK (action IN ('proceed','proceed_with_assumption','park_task','escalate')),
  decided_at TEXT NOT NULL,
  question TEXT, default_taken TEXT, rollback_plan TEXT,
  human_outcome TEXT NOT NULL DEFAULT 'unreviewed' CHECK (human_outcome IN ('agree','overturned','unreviewed')),
  CHECK (action = 'proceed' OR question IS NOT NULL),
  CHECK (action <> 'proceed_with_assumption' OR (default_taken IS NOT NULL AND rollback_plan IS NOT NULL))
);

-- 動作表の強制: 申告した action は、表から導かれる action 以上に保守的でなければならない
-- 保守度: proceed 1 < proceed_with_assumption 2 < park_task 3 < escalate 4
CREATE TRIGGER trg_decision_action BEFORE INSERT ON ai_decision
WHEN (CASE NEW.action WHEN 'proceed' THEN 1 WHEN 'proceed_with_assumption' THEN 2 WHEN 'park_task' THEN 3 ELSE 4 END) <
 (SELECT CASE
    WHEN dc.authority = 'A2_human_only' THEN 4
    WHEN dc.reversibility = 'R2_irreversible' THEN (CASE WHEN NEW.confidence < dc.min_confidence THEN 3 ELSE 4 END)
    WHEN NEW.confidence < dc.min_confidence THEN 2
    WHEN NEW.topic_key IS NOT NULL AND EXISTS (SELECT 1 FROM conflict_ticket t
         JOIN memory_entry ea ON ea.id = t.entry_a JOIN v_scope_closure ca ON ca.sub = NEW.scope AND ca.sup = ea.scope
         JOIN memory_entry eb ON eb.id = t.entry_b JOIN v_scope_closure cb ON cb.sub = NEW.scope AND cb.sup = eb.scope
         WHERE t.status = 'open' AND t.class_code = NEW.class_code AND t.topic_key = NEW.topic_key) THEN 2
    ELSE 1 END
  FROM decision_class dc WHERE dc.code = NEW.class_code)
BEGIN SELECT RAISE(ABORT, 'action less conservative than the policy table allows'); END;

CREATE TABLE review_queue (
  id INTEGER PRIMARY KEY,
  decision_id INTEGER NOT NULL UNIQUE REFERENCES ai_decision(id),
  class_code TEXT NOT NULL, scope TEXT NOT NULL,
  question TEXT NOT NULL, default_taken TEXT, rollback_plan TEXT,
  owner_alias TEXT REFERENCES person_alias(alias),       -- 作成時に scope の責任者を解決。NULL なら v_queue_unowned に出る
  escalated_to TEXT REFERENCES person_alias(alias),
  created_at TEXT NOT NULL, expires_at TEXT NOT NULL,
  renotify_count INTEGER NOT NULL DEFAULT 0,
  escalation_level INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','defaulted')),
  answer TEXT, answered_by TEXT REFERENCES approver(alias), answered_at TEXT, answer_sig TEXT
);

-- 書込み者: ai_decision の INSERT トリガだけ (エージェントは ai_decision を書く)
CREATE TRIGGER trg_queue_create AFTER INSERT ON ai_decision WHEN NEW.action <> 'proceed' BEGIN
  INSERT INTO review_queue (decision_id, class_code, scope, question, default_taken, rollback_plan,
                            owner_alias, created_at, expires_at)
  VALUES (NEW.id, NEW.class_code, NEW.scope, NEW.question, NEW.default_taken, NEW.rollback_plan,
    (SELECT alias FROM v_responsible WHERE scope = NEW.scope ORDER BY dist, level DESC, alias LIMIT 1),
    (SELECT now FROM v_now),
    strftime('%Y-%m-%dT%H:%M:%SZ', (SELECT now FROM v_now),
             '+' || (SELECT queue_ttl_hours FROM decision_class WHERE code = NEW.class_code) || ' hours'));
END;

-- 回答者: scope の責任者候補(level>=2)の署名付き回答だけ。署名が無い/偽造は拒否
CREATE TRIGGER trg_queue_answer BEFORE UPDATE OF status ON review_queue
WHEN NEW.status = 'answered' AND OLD.status <> 'answered' BEGIN
  SELECT RAISE(ABORT, 'answer: answerer is not a responsible approver for this scope')
    WHERE NOT EXISTS (SELECT 1 FROM v_responsible r JOIN approver a ON a.alias = r.alias AND a.active = 1
                      WHERE r.scope = NEW.scope AND r.alias = NEW.answered_by);
  SELECT RAISE(ABORT, 'answer: bad signature')
    WHERE NEW.answer_sig IS NULL OR verify_sig(NEW.answered_by,
      'queue|' || NEW.id || '|' || NEW.answer || '|' || NEW.answered_by || '|' || NEW.answered_at, NEW.answer_sig) <> 1;
END;
CREATE TRIGGER trg_queue_outcome AFTER UPDATE OF status ON review_queue
WHEN NEW.status = 'answered' AND OLD.status <> 'answered' BEGIN
  UPDATE ai_decision SET human_outcome = CASE WHEN NEW.default_taken IS NULL THEN 'unreviewed'
                                              WHEN NEW.answer = NEW.default_taken THEN 'agree' ELSE 'overturned' END
   WHERE id = NEW.decision_id;
END;

-- 質問キューの読み手 (単一仕様):
--  人間: v_queue_by_owner (担当者/エスカレーション先ごと)。エージェントループ: タスク切替時と SessionStart に
--  v_queue_answers_for_agent で回答済みを取り込み、仮定が覆った(overturned)成果物を v_overturn_impact で再作業に回す。
CREATE VIEW v_queue_by_owner AS
SELECT COALESCE(escalated_to, owner_alias) AS responsible, id, class_code, scope, status, expires_at, escalation_level
FROM review_queue WHERE status = 'open';
CREATE VIEW v_queue_unowned AS SELECT * FROM review_queue WHERE status = 'open' AND owner_alias IS NULL;
CREATE VIEW v_queue_answers_for_agent AS
SELECT q.id, d.task_id, q.status, q.answer, q.default_taken, d.human_outcome
FROM review_queue q JOIN ai_decision d ON d.id = q.decision_id WHERE q.status IN ('answered','defaulted');

CREATE TABLE decision_use (
  decision_id INTEGER NOT NULL REFERENCES ai_decision(id),
  entry_id INTEGER REFERENCES memory_entry(id),
  artifact TEXT,                                -- 仮定に依存した成果物 (ファイル/PR など)
  PRIMARY KEY (decision_id, entry_id, artifact)
);
CREATE VIEW v_overturn_impact AS
SELECT d.id AS decision_id, d.task_id, u.artifact
FROM ai_decision d JOIN decision_use u ON u.decision_id = d.id WHERE d.human_outcome = 'overturned';

-- 影響範囲: ソース失効から記録・AI 判断を列挙
CREATE VIEW v_blast_radius AS
SELECT s.id AS source_id, m.id AS entry_id, d.id AS ai_decision_id, d.task_id
FROM source s JOIN evidence e ON e.source_id = s.id JOIN memory_entry m ON m.id = e.entry_id
LEFT JOIN decision_use u ON u.entry_id = m.id LEFT JOIN ai_decision d ON d.id = u.decision_id;

-- ---------- 評価 (E5/E6) ----------
-- eval_case/eval_result は「プライベート環境」と「合成」だけに存在する。リポジトリには入れない実データ版は集計値のみ持ち帰る。
CREATE TABLE eval_run (
  id INTEGER PRIMARY KEY,
  environment TEXT NOT NULL CHECK (environment IN ('synthetic','private')),
  code_version TEXT NOT NULL, ran_at TEXT NOT NULL, model TEXT, k_samples INTEGER
);
CREATE TABLE eval_case (
  id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL REFERENCES eval_run(id),
  class_code TEXT NOT NULL REFERENCES decision_class(code),
  split TEXT NOT NULL CHECK (split IN ('memory','calibration','test')),
  decided_at TEXT NOT NULL, human_choice TEXT NOT NULL, retest_choice TEXT
);
CREATE TABLE eval_result (
  case_id INTEGER NOT NULL REFERENCES eval_case(id),
  arm TEXT NOT NULL CHECK (arm IN ('no_memory','rule_default','shuffled_memory','full_memory')),
  ai_choice TEXT, confidence REAL,
  PRIMARY KEY (case_id, arm)
);
CREATE VIEW v_agreement AS
SELECT c.class_code, r.arm, COUNT(*) AS n, AVG(r.ai_choice = c.human_choice) AS agree,
       AVG(c.retest_choice = c.human_choice) AS retest_ceiling
FROM eval_case c JOIN eval_result r ON r.case_id = c.id WHERE c.split = 'test' GROUP BY c.class_code, r.arm;
