-- A.md §2.4 の DDL (round-1 原版)。未修正。E2/E3 の欠陥を含む。
PRAGMA foreign_keys = ON;

CREATE TABLE role (
  role_id TEXT PRIMARY KEY,
  authority_rank INTEGER NOT NULL,
  max_reversibility TEXT NOT NULL CHECK (max_reversibility IN ('two_way','costly','one_way','none')),
  note TEXT
);

CREATE TABLE decision (
  decision_id   TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('principle','technical','product','process','preference')),
  status        TEXT NOT NULL DEFAULT 'proposed'
                CHECK (status IN ('proposed','accepted','superseded','deprecated','rejected')),
  epistemic     TEXT NOT NULL DEFAULT 'hypothesis' CHECK (epistemic IN ('hypothesis','confirmed')),
  decision_text TEXT NOT NULL,
  rationale     TEXT NOT NULL,
  tradeoff      TEXT,
  card          TEXT NOT NULL,
  decider_role  TEXT NOT NULL REFERENCES role(role_id),
  decider_ref   TEXT,
  required_role TEXT REFERENCES role(role_id),
  reversibility TEXT NOT NULL CHECK (reversibility IN ('two_way','costly','one_way')),
  confidence    REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  confidence_basis TEXT NOT NULL CHECK (confidence_basis IN
    ('stated_explicitly','inferred_from_behavior','extracted_single_source','extracted_multi_source')),
  agent_mode    TEXT NOT NULL DEFAULT 'follow'
                CHECK (agent_mode IN ('follow','follow_and_log','ask_async','human_only')),
  fallback      TEXT,
  valid_from    TEXT NOT NULL,
  valid_until   TEXT,
  review_by     TEXT,
  recorded_at   TEXT NOT NULL,
  approved_by   TEXT,
  approved_at   TEXT,
  CHECK (status <> 'accepted' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND epistemic='confirmed')),
  CHECK (valid_until IS NULL OR valid_until >= valid_from),
  CHECK (length(card) <= 300),
  CHECK (reversibility <> 'one_way' OR agent_mode IN ('ask_async','human_only'))
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

CREATE TABLE decision_scope (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  dim TEXT NOT NULL CHECK (dim IN ('project','path','task_type','tag')),
  pattern TEXT NOT NULL,
  exclude INTEGER NOT NULL DEFAULT 0 CHECK (exclude IN (0,1)),
  PRIMARY KEY (decision_id, dim, pattern)
);

CREATE TABLE decision_source (
  decision_id TEXT NOT NULL REFERENCES decision(decision_id) ON DELETE CASCADE,
  source_kind TEXT NOT NULL CHECK (source_kind IN
    ('direct_statement','chat','review_comment','commit','interview','deviation_note')),
  ref TEXT NOT NULL,
  extracted_by TEXT
);

CREATE TABLE decision_link (
  from_id TEXT NOT NULL REFERENCES decision(decision_id),
  to_id   TEXT NOT NULL REFERENCES decision(decision_id),
  link_type TEXT NOT NULL CHECK (link_type IN ('supersedes','conflicts_with','depends_on','refines')),
  PRIMARY KEY (from_id, to_id, link_type),
  CHECK (from_id <> to_id)
);

CREATE TRIGGER decision_immutable
BEFORE UPDATE OF decision_text, rationale, tradeoff, decider_role, reversibility, valid_from ON decision
WHEN old.status IN ('accepted','superseded')
BEGIN SELECT RAISE(ABORT, 'accepted decision is immutable: write a superseding record'); END;

CREATE TRIGGER link_supersede AFTER INSERT ON decision_link WHEN new.link_type='supersedes'
BEGIN UPDATE decision SET status='superseded' WHERE decision_id=new.to_id; END;

CREATE VIEW v_effective AS
SELECT * FROM decision
WHERE status='accepted' AND valid_from <= date('now')
  AND (valid_until IS NULL OR valid_until >= date('now'));

-- 矛盾時の優先: confirmed > 権限ランク > 新しい valid_from > 確信度
CREATE VIEW v_precedence AS
SELECT d.*, r.authority_rank,
  ROW_NUMBER() OVER (ORDER BY (d.epistemic='confirmed') DESC, r.authority_rank DESC,
                              d.valid_from DESC, d.confidence DESC) AS prec
FROM v_effective d JOIN role r ON r.role_id = d.decider_role;
