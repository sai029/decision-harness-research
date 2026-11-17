-- 担当F: 署名を要しない SQL テスト (f_run.py が上から実行し、期待と照合する)。全データは合成。
-- 書式: "-- Tnn expect=ok|fail[部分文字列] 説明" の次行から空行まで。fail は例外メッセージに部分文字列を含むこと。

-- S00 expect=ok 固定データ(人・scope・権限・クラス・規約)
INSERT INTO person_alias VALUES ('boss-001','dept_head'),('lead-001','tech_lead'),('senior-001','senior'),('senior-002','senior'),('agent-x','agent');
INSERT INTO scope_node VALUES ('global',NULL),('dept-a','global'),('dept-b','global'),('proj-x','dept-a'),('proj-y','dept-b');
INSERT INTO scope_authority VALUES ('boss-001','dept-a',3),('lead-001','proj-x',2),('senior-001','proj-x',1),('senior-002','dept-b',1);
INSERT INTO approver VALUES ('boss-001',1),('lead-001',1),('senior-001',1);
INSERT INTO decision_class (code,reversibility,authority,min_confidence,max_wrong_rate,default_ttl_days,queue_ttl_hours,renotify_hours) VALUES
 ('c_dep','R0_cheap','A0_task',0.7,0.10,180,24,12),
 ('c_schema','R1_costly','A1_owner',0.8,0.05,90,24,12),
 ('c_deploy','R2_irreversible','A1_owner',1.0,0.01,30,24,12),
 ('c_budget','R2_irreversible','A2_human_only',1.0,0.0,30,24,12);
INSERT INTO service_terms VALUES ('repo_docs','allowed','2026-11-17','https://example.invalid/internal-policy','own synthetic repo docs'),
 ('slack','unverified',NULL,NULL,'API terms: LLM training prohibited; in-context use needs legal check'),
 ('github_pr','restricted','2026-11-17','https://docs.github.com/en/site-policy/github-terms/github-terms-of-service','AI clauses exist; legal check needed');
INSERT INTO consent (id,subject_alias,purposes,scope,external_llm_allowed,granted_at) VALUES
 (1,'lead-001','judgement reference for agents (not personal proxy)','proj-x',0,'2026-01-05T00:00:00Z'),
 (2,'senior-001','judgement reference for agents (not personal proxy)','proj-x',1,'2026-01-05T00:00:00Z');

-- T01 expect=fail[CHECK constraint] 規約 allowed なのに証拠URL/確認日が無い
INSERT INTO service_terms (service,ai_processing) VALUES ('bad_svc','allowed');

-- T02 expect=fail[CHECK constraint] A2 クラスは確信度で解除できない(min_confidence<1)
INSERT INTO decision_class (code,reversibility,authority,min_confidence,max_wrong_rate) VALUES ('c_bad','R2_irreversible','A2_human_only',0.5,0);

-- T03 expect=fail[service terms not verified] 規約が unverified の Slack ソースは full で取り込めない
INSERT INTO source (kind,service,trust_tier,consent_id,handling,redaction_done,ingested_at) VALUES ('chat','slack','third_party',1,'full',1,'2026-02-01T00:00:00Z');

-- T04 expect=fail[service terms not verified] restricted(GitHub PR) も法務確認が済むまでは取り込み不可
INSERT INTO source (kind,service,trust_tier,consent_id,handling,redaction_done,ingested_at) VALUES ('pr_review','github_pr','third_party',1,'full',1,'2026-02-01T00:00:00Z');

-- T05 expect=ok 自前 repo_docs + 同意あり + ローカル処理 は full で取り込める(source 1)
INSERT INTO source (id,kind,service,trust_tier,consent_id,handling,processor,redaction_done,ingested_at) VALUES (1,'adr','repo_docs','human_authored_verified',1,'full','local',1,'2026-02-01T00:00:00Z');

-- T06 expect=fail[full handling needs active consent] 外部LLMで処理するのに外部LLM同意が無い(consent 1)
INSERT INTO source (kind,service,trust_tier,consent_id,handling,processor,redaction_done,ingested_at) VALUES ('adr','repo_docs','human_authored_verified',1,'full','external_llm',1,'2026-02-01T00:00:00Z');

-- T07 expect=ok 外部LLM同意のある consent 2 なら external_llm でも取り込める(source 2)
INSERT INTO source (id,kind,service,trust_tier,consent_id,handling,processor,redaction_done,ingested_at) VALUES (2,'adr','repo_docs','human_authored_verified',2,'full','external_llm',1,'2026-02-01T00:00:00Z');

-- T08 expect=fail[human re-identification review] 同意が無いソースを匿名化だけで取り込むには、再識別リスクの人手確認が要る
INSERT INTO source (kind,service,trust_tier,handling,redaction_done,ingested_at) VALUES ('adr','repo_docs','third_party','anonymized_only',1,'2026-02-01T00:00:00Z');

-- T09 expect=ok 人手確認つきの anonymized_only は取り込める(source 3)
INSERT INTO source (id,kind,service,trust_tier,handling,redaction_done,anonymization_reviewed_by,ingested_at) VALUES (3,'adr','repo_docs','third_party','anonymized_only',1,'lead-001','2026-02-01T00:00:00Z');

-- T10 expect=ok 同意の無い Slack ソースは既定で excluded として台帳にだけ残る(source 4)
INSERT INTO source (id,kind,service,trust_tier,handling,ingested_at) VALUES (4,'chat','slack','third_party','excluded','2026-02-01T00:00:00Z');

-- T11 expect=ok 候補エントリ 1 (lead-001 の判断、proj-x)
INSERT INTO memory_entry (id,class_code,decider_alias,topic_key,choice,statement,scope,valid_from,extraction_run,created_by) VALUES (1,'c_dep','lead-001','dep-policy','pin_exact','pin exact versions of direct dependencies','proj-x','2026-03-01','run-001','agent:extractor');

-- T12 expect=fail[entries must be inserted as candidate] INSERT で status=approved を直接指定する経路を拒否
INSERT INTO memory_entry (class_code,decider_alias,topic_key,choice,statement,scope,status,valid_from,extraction_run,created_by) VALUES ('c_dep','lead-001','dep-policy','ranges','use ranges','proj-x','approved','2026-03-01','run-001','agent:extractor');

-- T13 expect=fail[no signed approval] 署名付き承認なしに UPDATE で approved にする経路を拒否
UPDATE memory_entry SET status='approved' WHERE id=1;

-- T14 expect=fail[illegal status transition] candidate から expired への不正な遷移
UPDATE memory_entry SET status='expired' WHERE id=1;

-- T15 expect=fail[evidence: source excluded or revoked] excluded ソースは証拠にできない
INSERT INTO evidence VALUES (1,4,'q');

-- T16 expect=fail[named decider] anonymized_only ソースは名前付き判断者に紐づけられない
INSERT INTO evidence VALUES (1,3,'q');

-- T17 expect=ok 通常の証拠(source 1)
INSERT INTO evidence VALUES (1,1,'pin exact versions');

-- T18 expect=ok 匿名の候補エントリ 2(判断者なし)に anonymized_only ソースを紐づけられる
INSERT INTO memory_entry (id,class_code,decider_alias,topic_key,choice,statement,scope,valid_from,extraction_run,created_by) VALUES (2,'c_dep',NULL,'lockfile','commit_lockfile','commit lockfile','proj-x','2026-03-01','run-001','agent:extractor');
INSERT INTO evidence VALUES (2,3,'commit lockfile');

-- T19 expect=fail[less conservative] A2 クラスで proceed を申告
INSERT INTO ai_decision (task_id,class_code,scope,confidence,action,decided_at) VALUES ('t-a2','c_budget','proj-x',0.99,'proceed','2026-04-01T00:00:00Z');

-- T20 expect=fail[less conservative] R2 で確信度が閾値以上のとき park_task(表は escalate)
INSERT INTO ai_decision (task_id,class_code,scope,confidence,action,decided_at,question) VALUES ('t-r2','c_deploy','proj-x',1.0,'park_task','2026-04-01T00:00:00Z','deploy?');

-- T21 expect=fail[less conservative] R0 で確信度 < 閾値なのに proceed
INSERT INTO ai_decision (task_id,class_code,scope,confidence,action,decided_at) VALUES ('t-r0','c_dep','proj-x',0.5,'proceed','2026-04-01T00:00:00Z');

-- T22 expect=fail[CHECK constraint] proceed_with_assumption で巻き戻し手順が無い
INSERT INTO ai_decision (task_id,class_code,scope,confidence,action,decided_at,question,default_taken) VALUES ('t-r0','c_dep','proj-x',0.5,'proceed_with_assumption','2026-04-01T00:00:00Z','q','d');

-- T23 expect=ok R0 低確信 → proceed_with_assumption。review_queue 行がトリガで作られる(ai_decision 1)
INSERT INTO ai_decision (id,task_id,class_code,scope,confidence,action,decided_at,question,default_taken,rollback_plan) VALUES (1,'t-r0','c_dep','proj-x',0.5,'proceed_with_assumption','2026-04-01T00:00:00Z','Pin or range?','pin_exact','revert lockfile commit');

-- T24 expect=ok R2 低確信は park_task、A2 は escalate(ai_decision 2,3)
INSERT INTO ai_decision (id,task_id,class_code,scope,confidence,action,decided_at,question) VALUES (2,'t-r2','c_deploy','proj-x',0.4,'park_task','2026-04-01T00:00:00Z','Deploy to prod?');
INSERT INTO ai_decision (id,task_id,class_code,scope,confidence,action,decided_at,question) VALUES (3,'t-a2','c_budget','proj-x',0.99,'escalate','2026-04-01T00:00:00Z','Approve spend?');

-- T25 expect=ok 高確信 R0 は proceed(キュー行は作られない)(ai_decision 4)
INSERT INTO ai_decision (id,task_id,class_code,scope,confidence,action,decided_at) VALUES (4,'t-ok','c_dep','proj-x',0.95,'proceed','2026-04-01T00:00:00Z');
