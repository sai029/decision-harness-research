-- 質問キューの期限切れ処理 (定期実行。時刻は v_now)。単一仕様:
--  R0 (安いクラス): 既定を確定 (status=defaulted)。後で人間が答えれば overturned として追える。
--  R1/R2/A2: 既定のまま継続 (R1) / 駐車のまま (R2,A2) で、再通知 + 1段上の責任者へエスカレーション。期限を renotify_hours 延ばす。
UPDATE review_queue SET status = 'defaulted'
 WHERE status = 'open' AND expires_at <= (SELECT now FROM v_now)
   AND class_code IN (SELECT code FROM decision_class WHERE reversibility = 'R0_cheap');

UPDATE review_queue AS q SET
  renotify_count = renotify_count + 1,
  escalation_level = escalation_level + 1,
  escalated_to = COALESCE((SELECT x.alias FROM (SELECT r.alias AS alias,
                             ROW_NUMBER() OVER (ORDER BY r.dist, r.level DESC, r.alias) - 1 AS rn
                           FROM v_responsible r WHERE r.scope = q.scope) x
                           WHERE x.rn = q.escalation_level + 1), escalated_to),
  expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', (SELECT now FROM v_now),
                        '+' || (SELECT renotify_hours FROM decision_class WHERE code = q.class_code) || ' hours')
 WHERE status = 'open' AND expires_at <= (SELECT now FROM v_now);
