-- 判断記憶 索引スキーマ (担当C, round-1). 正本は Markdown(Git)、これは再構築可能な派生索引。
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE decision (
  id            TEXT PRIMARY KEY,               -- 例 DEC-0001 (Markdown ファイル名と一致)
  title         TEXT NOT NULL,
  body          TEXT NOT NULL,                  -- 判断+理由+前提の本文
  status        TEXT NOT NULL CHECK (status IN ('proposed','approved','superseded','revoked')),
  reversibility TEXT NOT NULL CHECK (reversibility IN ('reversible','one_way')),
  authority     TEXT NOT NULL CHECK (authority IN ('agent_ok','needs_human')),
  confidence    REAL CHECK (confidence BETWEEN 0 AND 1),
  scope         TEXT NOT NULL DEFAULT 'global', -- project 名 or global
  decided_by    TEXT NOT NULL,                  -- 役割名 (実名は入れない)
  valid_from    TEXT NOT NULL,                  -- 実世界で有効になった日 (ISO8601)
  valid_to      TEXT,                           -- NULL=現在有効
  recorded_at   TEXT NOT NULL,                  -- 記録した日 (bitemporal の記録時間)
  expires_at    TEXT,                           -- 再確認期限
  source_path   TEXT NOT NULL,                  -- 正本 Markdown の相対パス
  content_hash  TEXT NOT NULL,
  CHECK (valid_to IS NULL OR valid_to >= valid_from),
  -- 抽出直後の仮説(proposed)は agent_ok にできない: 承認までは権威なし
  CHECK (NOT (status='proposed' AND authority='agent_ok')),
  -- 一方通行は常に人間
  CHECK (NOT (reversibility='one_way' AND authority='agent_ok'))
);
CREATE INDEX ix_decision_active ON decision(scope, status, valid_to);

CREATE TABLE decision_tag (
  decision_id TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  tag         TEXT NOT NULL,
  PRIMARY KEY (decision_id, tag)
);

CREATE TABLE evidence (
  id          INTEGER PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('chat','pr','doc','interview','counterfactual')),
  ref         TEXT NOT NULL,                    -- 参照先ID/URL (本文は複製しない)
  excerpt     TEXT,
  sensitivity TEXT NOT NULL DEFAULT 'internal' CHECK (sensitivity IN ('public','internal','restricted'))
);

CREATE TABLE decision_edge (                    -- グラフはエッジ表で持つ
  src  TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  dst  TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  rel  TEXT NOT NULL CHECK (rel IN ('supersedes','contradicts','depends_on','refines')),
  PRIMARY KEY (src, dst, rel),
  CHECK (src <> dst)
);

CREATE TABLE open_question (                    -- 非同期キュー (作業は止めない)
  id           INTEGER PRIMARY KEY,
  asked_at     TEXT NOT NULL,
  question     TEXT NOT NULL,
  default_used TEXT NOT NULL,                   -- 待たずに採った保守的既定
  related_id   TEXT REFERENCES decision(id) ON DELETE SET NULL,
  state        TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','answered','dropped')),
  answer       TEXT
);

-- 全文検索: 日本語対応のため trigram。外部コンテンツ表で二重保存を避ける。
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

-- 同一scopeの supersedes エッジ追加時のみ旧判断を自動失効。scope違い(例: project が global を上書き)は失効させない
CREATE TRIGGER edge_supersede AFTER INSERT ON decision_edge
WHEN new.rel='supersedes'
 AND (SELECT scope FROM decision WHERE id=new.src)=(SELECT scope FROM decision WHERE id=new.dst) BEGIN
  UPDATE decision SET status='superseded',
    valid_to = COALESCE(valid_to,(SELECT valid_from FROM decision WHERE id=new.src))
  WHERE id=new.dst;
END;

-- 注入対象: 現在有効かつ承認済み
CREATE VIEW v_active AS
SELECT * FROM decision
WHERE status='approved' AND valid_to IS NULL AND (expires_at IS NULL OR expires_at > date('now'));
