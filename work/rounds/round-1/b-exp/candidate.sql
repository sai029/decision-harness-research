PRAGMA foreign_keys=ON;
CREATE TABLE source_item(
  source_id TEXT PRIMARY KEY,          -- 例: slack:C123/1709370060.0001
  kind TEXT NOT NULL CHECK(kind IN('slack','mail','minutes','pr_review','interview')),
  author TEXT, ts TEXT, trust TEXT NOT NULL DEFAULT 'untrusted' CHECK(trust IN('human','untrusted')),
  body_sha256 TEXT NOT NULL, consent_ref TEXT);
CREATE TABLE decision_candidate(
  cand_id TEXT PRIMARY KEY, title TEXT NOT NULL, decision TEXT NOT NULL,
  rationale TEXT, decider TEXT, decider_evidence TEXT CHECK(decider IS NULL OR decider_evidence IS NOT NULL),
  scope TEXT, reversibility TEXT CHECK(reversibility IN('one_way','reversible','unknown')) DEFAULT 'unknown',
  confidence REAL CHECK(confidence BETWEEN 0 AND 1),
  superseded_by TEXT REFERENCES decision_candidate(cand_id),
  status TEXT NOT NULL DEFAULT 'hypothesis' CHECK(status IN('hypothesis','confirmed','rejected','stale')),
  extractor TEXT NOT NULL, extracted_at TEXT NOT NULL, confirmed_by TEXT, confirmed_at TEXT,
  CHECK(status!='confirmed' OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)));
CREATE TABLE evidence(
  cand_id TEXT NOT NULL REFERENCES decision_candidate(cand_id),
  source_id TEXT NOT NULL REFERENCES source_item(source_id),
  quote TEXT NOT NULL, quote_verified INTEGER NOT NULL DEFAULT 0 CHECK(quote_verified IN(0,1)),
  role TEXT NOT NULL CHECK(role IN('decision','rationale','decider','reversal')),
  PRIMARY KEY(cand_id,source_id,role));
CREATE TABLE criterion_hypothesis(
  hyp_id TEXT PRIMARY KEY, person TEXT NOT NULL, statement TEXT NOT NULL,
  n_supporting INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'hypothesis'
  CHECK(status IN('hypothesis','confirmed','rejected')));
-- 注入制約: confirmed にできるのは quote 検証済みの根拠が1件以上ある候補のみ（トリガ）
CREATE TRIGGER confirm_needs_verified_evidence BEFORE UPDATE OF status ON decision_candidate
WHEN NEW.status='confirmed' AND (SELECT count(*) FROM evidence WHERE cand_id=NEW.cand_id AND quote_verified=1)=0
BEGIN SELECT RAISE(ABORT,'confirmed requires verified evidence'); END;
