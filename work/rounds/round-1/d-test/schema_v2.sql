-- D 側の「検索・注入に必要な最小列」(v2)。統合スキーマ(work/ddl/unified_schema.sql)の入力要件。
-- 判断DB(読取専用で開く)と状態DB(注入ログ・質問キュー。フックが書く)を別ファイルにする。
PRAGMA foreign_keys=ON;

-- ===== decisions.db (hook は mode=ro で開く) =====
CREATE TABLE decision (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  rule TEXT NOT NULL,                 -- 注入専用 1-2 文
  rationale TEXT,                     -- 注入しない
  status TEXT NOT NULL CHECK (status IN ('proposed','approved','superseded','expired','rejected')),
  reversibility TEXT NOT NULL CHECK (reversibility IN ('reversible','one_way')),
  authority TEXT NOT NULL CHECK (authority IN ('agent_ok','notify','human_required')),
  confidence REAL CHECK (confidence BETWEEN 0 AND 1),
  scope_level TEXT NOT NULL DEFAULT 'global' CHECK (scope_level IN ('global','project','path')),
  project TEXT,                       -- scope_level in (project,path) のとき cwd の末尾ディレクトリ名と一致が必要
  scope_paths TEXT,                   -- scope_level='path' のとき glob(改行区切り)
  topic TEXT,                         -- 矛盾検出キー。同一 topic で rule が異なる2件が同時ヒット=矛盾
  valid_from TEXT,
  valid_until TEXT,
  tier INTEGER NOT NULL DEFAULT 2 CHECK (tier IN (0,1,2)),
  CHECK (scope_level='global' OR project IS NOT NULL)
);
CREATE TABLE decision_tag (
  decision_id TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  not_followed_by TEXT,               -- 複合語の誤発火ガード(例 tag=ログ, ここに「イン」)。空白区切り
  PRIMARY KEY (decision_id, tag)
);
CREATE TABLE decision_trigger (
  decision_id TEXT NOT NULL REFERENCES decision(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('tool','path','command','keyword')),
  pattern TEXT NOT NULL,              -- command: 正規表現(search) / path: glob / tool: 完全一致
  action TEXT NOT NULL DEFAULT 'inject' CHECK (action IN ('inject','ask','deny'))
);
CREATE INDEX idx_dec_status ON decision(status, tier);

-- ===== state.db (hook が書く。判断の正本ではない) =====
-- CREATE は hook 側で IF NOT EXISTS 実行。ここは仕様として載せる。
CREATE TABLE injection_log (
  ts TEXT NOT NULL, session_id TEXT, agent_id TEXT, agent_type TEXT,
  event TEXT, decision_id TEXT, chars INTEGER
);
-- 質問キュー(単一仕様)。書く=PreToolUse hook(決定的に自動)/ エージェント(MCP queue_question)。
-- 読む=SessionStart hook(open/answered 件数を注入)と人間(CLI)。期限切れ=sweep が on_expire を適用。
CREATE TABLE open_question (
  qid TEXT PRIMARY KEY,
  decision_id TEXT,                   -- 発火元の判断(なければ NULL)
  context TEXT NOT NULL,              -- 何をしようとして止まったか(機微を含めない短い要約)
  raised_by TEXT NOT NULL,            -- 'hook' | agent_id
  raised_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  on_expire TEXT NOT NULL CHECK (on_expire IN ('park','take_reversible_default','escalate')),
  owner_role TEXT NOT NULL,           -- 期限切れ時に責任を持つ役割(人名でなく role)
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','expired','withdrawn')),
  answered_by TEXT, answered_at TEXT, answer TEXT,
  CHECK (status<>'answered' OR (answered_by IS NOT NULL AND answer IS NOT NULL))
);
