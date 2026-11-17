PRAGMA foreign_keys=ON;
CREATE TABLE decision (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  rule TEXT NOT NULL,            -- 1-2 sentence injectable form
  rationale TEXT,
  status TEXT NOT NULL CHECK (status IN ('proposed','approved','superseded','expired','rejected')),
  reversibility TEXT NOT NULL CHECK (reversibility IN ('reversible','one_way')),
  authority TEXT NOT NULL CHECK (authority IN ('agent_ok','notify','human_required')),
  confidence REAL CHECK (confidence BETWEEN 0 AND 1),
  scope_paths TEXT,              -- glob list, newline separated
  valid_until TEXT,
  tier INTEGER NOT NULL DEFAULT 2 CHECK (tier IN (0,1,2)) -- 0=always inject,1=trigger,2=search only
);
CREATE TABLE decision_tag (decision_id TEXT REFERENCES decision(id) ON DELETE CASCADE, tag TEXT, PRIMARY KEY(decision_id, tag));
CREATE TABLE decision_trigger (decision_id TEXT REFERENCES decision(id) ON DELETE CASCADE, kind TEXT CHECK(kind IN ('tool','path','command','keyword')), pattern TEXT NOT NULL);
CREATE VIRTUAL TABLE decision_fts USING fts5(title, rule, rationale, tags, content='', tokenize='trigram');
CREATE VIRTUAL TABLE decision_fts_uni USING fts5(title, rule, rationale, tags, content='', tokenize='unicode61');
CREATE TABLE injection_log (ts TEXT DEFAULT (datetime('now')), session_id TEXT, event TEXT, decision_id TEXT, rank INTEGER, chars INTEGER, latency_ms REAL);
