.headers on
.mode column
INSERT INTO decision VALUES
('DEC-0001','DBは SQLite を既定にする','小規模・単一ユーザーのため SQLite。前提: 同時書込みが少ない','approved','reversible','agent_ok',0.9,'global','role:lead','2026-01-10',NULL,'2026-01-10',NULL,'decisions/DEC-0001.md','h1'),
('DEC-0002','DBは PostgreSQL にする','複数ユーザー同時書込みが発生するため','approved','reversible','agent_ok',0.8,'proj-x','role:lead','2026-06-01',NULL,'2026-06-01','2027-06-01','decisions/DEC-0002.md','h2'),
('DEC-0003','外部公開APIの削除は必ず人間承認','一方通行の操作','approved','one_way','needs_human',1.0,'global','role:owner','2026-02-01',NULL,'2026-02-01',NULL,'decisions/DEC-0003.md','h3'),
('DEC-0004','ログ保存は30日','推測で抽出した仮説','proposed','reversible','needs_human',0.4,'global','role:agent','2026-07-01',NULL,'2026-07-01',NULL,'decisions/DEC-0004.md','h4');
INSERT INTO decision_tag VALUES ('DEC-0001','db'),('DEC-0002','db');
INSERT INTO decision_edge VALUES ('DEC-0002','DEC-0001','supersedes');
INSERT INTO decision_edge VALUES ('DEC-0004','DEC-0003','depends_on');
INSERT INTO decision VALUES ('DEC-0005','DBは PostgreSQL 16 にする','同一projの改訂','approved','reversible','agent_ok',0.8,'proj-x','role:lead','2026-09-01',NULL,'2026-09-01',NULL,'decisions/DEC-0005.md','h5');
INSERT INTO decision_edge VALUES ('DEC-0005','DEC-0002','supersedes');
INSERT INTO open_question(asked_at,question,default_used,related_id) VALUES ('2026-07-02','ログ保存期間は?','30日(仮)','DEC-0004');

.print --- 1. scope違い(proj-x が global を supersede)では失効しない / 同scopeなら失効
SELECT id,status,valid_to FROM decision ORDER BY id;
.print --- 2. v_active 注入対象
SELECT id,title FROM v_active;
.print --- 3. as-of 2026-03-01 の有効判断
SELECT id,title FROM decision WHERE status IN ('approved','superseded') AND valid_from<='2026-03-01' AND (valid_to IS NULL OR valid_to>'2026-03-01');
.print --- 4. FTS5 trigram 日本語部分一致 + bm25
SELECT d.id, bm25(decision_fts) AS score FROM decision_fts JOIN decision d ON d.rowid=decision_fts.rowid WHERE decision_fts MATCH '外部公開' ORDER BY score;
.print --- 5. 2文字クエリ 0件になるはず
SELECT count(*) AS n_2char FROM decision_fts WHERE decision_fts MATCH '削除';
.print --- 5b. 2文字は LIKE にフォールバック
SELECT id FROM decision WHERE title LIKE '%削除%' OR body LIKE '%削除%';
.print --- 6. 再帰CTE supersedes 連鎖
WITH RECURSIVE chain(id,depth) AS (SELECT 'DEC-0002',0 UNION ALL SELECT e.dst,depth+1 FROM decision_edge e JOIN chain c ON e.src=c.id WHERE e.rel='supersedes') SELECT * FROM chain;
.print --- 7. UPDATE 後の FTS 同期
UPDATE decision SET body='保存期間は90日に変更' WHERE id='DEC-0004';
SELECT id FROM decision_fts JOIN decision d ON d.rowid=decision_fts.rowid WHERE decision_fts MATCH '90日';
INSERT INTO decision_fts(decision_fts) VALUES('integrity-check');
.print --- 7b. integrity-check 完了 (エラー無しなら同期OK)
.print --- 8. 制約違反テスト 以下4件+2件は全て Error になるべき
INSERT INTO decision VALUES ('X1','t','b','approved','reversible','agent_ok',0.5,'g','r','2026-05-01','2026-04-01','2026-05-01',NULL,'p','h');
INSERT INTO decision VALUES ('X2','t','b','weird','reversible','agent_ok',0.5,'g','r','2026-05-01',NULL,'2026-05-01',NULL,'p','h');
INSERT INTO decision VALUES ('X3','t','b','proposed','reversible','agent_ok',0.5,'g','r','2026-05-01',NULL,'2026-05-01',NULL,'p','h');
INSERT INTO decision VALUES ('X4','t','b','approved','one_way','agent_ok',0.5,'g','r','2026-05-01',NULL,'2026-05-01',NULL,'p','h');
INSERT INTO decision_edge VALUES ('DEC-0001','DEC-0001','refines');
INSERT INTO decision_edge VALUES ('NOPE','DEC-0001','refines');
.print --- 9. cascade
DELETE FROM decision WHERE id='DEC-0004';
SELECT count(*) AS edges_left FROM decision_edge;
SELECT id,related_id FROM open_question;
INSERT INTO decision_fts(decision_fts) VALUES('integrity-check');
SELECT count(*) AS fts_hits_after_delete FROM decision_fts WHERE decision_fts MATCH '90日';
