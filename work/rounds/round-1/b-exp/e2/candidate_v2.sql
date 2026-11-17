-- B 担当の候補テーブル v2: confirmed への遷移を「DB の外で検証できる署名」に結びつける（E2 対応）
-- 前提: approvers.pub.json（承認者ID -> Ed25519 公開鍵）は Git 管理で DB の外に置く。
--       verify_confirmation() は承認プロセスと検証プロセスの接続にだけ登録する（SQLite のトリガは
--       関数名を文の準備時に解決するため、関数が無い接続では confirmation への INSERT が "no such function" で失敗する）。
PRAGMA foreign_keys=ON;
CREATE TABLE source_item(
  source_id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN('slack','mail','minutes','pr_review','interview')),
  author TEXT, ts TEXT, trust TEXT NOT NULL DEFAULT 'untrusted' CHECK(trust IN('human','untrusted')),
  body_sha256 TEXT NOT NULL, consent_ref TEXT);
CREATE TABLE decision_candidate(
  cand_id TEXT PRIMARY KEY, title TEXT NOT NULL, decision TEXT NOT NULL, rationale TEXT, decider TEXT,
  decider_evidence TEXT CHECK(decider IS NULL OR decider_evidence IS NOT NULL), scope TEXT,
  status TEXT NOT NULL DEFAULT 'hypothesis' CHECK(status IN('hypothesis','confirmed','rejected','stale')),
  extractor TEXT NOT NULL, extracted_at TEXT NOT NULL, confirmed_by TEXT, confirmed_at TEXT,
  CHECK(status!='confirmed' OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)));
CREATE TABLE evidence(
  cand_id TEXT NOT NULL REFERENCES decision_candidate(cand_id), source_id TEXT NOT NULL REFERENCES source_item(source_id),
  quote TEXT NOT NULL, quote_verified INTEGER NOT NULL DEFAULT 0 CHECK(quote_verified IN(0,1)),
  role TEXT NOT NULL CHECK(role IN('decision','rationale','decider','reversal')), PRIMARY KEY(cand_id,source_id,role));
-- 承認記録。署名は内容（canon の8項目）に結びつく。追記専用。
CREATE TABLE confirmation(
  cand_id TEXT NOT NULL, title TEXT NOT NULL, decision TEXT NOT NULL, rationale TEXT, decider TEXT, scope TEXT,
  approver_id TEXT NOT NULL, approved_at TEXT NOT NULL, sig TEXT NOT NULL, PRIMARY KEY(cand_id,approver_id,approved_at));
CREATE TRIGGER confirmation_verify BEFORE INSERT ON confirmation
BEGIN SELECT RAISE(ABORT,'invalid human signature')
  WHERE verify_confirmation(NEW.cand_id,NEW.title,NEW.decision,NEW.rationale,NEW.decider,NEW.scope,NEW.approver_id,NEW.approved_at,NEW.sig) IS NOT 1; END;
CREATE TRIGGER confirmation_append_only_u BEFORE UPDATE ON confirmation BEGIN SELECT RAISE(ABORT,'confirmation is append-only'); END;
CREATE TRIGGER confirmation_append_only_d BEFORE DELETE ON confirmation BEGIN SELECT RAISE(ABORT,'confirmation is append-only'); END;
-- confirmed にできるのは「同じ内容・同じ承認者・同じ時刻の承認記録」がある行だけ（INSERT 経路も UPDATE 経路も）
CREATE TRIGGER confirm_needs_confirmation_ins BEFORE INSERT ON decision_candidate WHEN NEW.status='confirmed'
BEGIN SELECT RAISE(ABORT,'confirmed requires matching signed confirmation') WHERE NOT EXISTS(
  SELECT 1 FROM confirmation k WHERE k.cand_id=NEW.cand_id AND k.title=NEW.title AND k.decision=NEW.decision
   AND k.rationale IS NEW.rationale AND k.decider IS NEW.decider AND k.scope IS NEW.scope
   AND k.approver_id IS NEW.confirmed_by AND k.approved_at IS NEW.confirmed_at); END;
CREATE TRIGGER confirm_needs_confirmation_upd BEFORE UPDATE ON decision_candidate WHEN NEW.status='confirmed'
BEGIN SELECT RAISE(ABORT,'confirmed requires matching signed confirmation') WHERE NOT EXISTS(
  SELECT 1 FROM confirmation k WHERE k.cand_id=NEW.cand_id AND k.title=NEW.title AND k.decision=NEW.decision
   AND k.rationale IS NEW.rationale AND k.decider IS NEW.decider AND k.scope IS NEW.scope
   AND k.approver_id IS NEW.confirmed_by AND k.approved_at IS NEW.confirmed_at); END;
-- quote 検証済みの根拠が1件以上（INSERT 経路も含める）
CREATE TRIGGER confirm_needs_verified_evidence BEFORE UPDATE ON decision_candidate
WHEN NEW.status='confirmed' AND (SELECT count(*) FROM evidence WHERE cand_id=NEW.cand_id AND quote_verified=1)=0
BEGIN SELECT RAISE(ABORT,'confirmed requires verified evidence'); END;
CREATE TRIGGER confirm_needs_verified_evidence_ins BEFORE INSERT ON decision_candidate
WHEN NEW.status='confirmed'
BEGIN SELECT RAISE(ABORT,'confirmed cannot be inserted directly; insert as hypothesis, attach evidence, then confirm'); END;
CREATE TRIGGER confirmed_is_frozen BEFORE UPDATE OF title,decision,rationale,decider,scope,confirmed_by,confirmed_at ON decision_candidate
WHEN OLD.status='confirmed' BEGIN SELECT RAISE(ABORT,'confirmed rows are frozen'); END;
CREATE TRIGGER confirmed_no_downgrade BEFORE UPDATE OF status ON decision_candidate
WHEN OLD.status='confirmed' AND NEW.status NOT IN('confirmed','stale')
BEGIN SELECT RAISE(ABORT,'confirmed can only become stale'); END;
