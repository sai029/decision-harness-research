-- 注入対象の決定 (E4/E9)。パラメータ :scope (現在の project 名)。MCP サーバーが実行する。
-- 優先規則 (この順。最初に決まった所で止まる):
--  R0 global かつ overridable=0 は、狭い scope の判断より常に優先
--  R1 scope が異なる (global vs project) なら狭い方 (project) が勝つ
--  R2 同一 scope: role_grant.rank が高い方。どちらかの rank が無ければ決めない(tie)
--  R3 rank 同値: 同一 decided_by なら valid_from が新しい方。別人なら決めない(tie)
--  決まらない(tie)組は decision_conflict にチケット化し、両方を conflict=1 として返す。confidence は順序に使わない
-- @@pairs
WITH cand AS (SELECT * FROM v_active WHERE scope IN (:scope,'global'))
SELECT a.id AS a_id, b.id AS b_id,
  CASE
    WHEN a.scope='global' AND a.overridable=0 AND b.scope<>'global' THEN 'a:R0'
    WHEN b.scope='global' AND b.overridable=0 AND a.scope<>'global' THEN 'b:R0'
    WHEN a.scope<>b.scope THEN CASE WHEN a.scope='global' THEN 'b:R1' ELSE 'a:R1' END
    WHEN ga.rank IS NULL OR gb.rank IS NULL THEN 'tie:no_rank'
    WHEN ga.rank<>gb.rank THEN CASE WHEN ga.rank>gb.rank THEN 'a:R2' ELSE 'b:R2' END
    WHEN a.decided_by<>b.decided_by THEN 'tie:same_rank_diff_person'
    WHEN a.valid_from<>b.valid_from THEN CASE WHEN a.valid_from>b.valid_from THEN 'a:R3' ELSE 'b:R3' END
    ELSE 'tie:same_date'
  END AS outcome
FROM cand a JOIN cand b ON a.id<b.id
LEFT JOIN role_grant ga ON ga.role=a.decided_by AND ga.scope=a.scope
LEFT JOIN role_grant gb ON gb.role=b.decided_by AND gb.scope=b.scope
WHERE (a.topic_key IS NOT NULL AND a.topic_key=b.topic_key)
   OR EXISTS (SELECT 1 FROM decision_edge e WHERE e.rel='contradicts'
              AND ((e.src=a.id AND e.dst=b.id) OR (e.src=b.id AND e.dst=a.id)))
-- @@ticket
-- (Python が "WITH t_pairs AS (<pairs>)" を前置する。VIEW はパラメータ不可のため)
INSERT OR IGNORE INTO decision_conflict(a_id,b_id,reason,opened_at)
SELECT a_id,b_id,substr(outcome,5),:now FROM t_pairs WHERE outcome LIKE 'tie:%';
-- @@effective
SELECT d.id, d.scope, d.decided_by,
  CASE WHEN EXISTS (SELECT 1 FROM t_pairs p WHERE p.outcome LIKE 'tie:%' AND d.id IN (p.a_id,p.b_id))
       THEN 1 ELSE 0 END AS conflict
FROM v_active d
WHERE d.scope IN (:scope,'global')
  AND NOT EXISTS (SELECT 1 FROM t_pairs p
      WHERE (p.outcome LIKE 'a:%' AND p.b_id=d.id) OR (p.outcome LIKE 'b:%' AND p.a_id=d.id))
ORDER BY d.id;
