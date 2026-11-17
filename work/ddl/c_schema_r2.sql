-- 判断記憶 索引スキーマ 担当C round-1 再調査版 (c_schema.sql からの差分: E3, E4, E9, E12 対応)
-- 正本は Markdown(Git)。このDBは c_rebuild.py で空から再構築できる派生索引。
PRAGMA foreign_keys = ON;

CREATE TABLE decision (
  id            TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  body          TEXT NOT NULL,
  status        TEXT NOT NULL CHECK (status IN ('proposed','approved','superseded','revoked')),
  reversibility TEXT NOT NULL CHECK (reversibility IN ('reversible','one_way')),
  authority     TEXT NOT NULL CHECK (authority IN ('agent_ok','needs_human')),
  confidence    REAL CHECK (confidence BETWEEN 0 AND 1),
  scope         TEXT NOT NULL DEFAULT 'global',
  topic_key     TEXT,                           -- 同一論点の判断を束ねる鍵。衝突検出に使う (E9)
  overridable   INTEGER NOT NULL DEFAULT 1 CHECK (overridable IN (0,1)), -- 0=狭い scope から上書き不可 (全社ポリシー等)
  decided_by    TEXT NOT NULL,                  -- 役割名 (実名は入れない)
  approval_ref  TEXT,                           -- 承認の外部事実 (PRマージのコミットID等)。偽造防止(E2)は別途
  valid_from    TEXT NOT NULL,                  -- 実世界の有効開始
  valid_to      TEXT,                           -- 実世界の有効終了 NULL=現在有効
  recorded_at   TEXT NOT NULL,                  -- 記録時間 (bitemporal の第2軸の開始)
  expires_at    TEXT,
  source_path   TEXT NOT NULL,
  content_hash  TEXT NOT NULL,
  CHECK (valid_to IS NULL OR valid_to >= valid_from),
  CHECK (NOT (status='proposed' AND authority='agent_ok')),
  CHECK (NOT (reversibility='one_way' AND authority='agent_ok')),
  -- proposed 以外は承認の外部事実が要る
  CHECK (status='proposed' OR approval_ref IS NOT NULL)
);
CREATE INDEX ix_decision_active ON decision(scope, status, valid_to);
CREATE INDEX ix_decision_topic ON decision(topic_key);

-- E9: 役割の権限ランクは scope ごと。大域ランクは持たない
CREATE TABLE role_grant (
  role  TEXT NOT NULL,
  scope TEXT NOT NULL,
  rank  INTEGER NOT NULL,                       -- 大きいほど強い。同一 scope 内でのみ比較する
  PRIMARY KEY (role, scope)
);

-- bitemporal の完全版: 版ごとに (記録時間, 実世界時間) を持つ。Git 履歴から再構築する
CREATE TABLE decision_history (
  id            TEXT NOT NULL,
  rev           INTEGER NOT NULL,
  recorded_from TEXT NOT NULL,
  recorded_to   TEXT,                           -- NULL=最新版
  valid_from    TEXT NOT NULL,
  valid_to      TEXT,
  status        TEXT NOT NULL,
  git_commit    TEXT NOT NULL,
  PRIMARY KEY (id, rev),
  CHECK (recorded_to IS NULL OR recorded_to >= recorded_from),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE decision_tag (
  decision_id TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  tag         TEXT NOT NULL,
  PRIMARY KEY (decision_id, tag)
);

-- E12: 本文・抜粋は複製しない。ref と quote のハッシュだけ持つ (引用の検証は ref 先を読んで照合)
CREATE TABLE evidence (
  id           INTEGER PRIMARY KEY,
  decision_id  TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('chat','pr','doc','interview','counterfactual')),
  ref          TEXT NOT NULL CHECK (length(ref) <= 300),
  quote_sha256 TEXT CHECK (quote_sha256 IS NULL OR length(quote_sha256)=64),
  sensitivity  TEXT NOT NULL DEFAULT 'internal' CHECK (sensitivity IN ('public','internal','restricted'))
);

CREATE TABLE decision_edge (
  src TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  dst TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  rel TEXT NOT NULL CHECK (rel IN ('supersedes','contradicts','depends_on','refines')),
  PRIMARY KEY (src, dst, rel),
  CHECK (src <> dst)
);

-- E9: 優先規則で決まらない矛盾の記録 (チケット)。a_id < b_id で正規化
CREATE TABLE decision_conflict (
  a_id      TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  b_id      TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  reason    TEXT NOT NULL,
  state     TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','resolved')),
  opened_at TEXT NOT NULL,
  PRIMARY KEY (a_id, b_id),
  CHECK (a_id < b_id)
);

CREATE TABLE open_question (
  id           INTEGER PRIMARY KEY,
  asked_at     TEXT NOT NULL,
  question     TEXT NOT NULL,
  default_used TEXT NOT NULL,
  related_id   TEXT REFERENCES decision(id) ON DELETE SET NULL,
  state        TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','answered','dropped')),
  answer       TEXT
);

CREATE VIRTUAL TABLE decision_fts USING fts5(
  title, body, content='decision', content_rowid='rowid', tokenize='trigram'
);
CREATE TRIGGER decision_ai AFTER INSERT ON decision BEGIN
  INSERT INTO decision_fts(rowid,title,body) VALUES (new.rowid,new.title,new.body);
END;
CREATE TRIGGER decision_ad AFTER DELETE ON decision BEGIN
  INSERT INTO decision_fts(decision_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
END;
CREATE TRIGGER decision_au AFTER UPDATE OF title,body ON decision BEGIN
  INSERT INTO decision_fts(decision_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
  INSERT INTO decision_fts(rowid,title,body) VALUES (new.rowid,new.title,new.body);
END;

-- E3: supersedes は「新旧とも approved」かつ「旧が needs_human なら新も needs_human」のときだけ挿入できる。
-- proposed/revoked/superseded の行を端点とする supersedes は ABORT。
CREATE TRIGGER edge_supersede_guard BEFORE INSERT ON decision_edge
WHEN new.rel='supersedes' BEGIN
  SELECT RAISE(ABORT,'supersede: src must be approved')
   WHERE (SELECT status FROM decision WHERE id=new.src) IS NOT 'approved';
  SELECT RAISE(ABORT,'supersede: dst must be approved')
   WHERE (SELECT status FROM decision WHERE id=new.dst) IS NOT 'approved';
  SELECT RAISE(ABORT,'supersede: needs_human dst requires needs_human src')
   WHERE (SELECT authority FROM decision WHERE id=new.dst)='needs_human'
     AND (SELECT authority FROM decision WHERE id=new.src)<>'needs_human';
END;

-- 同一 scope の supersedes のみ旧判断を失効 (scope 違いは E9 の優先規則で扱う)
CREATE TRIGGER edge_supersede AFTER INSERT ON decision_edge
WHEN new.rel='supersedes'
 AND (SELECT scope FROM decision WHERE id=new.src)=(SELECT scope FROM decision WHERE id=new.dst) BEGIN
  UPDATE decision SET status='superseded',
    valid_to = COALESCE(valid_to,(SELECT valid_from FROM decision WHERE id=new.src))
  WHERE id=new.dst;
END;

-- 現在有効な承認済み (scope では絞らない。scope と優先規則は c_effective.sql を使う)
CREATE VIEW v_active AS
SELECT * FROM decision
WHERE status='approved' AND valid_to IS NULL AND (expires_at IS NULL OR expires_at > date('now'));
