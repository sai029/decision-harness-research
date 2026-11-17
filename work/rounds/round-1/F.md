# Round 1 / F（評価・プライバシー/権限・運用）— 再調査版（v2）

出典IDは `notes/sources.md`（F01〜F31。他担当の A/B/C/D 系も参照）。
凡例: 【実行】= 私がこのラウンドで実際に走らせて結果を得たもの（ログのパスを付す）。【確認】= 一次情報を取得して読んだ。【推測】= 私の設計判断・外挿。法務は助言ではなく論点整理で、実運用前に法務確認が要る。
実行物（すべて `work/ddl/`。合成データのみ。`python -I` で実行）:
- `f_schema.sql`（DDL）/ `f_test.sql`（署名不要の SQL テスト）/ `f_run.py`（全テスト実行）/ `f_approval.py`（署名・検証）/ `f_sweep.sql`（キュー期限処理）/ `f_run.log`（実行ログ: PASS=70 FAIL=0）
- `f_eval.py` + `f_eval.log`（集計・閾値決定・持ち帰りガードの自己検証）
- `f_exp.py` + `f_exp_out/` + `f_exp_score.log`（合成2判断者の注入あり/なし実験）
- `f_cc_run.py` / `f_cc_hook.py` + `f_cc_run.log` / `f_cc_run_bare.log`（実際の Claude Code セッションでの PreToolUse deny）

## 1. 要約（10行以内）
- E2: 承認を「人間の SSH 署名（ssh-keygen -Y sign、Git の SSH 署名と同じ検証方式）」に結びつけた。INSERT 経路を含む偽造・内容すり替え・リプレイ・作成者自己承認・権限外 scope は全て拒否【実行 f_run.log B1〜B13, T12/T13】。DB に書込み権限を持つ内部者が偽の検証関数を登録して第1層を破っても、読み出し側の署名再検証（第2層）で偽造行が落ちる【実行 B12】。
- E9: 優先規則を1つに統一（P0 適用範囲 → P1 mandatory → P2 scope の深さ → P3 同一判断者の新旧 → P4 その scope での権限 → P5 決まらなければ矛盾チケット）。上司 vs 先輩、global vs project、mandatory、新旧、部署違い、同位、兄弟 scope の7シナリオを実行【実行 D1〜D8】。矛盾チケット表あり。未解決の間は proceed を DB が拒否。
- E7: 動作表（A2/R2/R1/R0×確信度）を ai_decision の BEFORE INSERT トリガで強制し、質問キューを `review_queue` の1本の仕様（誰が書く/読む/期限切れで誰が責任）にした【実行 T19〜T25, E7a〜h】。実際の Claude Code 2.1.302 で PreToolUse deny が発火し、エージェントが別タスクへ進んだ（n=1、2条件）【実行 f_cc_run*.log】。
- E10: PPC 注意喚起の PDF 本文を読んで逐語引用【確認 F18】。Slack・GitHub の規約を一次で確認（F19〜F22）。結論は「Slack API データの LLM 利用は禁止条項があり、文脈内利用の可否は不明 → 法務確認まで取り込まない」。同意が取れない・規約未確認のソースは DDL 上 `excluded`（既定）か `anonymized_only`（人手の再識別確認つき）にしかならず、同意撤回は失効を伝播する【実行 T03〜T10, C1〜C4】。
- E5: Pallet Memory-Bench（ベンダー自己計測 22%→62%）を一次で読み、弱さを台帳化（F16/F17）。自前の最小実験（合成2判断者×12ケース×k=2、1モデル）で no_memory 0.50 / rule_default 0.50 / shuffled 0.00 / full 1.00【実行 f_exp_score.log】。ただし玩具で天井に張り付いており、効果の大きさの根拠にはならない（§5）。
- E6: 実データ評価は「プライベート環境で同じ `f_eval.py` を回し、`aggregate.json`（数値のみ、`export_guard` 検査済み）だけ持ち帰る」設計。閾値は定数ではなく手順の出力（既定は自律化なし）。合成で `shuffled_memory` が機能する最小例を示した（上記）。
- E1: F の必須要件（consent・source・trust_tier・eval ほか）を §3.1 に列挙し、F 旧列→F v2→統合スキーマ v1(A) の対応表と、v1 に足りない点を挙げた。
- 効果の定量根拠は依然として弱い（ベンダー自己計測1件＋自前の玩具）。設計は「効くと分かった」ではなく「効果を測れる仕組みを先に置く」ものとして読むこと。

## 2. E の指摘への回答（番号別）

### E1（F の必須要件の明示）— 解消（F 側）／統合 DDL への反映は A 側で未了
- 条件「F の consent・source・trust_tier・eval を含める」→ §3.1 の R-F1〜R-F9 に列挙。
- 条件「旧列→新列の対応表」→ §3.1 の対応表（F 旧 → F v2 → `work/ddl/unified_schema.sql` v1）。
- 条件「統合版 DDL の実行ログ」は A の担当。私が読んだ `unified_schema.sql`（579行、読了時点）は consent / source(trust_tier, ingest_state) / eval_case / eval_result を既に持つ。足りないものは §3.1 末尾に列挙（要追加 8 点）。A が更新中の可能性があり、読んだ版は最新でないかもしれない。
- 私の `f_schema.sql` は F 単独で通る（実行ログあり）。統合へはマージ作業が残る。

### E2（承認の強制、F のトリガ部分）— 解消（INSERT 経路を含む拒否ログあり）。残る限界は §5
条件1「承認の主体を DB の外の検証可能な事実に結びつける」→ 承認 = 承認者の SSH 秘密鍵による署名（署名対象は `entry_id|content_hash|epoch|approver|approved_at`）。検証は公開鍵（allowed_signers）だけで足りる（F24, F25）。エージェントは秘密鍵を持たない。
条件2「偽造した INSERT/UPDATE が拒否される実行ログ（INSERT 経路を含む）」→ 下表（`f_run.log` から。すべて【実行】）。

| 試験 | 経路 | 結果 |
|---|---|---|
| T12 | `INSERT memory_entry ... status='approved'` | 拒否: `entries must be inserted as candidate` |
| T13/B5 | `UPDATE status='approved'`（承認行なし） | 拒否: `approve: no signed approval for current content/epoch` |
| B2 | 承認行 INSERT: lead-001 を名乗り別人の鍵で署名 | 拒否: `approval: bad signature` |
| B3 | 承認行 INSERT: 署名が空 | 拒否: `bad signature` |
| B4 | 承認行 INSERT: approver 表に無い agent-x を名乗る | 拒否: `approver is inactive or has no authority` |
| B6 | 署名後に statement を差し替え、旧ハッシュで承認行 INSERT | 拒否: `entry hash/epoch mismatch` |
| B7 | 本物の署名だが権限の無い scope の承認者 | 拒否: `no authority` |
| B8 | 作成者による自己承認 | 拒否: `creator cannot approve own entry` |
| B9 | approved の内容を UPDATE | 拒否: `approved entry is immutable` |
| B10 | 承認→隔離→candidate に戻し、旧署名で再承認（リプレイ） | 拒否（epoch が上がり旧署名は無効） |
| B11 | 検証関数を登録していない素の接続での承認 INSERT | 拒否（`no such function`、fail closed） |
| B12 | 内部者が「常に1を返す偽 verify_sig」を登録し、さらにトリガを DROP して直接 approved にした DB | DB 上の有効集合 [1,2,4] → **署名再検証後 [1]**。偽造した 2,4 は注入されない |
| B13 | candidate が `supersedes_id` を持つ／未承認の置換側で旧を superseded に | 旧は approved のまま。拒否: `supersede only by an approved entry`。置換側が署名付きで approved になって初めて旧が superseded |
| E7d/e | 質問キューの回答の偽造（他人の鍵／署名なし） | 拒否: `answer: bad signature` |

2層の役割（【推測】だが B11/B12 で挙動は実行確認）:
- 第1層（DB トリガ）: 善意の誤用と、検証関数を持たない gateway 外の接続を止める。DB ファイルに書込み権限がある主体には無力（B12: 偽関数・DROP TRIGGER で破れる）。
- 第2層（読み出し側 `f_approval.verified_effective`）: DB の status を信用せず、注入のたびに approval の署名を公開鍵で再検証する。DB を直接書き換えられても偽造行は注入されない。
- A の統合スキーマ v1 は承認の証明に HMAC（`proof_mac`、鍵は承認サービスだけ）を使う。私は非対称署名を推す。理由【推測】: MAC は検証側（フックやエージェントが動く端末）が鍵を持てば偽造もできる。署名は検証側が公開鍵しか持たないので、検証経路を増やしても偽造力が増えない。ただし、どちらも「鍵の保管」が弱点になる（§5）。
- 「Git の PR マージ者を唯一の書込み経路にする」案は、承認者がマージコミットに SSH 署名し、CI が署名を `approval` 行に写す形で実現できる（`gpg.ssh.allowedSignersFile` が同方式: F25）。この CI 経路は【未実装・未実行】。

### E5（効果の定量根拠）— 部分解消（既存報告の検討と台帳化は完了。自前実験は玩具で、効果量の根拠にならない）
- 条件1「既存の定量報告を一次情報で検討し、弱さを明記して台帳に載せる」→ F16/F17。弱さ（F17 より）:
  - ベンダー自己計測。データ・コードの公開先が記載なし。信頼区間は未報告。
  - 記憶が効きそうなケースを意図的に多めに抽出（「母集団率ではない」と自称）。本番では履歴が使えるのは約22%の介入。
  - 見出しの 22%→62% は、争いのあるケース・不明・銀（silver）ラベルを除いた44件。除かない場合は 18%→54%（同ページの記載）。
  - full-context 比較では記憶の上積みは +14〜15pt に縮む。1決定点のみの評価。理由づけ設定がモデルごとに違う（Claude 系は拡張思考なし）。
  - 記憶の中身は運用手順・過去の実行・人間が直した事例で、「個人の設計判断」ではない。本プロジェクトの判断記録に直接当てはめられない。
  - 一致の測り方は人間オペレータの解決との完全一致で、F §2.1 の一致率と同種（ただし shuffled 対照も再テスト天井も無い）。
- 条件2「自前の最小実験（合成、n 明記）で注入あり/なしの差を1つ」→ §3.5.2。【実行】結果: プール24判断（12ケース×2判断者）で no_memory 0.50、full_memory 1.00、純増 0.50（95%CI [0.29, 0.63]、ケース単位ブートストラップ）。
- 残る弱さ（自己評価）: 天井に張り付く玩具、1モデル、ルールが明示的で一貫、判断者2人とも決定論ルール。効果の大きさの根拠にはならず、「測定の枠が動く」「腕の差が出る場合と出ない場合がある」ことの確認に留まる。

### E6（評価の人間ラベル入手経路）— 解消（設計）。実データでの検証は未実施
- 条件1「リポジトリの外のプライベート環境で、同じスクリプトを回す（入出力契約、集計値だけ持ち帰る）」→ §3.5.3。`f_eval.py` に契約を書き、`export_guard` が数値・真偽・null と列挙値以外（自由文・未知キー）を拒否することを【実行】で確認（f_eval.log）。
- 条件2「合成データで shuffled_memory が機能する最小例」→ §3.5.2。合成の2判断者 P/Q（逆のルール）で、P の記録を Q のケースに与える shuffled 腕は一致率 0.00（no_memory 0.50、full 1.00）。一般常識ではなく個人の判断を読んでいることの切り分けになる。
- 条件3「閾値 0.8/0.5（A）、k、割合を、実データが無くても進められる形に直す」→ §3.5.4。定数を置かず、手順（クラスの許容誤り率 → 較正セットの二項上側限界 → 格子上の最小閾値）の出力にする。実データが無い間は閾値=1.0（自律化なし）が既定。手順の被覆は合成で検証済み。A の 0.8/0.5 は根拠が見つからず、私は検証できない。k は決められなかった（§5）。

### E7（動作表・review_queue 部分）— 解消（F の担当範囲）。D 側のフック設計の網羅は D が担当
- 条件1「実際に Claude Code セッションで PreToolUse deny が発火し、作業が別タスクへ進む様子のログ（合成タスク）」→ §3.4.3。【実行】2条件とも deny 発火→`ai_decision(park_task)`＋`review_queue #1` 作成→別タスク完了。
- 条件2「質問キューの単一仕様（誰が書き、誰が読み、期限切れの扱い）」→ §3.4.2。C の `open_question` と F の `review_queue` は1本にする（A の統合 v1 も同じ方針で `review_queue` に1本化している）。
- E の補足事実（hooks の `args` 形式、subagent 内でも発火し `agent_id` が入る）: 私の実行では `args` 形式の設定がそのまま動いた（Claude Code 2.1.302、Windows、`command` は python.exe）。`agent_id` は主セッションでは null だった（`hook.log`）。subagent 内の発火は私は試していない（E の記述を引用するに留める）。

### E9（優先規則・矛盾）— 解消（1規則＋DDL＋合成7シナリオ＋決まらない場合の動作）
→ §3.3。A（権限＞新しさ＞確信度）・C（scope 違いは supersede しない）・F（権限、新しさ、具体性）の3者の順序を、scope の木を使う1規則に統一した。大域ランクは使わない。

### E10（プライバシー・法務の一次確認）— 部分解消（PPC 本文、Slack/GitHub 規約、同意が取れない場合の DDL 反映は完了。Teams と改正個情法の一次は未了）
- 条件1「PPC の一次資料（PDF 本文）の該当箇所を引用」→ §3.6.1（逐語引用、F18）。
- 条件2「主要サービス2〜3社の規約の AI 処理条項の確認（一次、URL と取得日）」→ Slack（F19, F20, F21）、GitHub（F22）、Anthropic 商用規約（F30、送信先側）。Teams/Microsoft は未取得（§5）。いずれも WebFetch の要約モデル経由で、逐語・条番号は未照合。
- 条件3「同意が取れないソースの扱い（取り込まない／匿名化のみ）を DDL の状態に反映」→ `source.handling ∈ {excluded, anonymized_only, full}`、既定 `excluded`。§3.6.2。

## 3. 提案

### 3.1 F の必須要件（統合スキーマへ）— E1

各行: 要件 → 場所（F v2 の DDL）。根拠は 【実行】f_run.log / 【推測】。

| # | F の必須要件 | 内容（列・列挙値） |
|---|---|---|
| R-F1 | consent | `consent(id, subject_alias, purposes, scope, external_llm_allowed, granted_at, withdrawn_at)`。目的は「個人の代理ではなく記録された基準の参照」と明記。撤回で `trg_consent_withdraw` が source を excluded+revoked にし、証拠が全て失効した記録を `revoked` にする（C1〜C4） |
| R-F2 | source の取り込み可否 | `source.handling ∈ {excluded(既定), anonymized_only, full}`、`processor ∈ {local, external_llm}`、`redaction_done`、`anonymization_reviewed_by`。full は有効な consent（外部LLMなら external_llm_allowed=1）が要る。anonymized_only は人手の再識別確認が要り、名前付き判断者に紐づけられない（T03〜T10, T15, T16） |
| R-F3 | 規約の確認状態 | `service_terms(service, ai_processing ∈ {allowed, restricted, prohibited, unverified}, checked_at, evidence_url)`。allowed 以外のサービスのソースは excluded 以外にできない。allowed には確認日と URL が必須（T01, T03, T04） |
| R-F4 | trust_tier | `source.trust_tier ∈ {human_authored_verified, human_authored_unverified, third_party, agent_asserted}`。`kind='agent_trace'` は agent_asserted 固定（CHECK）。**権限の根拠ではない**（偽称されうる）。承認者への表示と隔離の補助。承認の真正性は署名で決まる |
| R-F5 | 承認 | `approval(entry_id, entry_hash, epoch, approver_alias, approved_at, sig)`。署名検証＋内容ハッシュ一致＋承認者の scope 権限＋作成者≠承認者。読み出し側の再検証（§2 E2） |
| R-F6 | 判断の種類別ポリシー | `decision_class(reversibility R0/R1/R2, authority, min_confidence 既定1.0, max_wrong_rate, default_ttl_days, queue_ttl_hours, renotify_hours)`。人間専用クラスは確信度で解除できない（CHECK）。R2 は閾値が 1.0 の間は常に escalate |
| R-F7 | 構造化された結論と scope 木 | `decision.topic_key / choice / strength ∈ {default, mandatory}`、`scope_node(scope, parent)`、`scope_authority(alias, scope, level)`。矛盾検出と優先規則 P0〜P5 の前提（E9） |
| R-F8 | 動作表と質問キュー | `ai_decision(scope, topic_key, question, default_taken, rollback_plan)` に BEFORE INSERT トリガ（申告 action ≥ 表の action）。`review_queue(owner, escalated_to, expires_at, on_expire, answer_sig)`（E7） |
| R-F9 | eval | `eval_run(environment ∈ {synthetic, private}, code_version, model, k_samples)`、`eval_case(split ∈ {memory, calibration, test}, human_choice, retest_choice)`、`eval_result(arm ∈ {no_memory, rule_default, shuffled_memory, full_memory}, ai_choice, confidence)`。実データ版はプライベート環境だけに存在し、リポジトリには集計値だけを持ち帰る（§3.5.3） |

**状態遷移（F v2、`entry_transition` 表で強制。T14, B13）**
```
candidate --(署名付き承認)--> approved --(置換側が approved)--> superseded   [終端]
candidate --> quarantined --> candidate (epoch+1)      approved --(valid_until 超過)--> expired --> candidate (再レビュー)
candidate --> revoked   approved --(署名付き取消/同意撤回の伝播)--> revoked   [終端]
approved --(汚染ラン)--> quarantined --> revoked
```
A の v1 は `quarantined→candidate` を「一度でも承認された判断には不可（never_approved）」としている。こちらのほうが単純で安全で、そうなら私の `epoch`（リプレイ防止）は不要になる。A の規則を採用してよい（`expired→candidate` も同様に新しい判断として書き直す）。

**旧列→新列の対応表**

| F 旧（round-1 初版） | F v2（`f_schema.sql`） | 統合スキーマ v1（A, 読了時点） | 備考 |
|---|---|---|---|
| `person_alias(alias, role)` | 同左＋`approver(alias, active)` | `principal(principal_id, kind, role_id)` | kind='human' が approver に相当 |
| `consent.*` | 同左 | `consent.*` | 列名の `_id` 差のみ。一致 |
| `source.kind` | 同左（＋`queue_answer`） | `source.kind`（＋minutes, mail） | queue_answer は「回答＝決定時点の記録」用（E の新規候補1の最小実装） |
| `source.trust_tier` | 同左（agent_trace は agent_asserted 固定） | 同列挙値 | 一致 |
| `source.consent_id/redaction_done/ingested_at/revoked_at` | 同左 | 同左 | 一致 |
| （無し） | `source.service`, `processor`, `anonymization_reviewed_by`, `handling` | `ingest_state ∈ {full, anonymized_only, not_ingested}` | handling.excluded = not_ingested。service/processor/再識別確認は v1 に無い（要追加） |
| （無し） | `service_terms` | 無し | 要追加（R-F3） |
| `decision_class.reversibility`, `authority` | 同左 | `decision_class.floor_agent_mode`（reversibility 列は無い） | 動作表で A0/A1 の差は使っていない。A2 のみ使用 → `human_only` に畳める。reversibility は `decision.reversibility(two_way/costly/one_way/unknown)` と対応: R0=two_way, R1=costly, R2=one_way, unknown は R2 扱い |
| `memory_entry` | 同左（＋topic_key, choice, strength, epoch, created_by） | `decision` | `statement`→`decision_text`、`decider_alias`→`decided_by`、`valid_until/review_after`→`valid_until/review_by`、`supersedes_id`→`decision_link(supersedes)`、`extraction_run`→`extraction_run_id`、`created_by`→`origin` |
| `scope`（文字列） | `scope_node` の木＋`scope_authority` | `scope_project`（global/プロジェクト）＋`authority_grant` | 部署の層が v1 に無い（要追加） |
| `approved_by, approved_at`（初版） | `approval`（署名） | `approval`（HMAC `proof_mac`） | 非対称署名への置換を提案 |
| `evidence` | 同左 | `evidence`（＋role, quote_verified, quote≤300字） | 一致。引用上限は E12 対応として v1 のほうがよい。採用 |
| `ai_decision` | 同左＋`scope, topic_key, question, default_taken, rollback_plan` | `ai_decision`（scope 等なし） | 要追加。動作表トリガに scope/topic が要る |
| `review_queue`（初版） | `review_queue`（owner, escalated_to, answer_sig） | `review_queue`（assignee_role, on_expire, escalated_to_role） | v1 の `on_expire` 列（行ごとに confirm_default / continue_and_renotify / stay_parked）は私のクラス別規則を明示化したもので、採用。`defaulted`=v1 の `expired`+confirm_default |
| `eval_case/eval_result/v_agreement` | 同左＋`eval_run` | 同左（eval_run なし） | eval_run 要追加 |
| `v_blast_radius` | 同左 | 無し（未確認） | 要追加 |
| `conflict_ticket`（初版: 無し） | `conflict_ticket(class_code, topic_key, entry_a, entry_b, reason, status)` | `conflict_ticket(a_id, b_id, reason, state)` | class/topic は私のほうが多い。v1 で足りる場合は v1 を採用 |

**統合スキーマ v1 に足りない点（要追加 8 点）**: (1) `service_terms`＋source の service/processor/anonymization_reviewed_by、(2) scope の木（部署層）と scope 別権限、(3) `topic_key/choice/strength`、(4) 優先規則 P0〜P5 と scope 別の有効集合（`v_effective_by_scope`）、(5) 動作表トリガ（ai_decision の scope/topic 列とともに）、(6) 読み出し側の署名再検証（A の `verify_proof` を読み出しにも使う）、(7) `eval_run`、(8) `v_blast_radius`。
また A の v1 の `CHECK (ingest_state <> 'full' OR consent_id IS NOT NULL OR kind = 'adr')` は、名前付き判断者の ADR を同意なしで full 取り込みできる。F の見解は「ADR でも名前付きなら同意（または公開文書であることの確認）を要する」。法務確認が済むまで例外を外すことを勧めるが、決めるのは A と人間（未解決 §5）。

### 3.2 承認の強制（E2）
実装: `f_schema.sql`（`approval`、`trg_approval_verify`、`trg_entry_approve`、`trg_entry_insert_candidate`、`trg_entry_immutable`、`trg_entry_epoch*`）、`f_approval.py`（`sign` / `verify` / `register` / `verified_effective`）。
- 署名は `ssh-keygen -Y sign -n decision-approval`、検証は `ssh-keygen -Y verify -f allowed_signers -I <承認者> -n decision-approval`。allowed_signers は DB の外（リポジトリの CODEOWNERS 保護下のファイル等）に置く。
- 検証関数 `verify_sig` はアプリ側で接続に登録する。未登録の接続ではトリガが失敗する（B11、fail closed）。
- 根拠: F24, F25（方式）、F02（complete mediation: 許可判断を LLM でなく下流で行う）、【実行】B1〜B13。確認できた/推測: 拒否の挙動は実行確認。「この方式で運用が回る（承認者が署名を面倒がらない）」は推測。
- 破綻しうる条件: (a) 承認者の秘密鍵をエージェントと同じ OS ユーザーが読める（鍵が盗まれる）。(b) allowed_signers を書き換えられる。(c) 承認者が内容を見ずに署名する（承認疲れ、§5）。(d) 署名検証に ssh-keygen を使うため、注入のたびに N 件分のプロセス起動が要る（件数が数百を超えるなら検証結果のキャッシュ、または Python の Ed25519 実装への置換が要る。件数ごとの遅延は未測定）。

### 3.3 優先規則と矛盾（E9）
実装: `f_schema.sql` の `scope_node`, `scope_authority`, `v_scope_closure`, `v_authority`, `v_pair`, `conflict_ticket`, `v_effective_by_scope`、`trg_conflict_open/close`、`trg_decision_action`（未解決矛盾があるトピックでは proceed 禁止）。テスト: `f_run.py` Part D。

**単一の優先規則**（上から順、最初に決まった段で止める）
- P0 適用範囲: 2件の scope が祖先-子孫（同一を含む）の関係にあるときだけ競合。兄弟 scope は競合しない。
- P1 `mandatory` 対 `default`: mandatory が勝つ（上位の「守るべき制約」は下位で覆せない）。
- P2 scope の深さが違う: default 同士は深い（具体的な）方。mandatory 同士は浅い（広い）方。
- P3 同一 scope・同一判断者: `valid_from` が新しい方（本人の改訂）。
- P4 同一 scope・別判断者: その scope での権限 level（`scope_authority`、祖先から継承）が高い方。片方でも権限が無い、または同位なら決めない。
- P5 決まらない: `winner=NULL` → `conflict_ticket` を開く。両方を注入から外し、そのトピックの proceed を DB が拒否（proceed_with_assumption＋キュー）。人間がどちらかを revoke/supersede するとチケットが自動で閉じる。

**合成シナリオ結果**【実行】（`f_run.log` D1〜D8）
| # | シナリオ | 規則 | 結果 |
|---|---|---|---|
| D1 | 上司（dept-a の level3、proj-x に継承）vs 先輩（proj-x の level1）、同一 scope | P4 | 上司が有効 |
| D2 | global の default vs proj-x の default | P2 | proj-x では proj-x の判断、**proj-y では global が有効のまま**（scope 別評価） |
| D3 | global mandatory vs proj-x default | P1 | global が有効 |
| D4 | 同一判断者の新旧 | P3 | 新しい方 |
| D5 | 部署違いの先輩同士（global scope、どちらも global に権限なし） | P5 | チケットが開き、両方が注入から外れる。conf 0.95 の proceed は拒否、proceed_with_assumption は通る。別トピックは影響なし。片方を revoke するとチケット resolved、残りが復帰 |
| D6 | 同位の別判断者（同一 scope） | P5 | 決めずにチケット |
| D7 | 兄弟 scope（proj-x と proj-y）の同一トピック | P0 | 競合なし、各々有効 |
| D8 | candidate（新しい）が approved を失効させるか | — | させない（pair は approved 同士のみ） |

- 根拠: A の `v_precedence`・C の scope 方針・F 初版の3者の食い違い（E9）。法令の「上位法優先・特別法優先・後法優先」に似た構造だが、これは類推で出典は取っていない【推測】。規則そのものの正しさ（上司が先輩に常に優先か）は組織で違う。変えるのは `scope_authority` と P4 の1行。
- 破綻しうる条件: (a) `topic_key` を抽出器が揃えられない（同じ論点が別キーになり矛盾が検出されない。未測定）。(b) 三者以上の連鎖矛盾（ペアごとの判定で循環しうる。未検証）。(c) 権限付与表の保守が止まる。(d) 取り消した置換側が出ても、旧判断は自動復活しない（人間が新エントリで書き直す必要がある。§5）。

### 3.4 動作表と質問キュー（E7）
**3.4.1 動作表**（`trg_decision_action` が強制。申告した action は表の action 以上に保守的でなければならない）【実行】T19〜T25
| 条件 | action |
|---|---|
| 人間専用クラス（A2） | escalate（確信度で解除不可） |
| R2 かつ conf < 閾値 | park_task |
| R2 かつ conf ≥ 閾値 | escalate（閾値が 1.0 の既定では常にこちら） |
| R0/R1 かつ conf < 閾値、または未解決矛盾あり | proceed_with_assumption（default_taken と rollback_plan が必須: CHECK） |
| それ以外 | proceed |

**3.4.2 質問キューの単一仕様**
| 項目 | 仕様 |
|---|---|
| 誰が書くか | エージェントは `ai_decision` を書く。`trg_queue_create` が `review_queue` 行を作る（エージェントが直接書く経路を主にしない）。責任者は scope の木で最も近い level≥2 の人（`v_responsible`） |
| 誰が読むか | 人間: `v_queue_by_owner`（担当者、またはエスカレーション後はその先）。責任者が決まらない scope は `v_queue_unowned` に出る（実行確認）。エージェント: タスク切替時と SessionStart に `v_queue_answers_for_agent` を読み、回答済み・確定済みを取り込む |
| 誰が答えるか | 責任者候補（`v_responsible` 上の approver）の署名付き回答だけ（偽造・署名なし・責任者でない人は拒否: E7d/e/f）。回答は `source(kind='queue_answer')` として決定時点の記録にしてよい |
| 期限切れ（`f_sweep.sql`） | R0: 既定を確定（`defaulted`）。R1: 既定のまま継続し再通知＋1段上へエスカレーション。R2/A2: 駐車のまま再通知＋エスカレーション。`renotify_hours` ずつ期限を延長 |
| 期限切れの責任 | 担当者（`owner_alias`）→ 期限切れごとに `escalation_level+1` で次の責任者（`escalated_to`）。実行確認: R2 の park は boss-001 へ（E7b）。最上位でも答えが無い場合の動作は未設計（§5） |
| 回答が既定と違う | `human_outcome='overturned'`。`v_overturn_impact` が仮定に依存した成果物（`decision_use.artifact`）を列挙。R0 の確定後の遅い回答でも記録される（E7h） |

**3.4.3 実際の Claude Code セッションでの発火**【実行】`f_cc_run.py`（Claude Code 2.1.302、`claude -p --model sonnet`、`--settings` で PreToolUse フックを指定、作業ディレクトリは一時の git リポジトリ。タスク: A=`git push origin main`、B=`notes.txt` 作成）
- 条件1（「ブロックされたら再試行せず続行」の指示あり、`f_cc_run.log`）: `Bash(git push origin main)` → 結果 `PreToolUse:Bash hook error: Irreversible command parked (review_queue #1). Do NOT retry...`（is_error=true）→ `Write(notes.txt)` 成功 → 最終応答 `A: pending | B: done`。`ai_decision(park_task, c_deploy)` と `review_queue #1`（責任者 lead-001、open、期限 +24h）が DB に作られた。
- 条件2（指示なし、`f_cc_run_bare.log`）: エージェントは `git push ...; printf ... > notes.txt` を1コマンドにまとめて送り、**コマンド全体が deny**。エージェントは push を再試行せず、B だけを再実行して完了。最終 `A: pending | B: done`。
- 観察: (a) フックの理由文が通る（deny 理由はモデルに届く）。(b) 静的規則は複合コマンドを丸ごと止めるので、巻き込みがある。(c) 質問文（`question`）にエージェントのコマンド文字列がそのまま入る。人間の承認画面とエージェントへの再注入では「引用データ」として扱う必要がある（インジェクション経路）。
- 試していないこと: subagent 内の発火、`git -C dir push` や `sh -c` 経由などの迂回、n>1。フックの分類は静的規則のみで AI の分類は使っていない。
- 根拠: F02, F05, F06（強制は CLAUDE.md ではなくフック）、E-review の hooks 確認（D-S01）、【実行】。破綻しうる条件: 規則の取りこぼし（迂回）、フックのタイムアウト・障害時の既定（fail open か closed か未検証）。

### 3.5 評価（E5・E6）
**3.5.1 手順**（初版 §2.1 を維持。変更点のみ記す）
- 一致率 = AI選択 == 人間選択（選択肢型のみ）。純増 = full − max(no_memory, rule_default) を**クラス別・判断者別**に出す（§3.5.2 で、判断者によって純増が 0 になる例が出た）。
- 確信度の複合値の (b)「k 回サンプリング間の選択の一致」は、私の実験では同じ入力の2回の run が 24/24 全て同一で（f_exp_out, 5腕）、情報を持たなかった。サンプリング設定は `claude -p` の既定で、温度は未確認。したがって (b) は温度を上げた設定で再測定するまで確信度に入れない。
- 閾値の手順は §3.5.4。報告は点推定でなくブートストラップ区間。

**3.5.2 合成2判断者の最小実験**【実行】`f_exp.py`、`f_exp_score.log`（モデル: `claude -p --model sonnet`、ツール無効。正確なモデル ID は未記録）
- 設計: 合成の判断者 P と Q が、3つの判断ファミリ（依存ライブラリ／公開方法／対応順）で**逆の**隠れたルールを持つ（P は依存が少ない方・段階公開・影響が大きい順、Q は人気の定番・一括切替・安い順）。12ケース（各ファミリ4）を A/B の2択で出す。正解は決定論ルールで決まる。各判断者に過去記録6件（各ファミリ2件）。選択肢の位置は手作業の固定割付。1プロンプトに12ケースを入れ、腕ごとに k=2 回実行。
- 腕: no_memory／rule_default（「一般的なベストプラクティスに従え」）／shuffled_memory（もう一人の記録）／full_memory／（追加）full_memory_noreason（理由なし、選択だけの記録）。
- 結果（24判断=12ケース×2判断者、k=2 の平均）:

| 腕 | P | Q | プール | 95%CI（ケース単位ブートストラップ） |
|---|---|---|---|---|
| no_memory | 1.00 | 0.00 | 0.50 | [0.29, 0.71] |
| rule_default | 0.75 | 0.25 | 0.50 | [0.29, 0.71] |
| shuffled_memory | 0.00 | 0.00 | 0.00 | [0.00, 0.00] |
| full_memory | 1.00 | 1.00 | 1.00 | [1.00, 1.00] |
| full_memory_noreason | 1.00 | 1.00 | 1.00 | [1.00, 1.00] |

  純増（arm 平均、full − max(no_memory, rule_default)）: プール +0.50（95%CI [0.29, 0.63]）。判断者別: P は 0.00（モデルの既定の癖が P の好みと一致）、Q は +0.75。
- 読み取れること【実行の範囲】: (1) 判断者によって記憶の純増は 0 から大きな値まで変わる → 純増は判断者・クラス別に測る。(2) 逆のルールの2人をプールすると、記憶を使わない方針は機械的に 0.5 に落ちる（プールの no_memory 0.50 は「モデルが弱い」ではなく設計の帰結）。(3) shuffled が 0.00 で no_memory(0.50) より低い＝モデルが他人の記録に素直に従った。個人の判断を読んでいることの対照として機能する。(4) 理由なしの記録でも 1.00。
- 読み取れないこと: 実データでの効果量。ルールが明示的で一貫、記録が6件で全ファミリを覆い、判断者は決定論、1モデル、n=24 判断（独立でない: 同一プロンプト内の12ケース、同一ルール）。天井に張り付いているため、記憶が曖昧・矛盾・古い場合の劣化は測れていない。再テスト天井は決定論ルールなので 1.0（正規化は意味を持たない。実データでは別途測る）。
- 根拠: F07（shuffled に近い demographics-only 対照と再テスト正規化）、F16/F17（比較対象）。破綻しうる条件: 上記の「読み取れないこと」全部。

**3.5.3 プライベート環境での評価（実データ）**
- 場所・主体: 実データ（先輩・上司の判断記録、同意済み）を扱える人間（プロジェクト責任者または同意の管理者）が、アクセス制御された別環境（別端末/別アカウント、リポジトリの外）で実行する。このリポジトリの規約（実データを入れない）は守られる。エージェントはスクリプトを書くが、実データは見ない。
- 外部 LLM を使う場合: 同意の `external_llm_allowed=1` のソースだけ。送信先の「機械学習に使わない」契約を確認（F18 が求める確認、F30 は商用規約の一例）。使えなければローカルモデル。
- 入出力契約（`f_eval.py` の docstring）: 入力 `cases.jsonl` / `results.jsonl` / `classes.json`、出力 `aggregate.json`。出力は数値・真偽・null と列挙値（腕名・クラスコード）だけ。n<5 のセルは値を伏せる（`MIN_CELL`）。`export_guard` が自由文字列・未知キーを拒否する【実行】f_eval.log。持ち帰る前に人間が目視する。
- 実行・提出の手順: (1) 時系列分割（memory/calibration/test）、(2) 4腕を実行、(3) `python -I f_eval.py --cases ... --out aggregate.json`、(4) `aggregate.json` だけを持ち帰る。
- 限界: 人間のラベル自体が誤りの場合は測れない（一致=良い判断ではない）。overturned 率（運用時）で間接的に見るだけ。再テスト（2週間後の再回答）を取る負担と、先の自分に引きずられる影響は未測定。

**3.5.4 閾値の決め方（実データ無しで進められる形）**【実行】`f_eval.py --selftest`（`f_eval.log`）
- 定数を置かない。クラスごとの許容誤り率 α_c（方針として決める。例: R0=0.10, R1=0.05, R2=0.01 は【推測】の初期案）から、較正セットで「確信度 ≥ t の事例の誤り」の Clopper-Pearson 片側 95% 上側限界が α_c 以下となる最小の t を、格子 {0.50, 0.55, …, 1.00}（11点）上で選ぶ。格子点数 m で Bonferroni（δ/m）。取れなければ t=1.0（自律化しない）。
- 必要件数（誤り0件）: 単一検定で α=0.10 → 29、α=0.05 → 59（実計算）。格子の補正後は α=0.10 → 52、α=0.05 → 106。クラスごとの較正件数がこれ未満なら、そのクラスは自律化しない。
- 検証【実行】: Clopper-Pearson の値は既知値（k=1,n=20 → 0.2161）に一致。較正された合成データ（n=600）で300回反復し、閾値が選ばれた237回のうち、選ばれた領域の真の誤り率が α を超えた回数は 0（Bonferroni で保守的）。n=20 では閾値は選ばれない（自律化なし）。scipy は環境に無く、scipy との照合は未実施。
- 分割割合: 固定しない。較正件数 ≥ 上の必要件数、テスト件数は区間幅から逆算（実データで決める）。k は決められなかった（上記 §3.5.1）。
- A の 0.8/0.5 は根拠が見つからないため、この手順の出力で置き換える提案（A が根拠を示せば比較する）。
- 破綻しうる条件: 合成の世界は確信度が較正されている前提。実際のモデルの確信度は較正されない可能性が高く、その場合は上側限界の保証が崩れる（較正セットと運用の分布が違う場合も）。クラス当たり数十件の想定なので、多くのクラスは自律化しない見込み。

### 3.6 プライバシー・法務（E10）
**3.6.1 PPC 注意喚起（一次）**【確認】F18。PDF（6頁）を本文抽出して読んだ。別添1（１）個人情報取扱事業者における注意点より（逐語）:
- ①「個人情報取扱事業者が生成 AI サービスに個人情報を含むプロンプトを入力する場合には、特定された当該個人情報の利用目的を達成するために必要な範囲内であることを十分に確認すること。」
- ②「個人情報取扱事業者が、あらかじめ本人の同意を得ることなく生成 AI サービスに個人データを含むプロンプトを入力し、当該個人データが当該プロンプトに対する応答結果の出力以外の目的で取り扱われる場合、当該個人情報取扱事業者は個人情報保護法の規定に違反することとなる可能性がある。そのため、このようなプロンプトの入力を行う場合には、当該生成 AI サービスを提供する事業者が、当該個人データを機械学習に利用しないこと等を十分に確認すること。」
- 初版で F04（報道要約）に頼っていた記述は、一次と一致した。別添2は OpenAI への注意喚起（要配慮個人情報の取得・利用目的の通知）で、本システムの設計には直接関係しない。
- 設計への反映: (a) 外部LLMに判断者の発言（個人情報になりうる）を送るなら、利用目的の範囲内か（consent.purposes）、事業者が機械学習に使わない契約か（`service_terms` と `processor`）を DDL で必須にした（T03〜T07）。(b) 「応答結果の出力以外の目的で取り扱われる」場合に当たらないよう、送信先との契約確認を運用に入れる。判断者の発言が個人データに当たるかの解釈は法務確認【未確認】。
- 2026年の改正個情法（統計作成等の特例、F11）は引き続き二次情報（PwC）で、未施行。一次（条文・政令）は未取得。本システムは特定個人の判断を再現するので特例を根拠にしない方針は維持する。

**3.6.2 規約の確認**【確認】WebFetch の要約モデル経由、逐語・条番号は未照合。
| サービス | 確認できたこと | 本設計への含意 |
|---|---|---|
| Slack（F19） | Slack 自身の AI について「顧客データを使用して生成 AI モデルを開発することはありません」。LLM プロバイダは顧客データにアクセスできない | Slack の話であり、顧客が Slack データを自前のエージェントで処理してよいかには答えていない |
| Slack Developer Policy（F20） | 禁止:「Using Data to train an LLM under any circumstances」「sharing Data with third parties under any circumstances」。データの収集・保存には適切な同意が要る | 学習でなく文脈内の取得・参照が該当するかは書かれていない → 法務確認まで `service_terms.ai_processing='unverified'`（取り込まない） |
| Slack ToS 更新（F21, 二次F23） | API データの保存・利用・共有の保護強化。LLM・一括エクスポート制限の解説は二次。一次の API ToS 全文は未取得 | 同上 |
| GitHub（F22） | ユーザーコンテンツはユーザーが所有、GitHub へのライセンス、API の濫用・スパム目的のダウンロード禁止。自社の私的リポジトリや PR レビューを自前エージェントで処理する可否の明示は見つからず | `restricted` 扱い。管理者設定・契約の確認まで取り込まない（T04） |
| 送信先: Anthropic 商用規約（F30） | 「Anthropic may not train models on Customer Content from Services」 | 送信先の学習利用なしの確認材料。DPA・無料/個人向け規約は未確認。別の送信先を使うなら同様の確認が要る |

**3.6.3 同意が取れない場合の DDL 上の扱い**【実行】T03〜T10, T15, T16, C1〜C4
- 同意が無い・撤回・規約が未確認のソースは `handling='excluded'`（既定）。引用（`evidence.quote`）は excluded ソースに紐づけられない（T15）。
- `anonymized_only`: 人手の再識別確認（`anonymization_reviewed_by`）が要り、名前付き判断者に紐づけられない（T08, T09, T16）。【推測】小さなチームでは判断の内容だけで本人が分かるため、匿名化では足りない場合が多い。既定は excluded で、anonymized_only は例外扱い。
- 同意の撤回（退職・本人の希望）: `consent.withdrawn_at` を立てると、ソースが excluded+revoked になり、証拠が全て失効した記録（candidate/approved/quarantined）は `revoked`、置換済みの旧判断は復活しない。`v_blast_radius` で影響する記録・AI判断を列挙（C1〜C3）。派生物（要約・埋め込み・評価セット）の再生成/削除は DDL 外の手順（実装は C 担当との調整事項、未実装）。
- 退職者: 退職時は同意の再確認を既定にする（【推測】運用）。従業員の「同意」が自由な意思に基づくかという論点（雇用関係での同意の有効性）は法務確認【未確認】。同意が取れない場合は取り込まない設計なので、記録が少なくなるコストを受け入れる。
- アクセス制御: 検索は要求主体の権限の scope だけを返す（`v_effective_by_scope(task_scope)`）。エージェントは読み取りが既定、書込みは candidate と ai_decision のみ。

### 3.7 運用（更新承認・矛盾の解決・失効・汚染回復・コスト）— 初版から維持し、更新点のみ
- 更新の承認: §3.2（署名）。内容は判断者本人（または代理で確認できる人）、適用範囲は scope の責任者。別人なら2回承認【推測】。承認画面は根拠引用＋信頼段階＋既存記録との差分を1件ずつ出し、バッチ承認を禁止【推測】。
- 矛盾の解決: §3.3（P0〜P5、チケット）。
- 失効: `valid_until` と `review_after`、クラス別 `default_ttl_days`（初期値は推測）。書き込み時に旧記録を superseded にして検索側で期限内の approved だけを返す（F09: 取得できても行動に反映しない傾向）。承認後にソースが失効した場合は §3.6.3 の伝播（トリガ）。
- 汚染回復: `extraction_run` 単位で一括 quarantined に戻し、評価（§3.5）を再実行して一致率が戻るか確認。quarantined からの復帰は A の `never_approved` 規則（新しい判断として書き直す）を推奨。
- コスト【推測】: 抽出は新規ソースのバッチに限る。評価の呼び出し量は事例数×腕数×k（事前に見積もる。本ラウンドの実験は16+4呼び出し、各数秒）。人間の承認の工数が真のボトルネック。キュー滞留件数と承認までの中央値を運用指標に。

## 4. 検討して棄却した案と理由
（初版の7件に追加）
1. 確信度を LLM の自己申告だけにする: 較正の保証が無い。複合値＋較正セットで検証。ただし k 回サンプリングの一致は今回の設定で情報を持たなかった。
2. 低確信なら全て人間に即質問して待つ: 計画に反する。R2/A2 のみ駐車。
3. ランダム分割のバックテスト: 将来情報が漏れる。時系列分割。
4. LLM 審判で自由記述の一致を採点: 審判の信頼性が未検証。選択肢型のみ。
5. 改正個情法の「統計作成等」特例を根拠に同意を省く: 特定個人の予測は対象外、未施行（F11）。
6. 注入内容の検出器だけで防ぐ: F10 は偽造推論が既存防御を突破、F01 は閾値調整が難しい。権威分離＋権限強制を主に。
7. 単一の固定 TTL: クラス別＋イベントトリガー。
8. （新）承認を `approved_by` の文字列または `NOT NULL` 検査にとどめる: 偽造できる（E2）。署名に置換。
9. （新）HMAC を承認の唯一の証明にする（A の v1）: 検証側が鍵を持てば偽造できる。非対称署名を推す（ただし A の採用判断を妨げない。鍵の保管が弱点なのは両方同じ）。
10. （新）DB トリガだけで承認を守る: DB ファイルへの書込み権限者に破られる（B12）。第2層の読み出し時再検証を併用。
11. （新）大域の権限ランクで優先を決める: 部署違いで決まらない（E9）。scope ごとの権限付与＋scope の木に。
12. （新）優先規則で「新しい方が常に勝つ」: 別判断者の新しい意見が上位者の判断を覆す。新旧は同一判断者の改訂（P3）に限る。
13. （新）判断者の氏名を匿名化すれば同意を省く: 小さなチームでは内容から再識別できる。anonymized_only は人手確認つきの例外に限る。
14. （新）AI による分類で A2 を判定: 静的規則（コマンド・パス）で判定し、AI の分類は引き上げ方向のみ許す（初版維持）。実セッションでは静的規則だけでフックが動いた。
15. （新）E の新規候補2（Anthropic の memory tool `memory_20250818`）: F の担当外のため評価していない。ただし採用するなら `delete`/`str_replace` で記録を AI が書き換えられるため、§3.2 の署名と読み出し時再検証をハンドラ側に実装する必要がある【推測】。

## 5. 未解決・不確実な点
- 効果の定量根拠: ベンダー自己計測（F16/F17）と自前の玩具（§3.5.2）のみ。実データでの効果は未確認。
- 実験の限界: 1モデル、2判断者、12ケース、ルール明示で天井張り付き、独立でない24判断。モデルの正確な ID と温度は未記録。理由なし記録でも 1.00 だったが、これは玩具の易しさの表れかもしれない。矛盾・古い・曖昧な記録で劣化するかは未測定。
- k（サンプリング回数）: 設定上の変動が無く決められない。温度を上げた再測定が要る。
- 承認の鍵保管: 承認者の秘密鍵、allowed_signers、検証関数コードが同じ OS ユーザーから触れる場合の防御は未検証。鍵の失効・ローテーション、紛失時の手順は未設計。Git の PR マージ経路（CI が署名を approval 行へ写す）は未実装。
- 検証コスト: 注入のたびの ssh-keygen 起動の遅延は未測定。
- 承認の質: 人間承認の形骸化（承認疲れ）と誤承認率は未測定。
- キュー: 最上位の責任者も答えない場合の動作、責任者不在 scope の R1 以上（エスカレーション先が無い）の扱い、`question` 文字列に入る注入文の扱い、通知の実装（誰がどう知るか）は未設計。
- フック: subagent 内の発火、コマンド迂回（`git -C`、`sh -c`、スクリプト経由）、フック障害時の既定（fail open/closed）は未検証。複合コマンドを丸ごと deny する副作用あり。
- 優先規則: `topic_key` を抽出器が揃えられるか（未測定）。3者以上の連鎖矛盾。取り消した置換側が出ても旧判断が自動復活しない。権限付与表の保守。
- 法務: 個情法の具体条文・規則の一次照合（別添以外）、2026年改正の一次、Slack の API ToS 全文、Teams/Microsoft の規約、GitHub 規約の条番号の逐語照合、従業員の同意の有効性、判断者の発言が個人データに当たるか、A の `kind='adr'` の同意例外の扱い。すべて法務確認【未確認】。
- 派生物（要約・埋め込み・評価セット）の削除連動、墓標（ハッシュ）の実装は未実装（C と調整）。
- 実データでの評価（プライベート環境）は未実施。再テスト天井の取得負担は未測定。
- 統合スキーマへの F 要件のマージ（§3.1 末尾の 8 点）は A の作業待ち。
- E の新規候補1（決定時点キャプチャ）: `source(kind='queue_answer')` で質問への回答を決定時点の記録にする最小形のみ。GitLab/Arize の資料は未取得で、採否は B/A 側と調整。

## 6. 試した検索クエリ一覧
初版（11件）
1. LLM agent memory prompt injection persistent memory poisoning attack defense
2. 個人情報保護委員会 生成AI 注意喚起 個人情報取扱事業者 プロンプト 入力 利用目的
3. selective prediction abstention LLM calibration confidence threshold risk-coverage human deferral
4. OWASP Top 10 for LLM Applications 2025 prompt injection excessive agency
5. Claude Code memory CLAUDE.md auto memory hooks permissions settings documentation
6. Zep temporal knowledge graph agent memory invalidation bi-temporal arXiv Graphiti
7. indirect prompt injection Greshake "Not what you've signed up for" arXiv
8. LLM simulate human decisions agreement held-out evaluation Cohen's kappa persona fidelity digital twin interview 1000 people
9. learning to defer to human expert rejector confidence LLM deferral cost-sensitive arXiv
10. 個人情報保護法 令和 改正 2026 AI 学習 公布 個人情報保護委員会 本人同意 例外 統計作成
11. agent memory forgetting TTL expiry staleness conflict resolution long-term memory survey arXiv 2026

再調査で追加（2件の WebSearch と、取得）
12. 個人情報保護委員会 生成AIサービスの利用に関する注意喚起等 令和5年6月2日 別添 プロンプト 機械学習 学習に利用されない
13. Slack API terms of service 2025 rate limits data export LLM "may not" large language models Slack data restriction

取得（WebFetch / ローカル）: Pallet memory-bench と benchmark（F16, F17）、PPC 報道発表ページと PDF（F18、PDF は curl で取得し pypdf で抽出）、Slack privacy-principles / developer-policy / changelog tos-updates（F19〜F21）、GitHub Terms of Service（F22）、ssh-keygen(1)（F24）、git-config（ネットの版は gpg.* 部分が切れて未確認 → Git 2.40.0 同梱のローカル文書で確認: F25）、Anthropic Commercial Terms（F30）。
取得できなかった・していない: Microsoft Teams の規約、Slack API ToS 全文、PPC 別添の「要配慮個人情報」以外の関連文書、改正個情法の条文。
