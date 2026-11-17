# A: 判断の記録スキーマ・ADR（ラウンド1）

出典IDは `notes/sources.md` の A01〜A25（A17〜A25 は再調査で追加）。「確認」= 取得して確認、「推測」= 私の設計判断で出典による裏付けなし。「実行確認」= 自分で走らせて結果をログに残した。

## 0. 再調査（E-review の E1, E2, E3, E5, E7, E9 への回答）

成果物（全て `work/` 配下。全データは合成。SQLite 3.39.4 / Python 3.11.1、`python -I` で実行）:

| ファイル | 内容 |
|---|---|
| `work/ddl/unified_schema.sql` | 統合スキーマ（25表・38トリガ・8ビュー） |
| `work/ddl/unified_test.py` / `unified_run.log` | 統合版の実行ログ（77 PASS / 0 FAIL。他に「限界の実演」1件） |
| `work/ddl/a_schema.sql` / `a_run.py` / `a_run.log` | A 原版 DDL の保存・再実行と、E2/E3 の欠陥の再現（E 総評の指摘への対応） |
| `work/rounds/round-1/a-exp/e7_*`, `e7-proj/` | E7: Claude Code 実セッションでの PreToolUse deny |
| `work/rounds/round-1/a-exp/e5_*` | E5: 注入あり/なしの最小実験 |

### 0.1 E1: 統合スキーマ（解消。ただし B/C/D/F の確認待ち）

**単一スキーマ**は `unified_schema.sql`。列は同ファイルを正とし、ここには要点と対応表だけ置く。

**列挙値の統一**

| 軸 | 統一値 | 旧: A / B / C / D / F |
|---|---|---|
| 状態 `decision.status` | `candidate, quarantined, approved, rejected, superseded, expired, revoked` | A: proposed/accepted/superseded/deprecated/rejected、B: hypothesis/confirmed/rejected/stale、C: proposed/approved/superseded/revoked、D: proposed/approved/superseded/expired/rejected、F: candidate/approved/superseded/expired/revoked/quarantined |
| 可逆性 `reversibility` | `two_way, costly, one_way, unknown` | A: two_way/costly/one_way、B: one_way/reversible/unknown、C・D: reversible/one_way、F: R0_cheap/R1_costly/R2_irreversible |
| 動作モード `agent_mode` | `follow, follow_and_log, ask_async, human_only` | A: 同左、C: agent_ok/needs_human、D: agent_ok/notify/human_required、F: A0_task/A1_owner/A2_human_only |
| エージェントの行動 `ai_decision.action` | `proceed, proceed_with_assumption, park_task, escalate` | F の action を採用（A の動作表 §2.3 は `v_agent_action` に置換） |
| 出所の信頼 `source.trust_tier` | `human_authored_verified, human_authored_unverified, third_party, agent_asserted` | F の4段階。B の `trust`（human/untrusted）は human→unverified、untrusted→third_party に写像 |
| 正本 | Git 上の Markdown。DB は索引＋エージェントの作業記録。`source_path`＋`content_hash` で対応 | A・C: Markdown が正、D・F: DB 直書き → DB 直書きは廃止 |

**状態遷移図**（`status_transition` 表にデータとして保持し、トリガで強制。表自体は変更不可トリガで施錠）

```
            approval(approve) INSERT                     link supersedes (両方approved・同scope・権限条件)
 candidate ---------------------------> approved --------------------------------------------------> superseded
   |  ^                                  |  |  \
   |  | (承認歴なしの場合のみ)            |  |   `-- valid_until 経過 -----------------------------> expired
   v  |                                  |  `----- approval(revoke) -----------------------------> revoked
 quarantined <---- approval(revoke) -----'                                         (approved -> quarantined も revoke 承認が要る)
   |
   `--> rejected   (candidate -> rejected もある)
```
`approved` へ入る道は `approval` 行の INSERT だけ（トリガ `trg_ap_apply` が遷移させる）。`INSERT ... status='approved'` と直接 `UPDATE` は共に拒否（§0.2）。

**各担当の必須要件の取り込み状況**（E1 の要件表に対応）

| 要件 | 担当 | 統合版での実現 | 実行確認 |
|---|---|---|---|
| 可逆性・有効期限・優先規則 | A | `reversibility`（`one_way/unknown` は `follow` 不可を CHECK）、`valid_from/valid_until/review_by`、`v_conflict_resolution`（§0.5） | はい |
| quote 検証 | B | `evidence.quote_verified=1` は `verify_quote()` が true を返す時のみ（トリガ）。承認は検証済み・人間由来・同意あり・マスク済み・未失効の証拠が1件以上必須。判断者は `role='decider'` の検証済み証拠が必須 | はい（偽の検証済み旗、関数未登録の接続=fail closed を確認） |
| bitemporal | C | 実世界時間 `valid_from/valid_until`、記録時間 `recorded_at`、失効を知った時刻 `invalidated_at`。履歴は削除せず status で残す。as-of クエリを実行 | はい |
| tier・trigger | D | `decision.tier`、`decision_trigger(kind,pattern)`、`decision_tag`、`injection_log`、FTS5 trigram（external content） | FTS のみ実行。D のフックとの結合は未実施 |
| consent・source・trust_tier・eval | F | `consent`、`source`（`ingest_state` で同意が取れない場合を `anonymized_only/not_ingested` に）、`extraction_run`、`decision_class`、`ai_decision`、`decision_use`、`eval_case/eval_result`、`v_blast_radius`、`v_agreement` | はい（同意撤回・agent_asserted のみの承認拒否、v_blast_radius） |

**旧列 → 新列の対応表**（「←」は写像、「×」は廃止・吸収。情報が減るものは備考）

| 担当 | 旧 | 新 | 備考 |
|---|---|---|---|
| A | `decision.decision_id/title/kind/rationale/tradeoff/card` | 同名 | `kind` に `criterion` を追加（B の基準仮説） |
| A | `status`(accepted) / `epistemic` | `status`(approved) / ×（`candidate`=hypothesis、`approved`=confirmed） | `epistemic` 列は廃止。状態で表す |
| A | `decider_role` / `decider_ref` | `decided_by`→`principal` | 役割は `principal.role_id` から引く。仮名 |
| A | `approved_by/approved_at` | ×（`approval.approver_id/approved_at`） | 自由文字列を廃止（E2） |
| A | `role(authority_rank, max_reversibility)` | `role(rank, escalates_to)` ＋ `authority_grant(principal, scope_project, rank)` | 大域ランクから (主体, scope) 別ランクへ（E9）。`max_reversibility` は廃止（`decision_class.floor_agent_mode` で代替。機能は弱まる） |
| A | `decision_link(supersedes/conflicts_with/depends_on/refines)` | 同左＋`proposes_supersede`＋`overrides` | supersede は自動失効→ゲート付き（E3） |
| A | `decision_scope(project/path/task_type/tag)` | `scope_project`・`scope_path` 列＋`decision_scope(path/task_type)`＋`decision_tag` | project と path は優先規則に使うため列に昇格 |
| A | `decision_source` | `evidence` | `deviation_note` 種別は未移植（`source.kind` に無い。要追加） |
| A | `decision_option` / `decision_assumption` | 同名 | 変更なし |
| B | `source_item(source_id,kind,author,ts,trust,body_sha256,consent_ref)` | `source(ref,kind,author_id,trust_tier,body_sha256,consent_id,…)` | `ts` は `ingested_at` に吸収（元の発言時刻は未保持。要追加） |
| B | `decision_candidate.cand_id/decision/rationale/decider/scope/reversibility/confidence` | `decision`（`status='candidate'`, `origin='extracted'`） | `decider_evidence` 列は `evidence(role='decider')` に |
| B | `decision_candidate.superseded_by` | `decision_link(supersedes)` | |
| B | `status`(hypothesis/confirmed/rejected/stale) | `candidate / approved / rejected / expired` | `stale`→`expired` は意味が近いが同一でない |
| B | `confirmed_by/confirmed_at` | `approval` | |
| B | `evidence(quote, quote_verified, role)` | `evidence` | 同名。検証を関数ゲートに（旗の自己申告を禁止） |
| B | `extractor/extracted_at` | `extraction_run` ＋ `decision.recorded_at` | |
| B | `criterion_hypothesis` | `decision(kind='criterion')` | `n_supporting` は `evidence` の件数で代替 |
| C | `decision.id/body/scope/decided_by` | `decision_id/decision_text(+rationale)/scope_project/decided_by` | `body`（判断+理由+前提の混在）は分割 |
| C | `status`(approved/revoked) | `approved/revoked` | |
| C | `authority(agent_ok/needs_human)` | `agent_mode` | agent_ok→follow、needs_human→human_only |
| C | `valid_from/valid_to/recorded_at/expires_at` | `valid_from/valid_until/recorded_at/review_by` ＋`invalidated_at` | `valid_to`→`valid_until`、`expires_at`→`review_by`（再確認日）。bitemporal の系統時間終端 `invalidated_at` を追加 |
| C | `source_path/content_hash` | 同名 | |
| C | `evidence(kind,ref,excerpt,sensitivity)` | `source(kind,ref,sensitivity)`＋`evidence.quote`（≤300字） | 本文複製を抑える上限を CHECK で追加 |
| C | `decision_edge(supersedes/contradicts/…)` | `decision_link` | `contradicts`→`conflicts_with` |
| C | `open_question` | `review_queue` | §0.4 |
| C | FTS5 trigram（external content） | 同じ | |
| D | `rule` | `decision_text`（注入用は `card`） | 「1〜2文の注入形」は `card` が担う |
| D | `authority(agent_ok/notify/human_required)` | `agent_mode` | agent_ok→follow、notify→follow_and_log、human_required→human_only（ask_async との区別は消える） |
| D | `reversibility(reversible/one_way)` | `two_way/one_way` | reversible→two_way（costly と区別できていた情報は元から無い） |
| D | `scope_paths`（改行区切り glob） | `scope_path`（単一）＋`decision_scope(dim='path')` | 複数 glob は `decision_scope` |
| D | `tier`、`decision_trigger`、`decision_tag`、`injection_log` | 同名 | |
| D | `decision_fts_uni`（unicode61） | 未移植 | D の日本語対策（空白区切りタグ語彙）は D 側の実装事項。要確認 |
| F | `memory_entry.statement/class_code/decider_alias/scope` | `decision.decision_text/class_code/decided_by/scope_project` | 表名は `decision` に統一 |
| F | `person_alias` | `principal`（kind=human） | |
| F | `consent`、`source`、`extraction_run`、`evidence` | 同名で統合 | `source.id`→`source_id`、`kind` を拡張 |
| F | `decision_class.reversibility/authority` | `decision_class.floor_agent_mode`（可逆性は決定側） | クラスが可逆性を持つ設計は廃止。要確認 |
| F | `approved_by/approved_at`、`trg_no_agent_only_approval` | `approval` と `trg_ap_*` | UPDATE だけでなく INSERT 経路も拒否 |
| F | `ai_decision/decision_use/review_queue/eval_case/eval_result/v_blast_radius/v_agreement` | 同名（FK 名を統一） | |
| F | `supersedes_id` 列 | `decision_link(supersedes)` | |

**未移植・未確認（正直に）**: (1) B/C/D/F は同時並行で自分の修正に取り組んでおり、本表は **round-1 原版の列**を元にしている。各担当の修正版（例: `c_schema_r2.sql`、`f_schema.sql`）との突き合わせは未実施。(2) C の Markdown→DB 再構築（`c_rebuild.py`）が、統合版の「candidate 挿入→承認」経路で動くかは未検証。(3) D の注入フックと統合版ビューの結合は未実施。(4) 「削除・墓標」（F）は未実装。

### 0.2 E2: 承認の強制（解消。条件付き）

**設計（3層。単独の層に依存しない）**
1. **承認の主体を DB の外の事実に結びつける**。`approval` 行は承認サービスだけが作る。サービスは (a) Git コミットが `allowed_signers`（人間の署名鍵だけを列挙）で署名されていること、(b) 署名者が `kind='human'` の principal であること、(c) コミット内の Markdown のハッシュが DB の `content_hash` と一致すること、を確かめた時だけ HMAC（`proof_mac`）を作る。`approver_id` は自由入力でなく署名検証から決まる。
2. **DB のトリガ**が `approval` の INSERT で `verify_proof()`（HMAC 検証）・承認者が human・権限ランクが scope と `required_role` を満たす・内容ハッシュ一致・状態が合う・証拠条件を検査する。`verify_proof` を登録していない接続は "no such function" で失敗する（fail closed）。`decision` は `candidate`/`quarantined` としてしか INSERT できず、`approved` への UPDATE は該当 `approval` 行が無ければ拒否。`approval` は追記のみ。
3. **エージェントに渡す接続**は SQLite の authorizer で許可リスト化（INSERT は作業表のみ。`approval`・`principal`・`authority_grant`・`status_transition`・DROP・UPDATE は拒否）。

**実行ログ**（`unified_run.log` §2, §6。全て合成）

| 試行 | 結果 |
|---|---|
| エージェント接続で `approval` に INSERT | 拒否（not authorized） |
| エージェント接続で `status='approved'` の `decision` を INSERT（INSERT 経路） | 拒否（candidate/quarantined のみ） |
| エージェント接続で `UPDATE status='approved'` | 拒否（not authorized） |
| 生の書込み接続（`verify_proof` 未登録）で人間名義の承認を INSERT | 拒否（no such function = fail closed） |
| 鍵を持たない接続が自作関数で `approver_id=boss-a`・偽 MAC を INSERT | 拒否（approval proof invalid） |
| 同接続で候補を直接 `UPDATE status='approved'` | 拒否（no approval row） |
| agent principal 名義・権限なし人間名義・`content_hash` 不一致（正しい MAC 付き） | 各々拒否 |
| エージェントが自分の鍵で署名したコミット／senior-b のメールを名乗る無署名コミット／senior-b のメールを名乗りエージェント鍵で署名したコミット | 承認サービスが拒否（署名状態 U / N / U） |
| `approval` の UPDATE/DELETE | 拒否（追記のみ） |
| 正規経路（人間が署名したコミット→サービス→MAC） | `approved`。`approver_id` は署名者から導出 |

**限界（実演済み。ログの §6 に `LIMIT` として残した）**: スキーマ変更権限のある生の書込み接続は、ガード用トリガを `DROP TRIGGER` して偽の承認を通せる（コピーした DB で `approved` になることを確認）。つまり DB 内の CHECK/トリガは**多層防御の一層**で、境界そのものは (i) エージェントには authorizer 付き接続だけを渡す（authorizer は DROP・principal/grant の書込みを拒否することを確認）、(ii) DB ファイルをエージェントのプロセスが書けない、(iii) MAC 鍵・署名鍵をエージェントが読めない、の3点を**運用で満たす**ことに依存する。authorizer は同一プロセス内の仕組みなので、エージェントが任意の Python/ネイティブコードを実行できる構成では境界にならない。（Git の author メールは自己申告できるため、署名検証を使った。GitHub の merged_by や保護ブランチでの代替は未検証。）

| 根拠 | 確認/推測 | 破綻しうる条件 |
|---|---|---|
| A22（実行ログ）、A21（authorizer 仕様。第4/5引数は取得範囲で未確認だが挙動は A22 で観測）、B-07/C01（CLAUDE.md は助言であり強制は hook） | 確認: 上表の拒否。推測: 本番で鍵を隔離できること | 鍵と DB が同一ユーザー権限でエージェントから読める／書ける。承認者が内容を見ずに署名する（承認疲れは F 担当の領域で未解決）。署名鍵の失効・ローテーション未設計 |

### 0.3 E3: supersede ゲート（解消）

`decision_link` の `supersedes` は、`trg_link_supersede_gate` が次を全て満たす時だけ挿入でき、挿入後に旧判断が `superseded`・`valid_until` が新判断の前日に短縮される。
1. 新旧**両方が `approved`**。2. `scope_project` が同一（異 scope は `overrides` を使い、失効はさせない）。3. 新判断の承認者のランク ≥ 旧判断の承認者のランク。4. 旧判断に `required_role` があれば新承認者のランクがそれ以上。
エージェントが書けるのは `proposes_supersede`（効果なし）まで。`status='superseded'` への直接 UPDATE は、承認済み判断からの `supersedes` リンクが無ければ拒否。

実行ログ（`unified_run.log` §3）: candidate が approved を supersede → 拒否（両方承認済みが必要）／旧判断は引き続き `v_effective` に残る／`proposes_supersede` は挿入可だが効果なし／低権限承認者（rank10 対 60）の supersede は拒否／異 scope は拒否／同 scope・同権限の承認済み同士は成功し `valid_until` が前日になる／リンク無しの直接 `UPDATE status='superseded'` は拒否。原版で失効してしまうことは `a_run.log` で再現（原版では proposed が accepted を失効させ `v_effective` が空になる）。

| 根拠 | 確認/推測 | 破綻しうる条件 |
|---|---|---|
| A22, A23, E-review E3 | 確認（上記テスト）。「新承認者ランク ≥ 旧承認者ランク」という権限条件は推測（設計判断） | ランクの付与が実態と乖離。同ランクの同僚が互いの判断を無言で上書き（検知は承認者の目視のみ） |

### 0.4 E7: 低確信時の動作の実体化と質問キュー（部分的に解消）

**単一の動作規則**: `v_agent_action`（1つのビュー）。負けた側の判断は `overridden`、`human_only` は `escalate`、`one_way/unknown` は `park_task`、未解決の矛盾チケットまたは確信度がクラス閾値未満または `ask_async` は `proceed_with_assumption`、それ以外は `proceed`。（A §2.3 の表と F §2.2 の表はこの規則に置換。確信度の閾値は `decision_class.min_confidence` で、値は仮置きのまま。）

**質問キューの単一仕様**（`review_queue` 1本。C の `open_question` と F の `review_queue` を統合）
- **誰が書く**: エージェント（`raised_by`）。INSERT のみ可。既定で採った行動（`default_taken`）と巻き戻し手順を必ず添える。
- **誰が読む**: `assignee_role` の人間。起動時（SessionStart）と `v_queue_due` で件数・期限切れを提示する想定（フック側は D の実装。未結合）。
- **誰が答える**: human principal のみ（`state='answered'` はトリガで人間以外を拒否。エージェント接続は UPDATE 自体が拒否）。
- **期限切れ**: `on_expire` で決める（`confirm_default`=既定を確定／`continue_and_renotify`=既定のまま継続し再通知／`stay_parked`=駐車のまま再通知）。責任者は `assignee_role` の `escalates_to`（`v_queue_due.responsible_role`）。スイーパ（承認サービス側）が `v_queue_due` を読んで処理する。スイーパ自体の定期実行は未実装。

**実セッションでの確認**（`a-exp/e7_*`。Claude Code 2.1.302、`claude -p`、モデルは init で `claude-sonnet-5-5`、合成タスク。n=3 回、モデルは1種）
- フックは `python -I` で統合 DB を読み、承認済みの `DR-DEL`（`human_only`、トリガ `data/prod`）に一致した削除操作を `permissionDecision: deny` ＋理由で拒否し、`review_queue` に質問を積み、`ai_decision` に `escalate` を記録した。
- run1（失敗例）: `matcher` を `Bash|Write|Edit` にしたところ、エージェントが **PowerShell ツール**で `Remove-Item` を実行し、**削除が通った**（`e7_run1_*`）。Windows では matcher に `PowerShell` が必要。deny リストの網羅性が問題で、これは D のフック設計にも影響する。
- run2/run3（`matcher` に PowerShell を追加）: `Remove-Item` が deny され、エージェントは Write（run2）／別の PowerShell（run3）で `notes/hello.txt` の作成と一覧に**進み**、最後に「ブロックされた・回避していない・質問を積んだ」と報告した。run2 はプロンプトに「ブロックされたら回避せず先へ進め」と書いた版、run3 はその文を外した版。どちらも同じ結果（各1回。分散は不明）。
- 未確認: subagent 内の発火（`hook.log` の `agent_id` は主セッションで null。E が公式ドキュメントで確認した記載を私は実行で確かめていない）、deny リスト（`rm`, `Remove-Item` 等の語）の迂回（`[System.IO.File]::Delete` 等は拾えない設計）、長時間運転。

| 根拠 | 確認/推測 | 破綻しうる条件 |
|---|---|---|
| A22, A24, D-S01（hooks）, E-review E7 | 確認: deny 発火・作業続行・キュー記録（n=3）。推測: 期限切れ運用 | 語彙ベースの deny は迂回される（根本はサンドボックス/権限設定）。キューを読む人がいなければ全て `stay_parked`/既定のまま滞留 |

### 0.5 E9: 唯一の優先規則（解消。検証は合成シナリオのみ）

**規則**（`v_conflict_resolution`。上から順に最初に差が出た所で決める。両方 `approved` かつ有効で `conflicts_with` リンクがある組だけが対象）
0. 承認済みの `overrides` リンクがあればそれ。
1. 権限ランク: 判断者の、その判断の `scope_project` を覆う `authority_grant` のランクの最大値（無ければ 0）。
2. scope の具体性（project 指定 +1、path 指定 +1）。
3. 新しい `valid_from`。
4. 高い `confidence`。
5. 決まらない → 勝者なし。`conflict_ticket` を開き、両判断は `proceed_with_assumption` に下がる。チケットは、承認済み判断（supersedes/overrides）で勝者が決まった時にだけ resolved にできる（UPDATE を直接打っても拒否）。

順序「権限 > 具体性 > 新しさ」は法の格言（lex superior / specialis / posterior）の借用で、**この順序自体の出典は無い**（A20 は固定順位を載せていない）。A §2.5（旧）・F の順序とも異なるので、これを唯一の規則とし、旧記述は廃止する。

**合成シナリオの実行結果**（`unified_run.log` §4）

| シナリオ | 設定 | 勝者・決め手 |
|---|---|---|
| S1 上司 vs 先輩 | 同 scope。boss-a（global 90）対 senior-b（demo 60）。先輩の方が新しく確信度も高い | 上司（1_authority） |
| S2 global vs project | 同一判断者。global 判断対 `proj-p` 限定判断 | project 限定（2_specificity） |
| S3 新旧 | 同一判断者・同 scope・supersede 関係なし。新=確信度0.7、旧=0.9 | 新（3_recency） |
| S4 別部署の上司 vs 先輩 | deptY-boss は `deptY` にだけ grant。demo 判断では rank 0 | 先輩（1_authority） |
| S5 完全同順位 | 同権限・同 scope・同日・同確信度 | 勝者なし（5）。チケット開設、`proceed`→`proceed_with_assumption` を確認。上位者が両方を supersede するとチケット対象が消える |
| S6 明示 overrides | global 上司判断 vs project 先輩判断。overrides 前は上司（権限）。上位権限者が承認した overrides を追加 | project 先輩判断（0_overrides）。低権限承認者による overrides は拒否 |

大域ランク前提の問題（A 自身が認めた点）は、ランクを `(主体, scope)` の `authority_grant` にして**判断の scope でのランク**を使うことで扱った。部署が違えば grant が無く rank 0 になり、権限差では決まらず下位の規則に落ちる（S4 は決め手が 1_authority になったが、これは相手が grant を持つため）。

| 根拠 | 確認/推測 | 破綻しうる条件 |
|---|---|---|
| A22, A20（格言の借用） | 確認: 6シナリオの結果。推測: 順序の妥当性（実運用の判断者の期待と合うかは未検証） | `conflicts_with` リンクが誰にも張られない矛盾は検出されない（検出は抽出側/レビューの責務で未設計）。global 上司が project の責任者を権限で常に上回る（上回らせたくなければ overrides を使う運用が要る）。ランク値の付け方が恣意的 |

### 0.6 E5: 効果の定量的根拠（部分的に解消。自前実験は上限値であって実世界の効果ではない）

**既存の定量報告**（A17, A18。一次=ベンダー自身のページ。逐語照合なし）: Pallet "Memory-Bench"（2026-09-24公開）は、本番判断由来78タスクのうち人間の正解鍵がある44件で、7モデルのプール first-try 正解率が記憶なし22%→あり62%（各モデル +36〜45pt）。記憶は SOP・過去の実行・人間の修正事例。方法ページ（A18）で次が分かった。弱さを列挙する:
- ベンダーが自社の記憶層を評価している。CI・有意検定なし。44件。50試行は gpt-5.5 のみで、他6モデルは1回。
- 関連事例を意図的に過剰サンプリング（本番の基準率は約22%）。contested/unknown/silver を除くと 22→62% が 18→54% に動く。全文脈投入では +14〜15pt に縮む。
- 提示順を変えると、履歴が互いに食い違うタスクで答えの安定率が 41%（履歴が一致する場合は 74%）。
- プロンプト形式の ablation は未報告。リーク対策は時刻カットオフのみで別途の監査の記載なし。
- 1決定点のみ。判断者個人の判断の再現ではなく、運用手順の正解率。
つまり「記憶を足すと正解が増える」ことの傍証にはなるが、本プロジェクトの「個人の判断の再現」への効果は示していない。直接の研究は検索で見つからなかった（A19。「無い」とは言えない）。

**自前の最小実験**（`a-exp/e5_exp.py`、結果 `e5_score.log`。合成データ、`claude -p`・sonnet・ツール無効、1サンプル/セル）
- 設計: 合成の2判断者 D-1, D-2。6つの領域（リトライ・デプロイ・依存更新・レビュー・障害連絡・個人情報ログ）で互いに逆の癖を持つ。各領域で過去判断カード4件（Y-statement 形式）を作り、未見の状況2件ずつ（計12ケース）を予測させる。一致率 = AI の選択 == その判断者の選択（F §2.1 の定義）。腕: no_memory／full_memory（本人のカード24件）／shuffled_memory（他方のカード24件。ラベルは対象本人のまま）。n=12 ケース×2 判断者=24/腕。
- 結果: no_memory 7/24 = 0.29（Wilson95 0.15–0.49）、full_memory 23/24 = 0.96（0.80–0.99）、shuffled_memory 0/24 = 0.00（0.00–0.14）。
- 解釈: カードの注入で本人の選択との一致が上がり、他人のカードでは**下がる**（一般常識に寄っているだけでは説明できない。F の `shuffled_memory` 腕が合成データで機能する最小例にもなっている）。
- 限界（重要）: (1) 同一ドメインの4件から規則を直接引ける設計で、**上限に近い易しい条件**。実データの判断は矛盾・例外・暗黙知を含む。(2) 全24件を毎回入れており、検索・順位付けの失敗を測っていない。(3) モデル1種・1サンプル。(4) 判断者の癖は私が作ったルールなので、モデルの事前分布と無関係な任意規則が「常識との区別」を容易にしている。(5) 承認前の仮説カードや古いカードを混ぜた時の挙動は未測定。**実世界の効果量としては使わない**。

| 根拠 | 確認/推測 | 破綻しうる条件 |
|---|---|---|
| A17, A18, A19, A25 | 確認: 上記の数値（自前=実行、Pallet=取得）。推測: 実データへの外挿は不可 | 実データで記録が矛盾・不足すると差が縮む（Pallet でも全文脈や contested 層で縮んだ）。検索を挟むと更に下がりうる |

### 0.7 未解決・不確実（今回の範囲）
1. B/C/D/F の修正版との突き合わせ（§0.1 末尾）。統合版は私が単独で設計した版で、他担当のレビューは未実施。
2. 承認サービスの本番実装（GitHub の merged_by・保護ブランチ・鍵ローテーション）は未検証。署名鍵と MAC 鍵の保管場所が最大の前提。
3. `conflicts_with` を誰がいつ張るか（矛盾の検出）。張られない矛盾は優先規則が働かない。
4. E7 のキューを人間が実際に読む運用（誰が、どの頻度で）は設計のみ。スイーパの定期実行は未実装。
5. 優先規則の順序（権限 > 具体性 > 新しさ）の妥当性は実運用の判断者で未検証。
6. E5 の実データでの効果、検索を挟んだ場合、仮説/古いカード混在時は未測定。
7. 閾値 0.8/0.5（A §2.3）は依然として根拠のない仮置き。統合版では `decision_class.min_confidence`（0.7 は合成値）。
8. E4（注入側の有効期限検査）、E6、E8、E10〜E13 は今回の担当外。統合版の `v_effective` は期限・superseded・candidate を除外することをログで確認したが、D のフックがこのビューを使うかは未確認。

### 0.8 試した検索・取得（今回追加）
- WebFetch: pallet.com/labs/memory-bench、pallet.com/labs/benchmark、en.wikipedia.org/wiki/Lex_specialis、sqlite.org/c3ref/set_authorizer.html
- WebSearch: "benchmark agent memory of past human decisions improves agreement with human decision-maker evaluation with and without memory"
- 実行: `unified_test.py`、`a_run.py`、`e7_*`（claude -p ×3）、`e5_exp.py`（claude -p ×48）

---
以下は round-1 原版（§2.4 の DDL と §2.3 の動作表、§2.5 の優先規則は §0 で置換済み。経緯として残す）。

## 1. 要約

- ADR（Nygard 2011）は Context/Decision/Status/Consequences の4〜5節で、1〜2ページ、番号を再利用せず、覆す時は superseded で残す（A01、確認）。MADR 4.0.0 は却下案(Considered Options)・Confirmation・decision-makers を持つ（A02、確認）。
- ただし人間向け ADR が持たないが「AI が判断を再現する」には必須の項目がある。**権限(誰が決めたか/誰なら覆せるか)、確信度と根拠の種類、可逆性、有効期間、適用範囲、矛盾時の優先規則、エージェントの動作モード**。これらは標準 ADR テンプレに無い（推測。A01/A02 の節に無いことは確認）。
- 提案は2層。(a) 人が読む Markdown＋YAML front matter の判断レコード (b) 機械が引く SQLite 正規化表。両方に同じ項目。注入用には Y-statement 形式の「カード」(300字以内) を持たせ、全文は必要時だけ引く（A07 の6要素。カードの長さ上限は推測）。
- 抽出された判断は `epistemic=hypothesis` で、人間が承認(`approved_by`)するまで `accepted` にできない。DB の CHECK で強制した（SQLite で実行済み、§2.4）。
- 一方通行(`one_way`)の判断は `agent_mode` が `ask_async`/`human_only` に限られる。Bezos の Type1/Type2 区別（A11、確認）を借りた。
- 矛盾時の優先規則は「confirmed > hypothesis → 権限ランク → 新しい valid_from → 確信度」の決定的な順序を提案（推測。要バックテスト）。
- 強い注意: 「ADR を足せば AI が従う」を支持する一次の定量根拠は見つからなかった。Qodo 経由の「-10.1%」は元論文未確認で不採用（A16）。
- 暗黙の判断・組織知識に依存する決定は LLM による検証精度が落ちる（A09、確認）。記録側で「検証可能性」を明示する価値がある。

## 2. 提案

### 2.1 必須項目の判定表

各項目: 必須度 / 理由 / 根拠 / 確認or推測 / 破綻条件。

| 項目 | 必須度 | 理由 | 根拠 | 確認/推測 | 破綻しうる条件 |
|---|---|---|---|---|---|
| decision_text（「〜する」） | 必須 | 再現対象そのもの | A01 | 確認 | 複数判断が1件に混ざる（A01 は1 ADR 1決定） |
| rationale（なぜ） | 必須 | 例外・類似状況への転用に必要。結論だけだと機械的適用になる | A01,A07,A10 | 確認（意見含む） | 後付け合理化。抽出時は rationale が推定になる→ confidence_basis で区別 |
| tradeoff（accepting that） | 必須 | 「何を犠牲にしたか」が分かると、犠牲が許容外になった時に再検討できる | A07 | 確認 | 書き手が空欄にする→NULL許容にしたが card では必須 |
| options（却下案＋why_not＋reconsider_if） | 必須 | 却下案の再提案を防ぐ(A10)。reconsider_if で復活条件を持つ | A02,A07,A10 | 確認（A10は意見） | 却下案が網羅されない。却下理由が陳腐化 |
| assumptions / constraints | 必須 | 前提が崩れたら判断は失効候補。check_hint で検査可能に | 推測（A15 は項目未確認） | 推測 | check_hint を書けない前提が多い |
| decider_role / decider_ref | 必須 | 権限の評価に使う。実名でなく仮名ハンドル | A02(decision-makers) | 一部確認 | ロールが固定化し実態と乖離 |
| required_role | 条件付 | 覆すのに必要な最小ロール。権限超過判断の検出 | 推測 | 推測 | 組織変更で陳腐化 |
| reversibility（two_way/costly/one_way） | 必須 | 確信度が低い時の退避動作を分ける | A11 | 確認（概念）/推測（3値化） | 見積り誤り。一見可逆でも副作用が戻らない |
| confidence ＋ confidence_basis | 必須 | 数値だけだと較正されていない。根拠種別を併記 | 推測 | 推測 | LLM 自己申告の確信度は較正されない可能性。F 担当の較正実験待ち |
| agent_mode / fallback | 必須 | 「待たずに進める」(plan.md)を実装する核 | plan.md | 設計 | モード割当が過度に保守的だとブロッカーが残る |
| scope（project/path/task_type/tag、exclude） | 必須 | 過剰適用を防ぐ。path-scoped rules と同発想 | A06 | 確認（Claude Code側の仕組み） | scope が広すぎ/狭すぎ。scope 判定自体を誤る |
| valid_from / valid_until / review_by | 必須 | 有効期限と再確認日。bi-temporal(valid時間と recorded_at) | A13 | 確認（Graphiti は有効窓を持つ）。フィールド名は未確認 | 期限が過ぎても人が気づかない→ review_by で警告する運用が必要 |
| status＋epistemic | 必須 | 抽出物=仮説、承認=権威 | plan.md, A01(status) | 設計 | 承認が形骸化（全件ワンクリック承認）。F担当の運用設計待ち |
| supersedes 等の link | 必須 | 履歴を消さず無効化 | A01,A10,A13 | 確認 | 循環・孤立リンク |
| source（ポインタ＋extracted_by） | 必須 | 出所と抽出器版を追跡。本文はコピーせず参照 | 推測 | 推測 | 参照先が消える。ログ内の命令文を拾う(プロンプトインジェクション)→B/F |
| card（Y-statement 300字） | 必須 | 注入用の短い表現。全文を毎回入れない | A07 | 確認（形式）/推測（300字） | 圧縮で条件が落ちる |
| consulted / informed | 任意 | 合意形成の記録。AI再現には効果が薄い | A02 | 確認 | — |

注: Tyree & Akerman (2005) のテンプレ項目は本文未取得で「未確認」。assumptions 等を「彼らも持つ」とは書かない（A15）。

### 2.2 Markdown テンプレート（人間レビュー用）

人が1画面で承認できる量（目安: 本文30行以内）を意図。Nygard の「大きい文書は読まれない」(A01) に沿う。

```markdown
---
id: DR-0002
title: 記憶ストアに Postgres を使う
kind: technical            # principle|technical|product|process|preference
status: accepted           # proposed|accepted|superseded|deprecated|rejected
epistemic: confirmed       # hypothesis|confirmed  (抽出物は hypothesis)
decider: {role: senior, ref: senior-b}   # 仮名。実名は書かない
required_role: owner       # 覆すのに必要な最小ロール（無ければ省略）
approved: {by: owner-a, at: 2026-03-02}
reversibility: costly      # two_way|costly|one_way
confidence: 0.7
confidence_basis: inferred_from_behavior
agent_mode: follow_and_log # follow|follow_and_log|ask_async|human_only
fallback: "迷ったら SQLite 互換の SQL だけ使う"
valid_from: 2026-03-01
valid_until:               # 空=期限なし
review_by: 2026-09-01
supersedes: [DR-0001]
scope: {project: [demo], path: ["db/**"], exclude: []}
sources: [{kind: review_comment, ref: "synthetic://review/12"}]
---
**card**: In the context of 5 concurrent writers, facing write contention, we decided for Postgres and neglected SQLite, to achieve concurrency, accepting ops cost.

## Decision
We will store decision records in Postgres.

## Why
書き込みが5人並行になった。

## Accepting (trade-off)
運用コスト。

## Options
- [x] Postgres
- [ ] SQLite — 却下理由: 書込競合。reconsider_if: 書き手が1人に戻る

## Assumptions / Constraints
- assumption: 書き手は5人前後 / check: 直近30日の distinct writer 数
```

### 2.3 判断の再現に使うときのエージェント動作表（提案）

| reversibility | confidence ≥ 0.8 かつ confirmed | 0.5〜0.8 | < 0.5 または hypothesis |
|---|---|---|---|
| two_way | 従う | 従い、ログに残す | 保守的な fallback で進め、非同期キューに質問を積む |
| costly | 従い、ログに残す | fallback で進め、質問を積む | fallback で進め、質問を積む。不可逆な手前で止める |
| one_way | 質問を積む、実行は人間 | 同左 | 同左（常に human_only/ask_async） |

閾値 0.8/0.5 は**根拠のない仮置き**（推測）。F 担当のバックテストで較正する前提。破綻条件: 確信度が較正されていないと閾値が無意味。`one_way` を DB の CHECK で `follow` 不可にしてあるのは、この表の最下行を強制するため。

### 2.4 SQLite DDL（実行検証済み）

実行環境: Python 3.11 `sqlite3`（SQLite 3.39.4）、`python -I`。DDL と合成データ投入が通り、不正操作5件が全て拒否されることを確認した。
注意: 本ファイル1つ縛りのため、DDL/ログの `work/` 保存は未実施。plan.md 終了条件3の「ログを work/ に残す」はメインスレッドで保存が必要（下の再現コマンドを使う）。実行元ファイルは scratchpad にあるが、内容は以下と同一。

```sql
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
```

実行ログ（合成データ: DR-0001 SQLite 採用、DR-0002 Postgres で supersede、DR-0003 チャットから抽出した「確認なしで顧客データ削除」仮説）:

```
sqlite 3.39.4
DDL OK
seed OK
SELECT decision_id,status FROM decision ORDER BY 1
   ('DR-0001', 'superseded')    <- link_supersede トリガが自動更新
   ('DR-0002', 'accepted')
   ('DR-0003', 'proposed')
SELECT decision_id,prec FROM v_precedence
   ('DR-0002', 1)               <- hypothesis の DR-0003 は有効集合に入らない
rejected: edit accepted text -> accepted decision is immutable: write a superseding record
rejected: accept hypothesis w/o approval -> CHECK constraint failed: status <> 'accepted' OR (...)
rejected: one_way with follow -> CHECK constraint failed: reversibility <> 'one_way' OR agent_mode IN (...)
rejected: rejected option w/o reason -> CHECK constraint failed: chosen = 1 OR why_not IS NOT NULL
rejected: card too long -> CHECK constraint failed: length(card) <= 300
```

再現: `python -I run.py <schema.sql と seed.sql のあるディレクトリ>`。DDL は §2.4 のブロックを `schema.sql` として保存すれば同じ結果になる想定。ただし DDL を貼り直した版での再実行は未実施。

この検証で確認できたのは「構文が通り、制約が意図どおり働く」ことだけ。**スキーマが実際に AI の判断再現率を上げるかは未検証**。

### 2.5 矛盾時の優先規則（提案、推測）

1. `human_only` / 権限超過（`required_role` を満たさない上書き）→ 常に人間へ。
2. `confirmed` は `hypothesis` に勝つ。
3. scope が狭い(path 指定あり)ものが広いものに勝つ（この比較は DDL 未実装。クエリ側で実装要）。
4. 権限ランクが高い decider が勝つ。
5. 新しい `valid_from`。
6. 確信度が高い方。
7. 同順位なら「保守的 fallback で進め、衝突を人間に非同期で通知」。
`conflicts_with` リンクがある組には、2〜6 の結果をログに残す。破綻条件: 上司と先輩の矛盾が「権限ランク」で機械的に決まらない場合（部署が違う等）。ランクを scope ごとに持つ必要があるが、現在の `role` 表は大域ランクのみ。

### 2.6 注入効率と人のレビュー容易性の両立

- 注入は card（≤300字、約100〜150トークンと推測）を既定とし、`agent_mode`/`fallback` と scope 一致時のみ全文を引く。
- 人のレビューは Markdown の1画面。DB は Markdown から生成（Markdown が正、DB は索引）。二重管理の食い違い対策が要る（推測、未解決）。
- A08: ADR 生成時は直近3〜5件の文脈が効率最良で、検索ベース選択の追加効果は線形な場合ほぼ無い。これは「生成」の結果であり「判断の再現」への注入に転用できるとは限らない。判断の件数が少ない初期は全カードを入れる運用でよい可能性がある（推測）。件数が増えた時の切替点は D 担当の検討事項。
- Claude Code の CLAUDE.md は助言で強制力が無く、200行目安、auto memory は先頭200行/25KB（A06、確認）。したがって「強制したい判断」(one_way の禁止等)は hooks 側に置き、カードは助言層に置く分担が必要。

### 2.7 既存ツールとの対応（確認できた範囲）

- MemGPT/Letta: 階層メモリ（core ブロック=常時文脈、archival=検索）、エージェントが自己編集（A04確認、A14は検索要約のみ）。判断レコードは「常時入れる card 層」と「archival 全文層」に対応づけられる（推測）。自己編集を許すと hypothesis を勝手に昇格できるため、承認ゲートは外側に置く。
- Zep/Graphiti: 事実に有効期間を持たせ、変更時は削除でなく無効化（A13確認）。本提案の valid_from/valid_until/supersede と同じ思想。bi-temporal の具体フィールド名は未確認。
- Mem0: 実在確認のみ（A12、二次）。判断レコード向けの機能比較はC担当へ。

## 3. 検討して棄却した案と理由

| 案 | 棄却理由 |
|---|---|
| Nygard 形式のまま（自由文のみ） | 権限・確信度・可逆性・有効期限が機械で引けない。ただし A10 のとおり自由文はパイプライン不要という利点があり、Markdown 本文は残した |
| MADR をそのまま採用 | decision-makers はあるが権限ランク・確信度・可逆性・agent_mode が無い。拡張前提で採用 |
| JSON/YAML のみで DB なし | 優先規則・有効期間のクエリ、不変性の強制（トリガ/CHECK）が書けない。件数が少ない初期には十分かもしれない（C担当と調整） |
| 確信度を LLM が自己申告し閾値で動かす | 較正の根拠が無い。confidence_basis（根拠種別）を併記し、F の較正実験まで閾値は仮置きとした |
| 判断を1つの巨大 Markdown に連結 | A07: 100件超のログは保守困難。A01: 大きい文書は読まれない |
| 実名を decider に入れる | CLAUDE.md の実データ禁止ルール。仮名ハンドルのみ |
| Qodo 経由「rationale 付きで開発時間 -10.1%」を効果根拠に採用 | 元プレプリント未確認（A16） |

## 4. 未解決・不確実な点

1. 本提案のスキーマが判断再現率を上げる定量根拠が無い。F のバックテスト（過去判断を伏せて再現）が必要。
2. 確信度・閾値(0.8/0.5)の較正方法。
3. Markdown（正）と SQLite（索引）の同期方法と食い違い検出。
4. 権限ランクが大域（`role` 表）のみ。部署・領域ごとの権限、上司と先輩の矛盾の扱い。
5. `link_supersede` トリガは supersede する側の権限（`required_role`）を検査しない。エージェントが人の決定を supersede できてしまう。アプリ層または追加トリガで検査が要る。
6. `valid_until` 切れ・`review_by` 超過の通知は DDL に無い（view のみ）。運用はF担当。
7. 暗黙知・ログに現れない判断の記録（`deviation_note` 種別は用意したが抽出手順は B）。A09 によれば、組織知識に依存する決定はLLMでの検証が弱い。
8. scope マッチ（glob と task_type の判定）の実装は未検証。
9. Tyree & Akerman のテンプレ項目、Y-statement が Zdun et al. 2013 で定義されたか、Mem0 本文、Letta 公式ページ本体、Graphiti のフィールド名は未確認。
10. A08・A09 は ADR（チームの設計判断）の研究。個人の判断基準（好み・価値観）の記録へ転用できる保証は無い。`kind=principle/preference` の扱いは追加調査が要る。
11. 「decision rule」型（「X の時は Y を優先」）を別構造にすべきか、decision の一種で十分かは未決。

## 5. 試した検索クエリ一覧

- WebFetch: cognitect.com Nygard 記事、adr.github.io/madr、adr.github.io、arxiv.org/abs/2310.08560、/2501.13956、/2604.03826、/2602.07609、code.claude.com/docs/en/memory、ozimmer.ch ADR 記事、tianpan.co 記事、github.com/getzep/graphiti、SEC の Amazon 2016 株主書簡
- WebFetch 失敗: help.getzep.com/graphiti/core-concepts/temporal-agents（404）
- WebSearch: 「Y-statements architecture decision In the context of facing we decided ... Zdun」「architecture decision records LLM agents decision log rationale retrieval arXiv 2025」「Mem0 arXiv production-ready AI agents scalable long-term memory」「Tyree Akerman Architecture Decisions: Demystifying Architecture ... template」「Letta docs memory blocks core memory archival memory agent self-editing」
- 未実施（次ラウンド候補）: Anthropic の context engineering 記事、decision record を使う agent 研究（AgenticAKM arXiv:2602.04445 は検索結果で存在のみ確認・本文未取得）、日本語での ADR 運用事例、Generative Agents の重要度/reflection、確信度較正の文献
