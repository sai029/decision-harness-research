# 担当C ラウンド1: 格納形式とストレージ設計

出典 ID は `notes/sources.md` の C01〜C16。「確認」= 取得または実測で確認、「推測」= 私の推論。

## 0. 再調査の結果（E1 の C 部分 / E3 / E4 の C 部分 / E9 / E12）
実行物はすべて `work/ddl/`。ログ: `c_r2_run.log`（30/30 PASS）、`c_ja_eval.log`、`c_schema_r2_cli.log`。
- E1（C の必須要件）: §2.9 に要件 R-C1〜R-C8 と、C の列から A の `unified_schema.sql` の列への対応表を書いた。統合版 DDL への反映確認は A の完成待ち（**未解決**）。
- E3: **解消**。supersede は新旧とも approved のときだけ通る。「proposed が approved を supersede」は拒否される（§2.10、ログ E3-1〜7）。
- E4（C の v_active 部分）: 期限切れ・superseded・valid_to 済み・scope 違いの除外、矛盾2件の同時ヒット、タグ誤発火率を SQL 層と合成データで測った（§2.11）。D のフック本体への組込みは C の範囲外で**未実施**。
- E9: **C のスキーマ内で解消**。1つの優先規則（R0〜R3）、SQL、`decision_conflict` 表、6シナリオの実行結果（§2.12）。A・F の規則との一本化は統合時に必要（**未解決**）。
- E12: 方針は整合させた（本文・抜粋を複製しない。hash のみ）。形態素解析が「不要」とは測定で言えなかった（recall は同等、precision は janome が +0.06、誤ヒットの型が違う）。解消ではなく**部分解消**（§2.13）。

## 1. 要約
- 推奨は4層のハイブリッド。(1) Markdown+YAML frontmatter を Git で持つ正本、(2) SQLite の再構築可能な派生索引（FTS5 trigram、エッジ表、時間列）、(3) 必要になった時だけ sqlite-vec、(4) stdio の小型 MCP サーバーで Claude Code に公開。
- Graph DB（Neo4j/FalkorDB 等）は初期は採らない。判断の件数（数百〜数千）なら、エッジ表と再帰 CTE で足りる（C16 で supersede 連鎖を実測）。Graphiti/Zep は「会話から事実を自動抽出して時間管理する」用途に強いが、判断記録の承認ワークフローは持たない（C03, C04）。
- 正本を Markdown+Git にする理由は、人間の承認を PR で取れること、差分と履歴が残ること、索引が壊れても再構築できること。`CLAUDE.md` は助言であり強制力がない（C01）ので、承認状態の強制は DB の CHECK 制約と MCP サーバー側で行う。
- SQLite の DDL は実際に流して通した（sqlite3 3.47.2）。トリガ、FTS5 trigram、as-of 照会、再帰 CTE、制約違反6件、vec0 の KNN まで動いた。ログは `work/ddl/`。
- 実測で見つけた制約。trigram は2文字以下の語が引けない（`削除` が0件）。LIKE へのフォールバックが要る。
- 実測で見つけた設計の穴。最初の版では project スコープの判断が global の判断を自動失効させてしまった。同一 scope のみ失効するようトリガを直した。さらに E3 の指摘で、proposed の行でも approved を失効できる穴が見つかり、ガードを足した（再調査）。
- 既存実装で近いもの: Basic Memory（Markdown+SQLite+MCP、ただし AGPL-3.0、C14）。公式の memory MCP サーバーは JSONL のみで、時間・承認の列がない（C06）。
- Kuzu はアーカイブ済み（2025-10-10、C13）。組込みグラフ DB の候補から外す。GraphRAG はメンテナンスモード（C12）で、判断記憶には過剰。

## 2. 提案

### 2.1 全体構成
```
repo/
  decisions/
    DEC-0001.md            # 正本。PR でレビュー・承認
  decisions/_inbox/        # AI が抽出した proposed。承認までは権威なし
  .claude/rules/decisions.md   # decisions/** を触る時だけ効く規則（C01）
  .mcp.json                # project スコープで MCP サーバー登録（C02）
  memory/index.sqlite      # 派生索引。.gitignore。再構築可能
  memory/schema.sql        # work/ddl/c_schema.sql と同じ
```
- 書込み経路は一方向。Markdown → 索引再構築。DB を直接編集しない。
- AI が書けるのは `_inbox/` の `status: proposed` だけ。`approved` への昇格は人間の PR マージ。
- 根拠: C01（CLAUDE.md は強制でない）、C14（同型の先行例）。確認できた/推測: 構成の妥当性は推測、部品の挙動は確認。破綻しうる条件: 複数人が同時に大量の判断を書く運用（Git のマージ競合が増える）。

### 2.2 正本の frontmatter（例は合成データ）
```markdown
---
id: DEC-0002
title: DBは PostgreSQL にする
status: approved          # proposed|approved|superseded|revoked
reversibility: reversible # reversible|one_way
authority: agent_ok       # agent_ok|needs_human
confidence: 0.8
scope: proj-x
decided_by: role:lead     # 実名は入れない
valid_from: 2026-06-01
valid_to: null
recorded_at: 2026-06-01
expires_at: 2027-06-01
supersedes: [DEC-0001]
depends_on: []
tags: [db]
evidence:
  - {kind: chat, ref: "chat-export#msg-123", sensitivity: internal}
---
複数ユーザーの同時書込みが発生するため。前提: 同時接続は10以上。
```
- 本文は「判断・理由・前提」。フィールドの最終形は担当 A の ADR スキーマに合わせて調整する（ここは暫定）。
- 根拠: C16（この形を DDL に写して通した）。推測: 項目の過不足。

### 2.3 SQLite DDL（実行済み）
全文は `work/ddl/c_schema.sql`。要点だけ示す。

| 要素 | 内容 |
|---|---|
| `decision` | 状態・可逆性・権限・確信度・valid_from/valid_to（実世界の時間）・recorded_at（記録時間）・expires_at |
| CHECK 制約 | proposed は agent_ok 不可。one_way は agent_ok 不可。valid_to >= valid_from |
| `decision_edge` | supersedes / contradicts / depends_on / refines。自己参照禁止、FK あり |
| `evidence` | 根拠への参照。本文は複製せず ref のみ。sensitivity 列でアクセス制御に備える |
| `open_question` | 非同期キュー。`default_used` に、待たずに採った保守的既定を残す |
| `decision_fts` | FTS5、`tokenize='trigram'`、external content（二重保存なし）、INSERT/UPDATE/DELETE トリガで同期 |
| `edge_supersede` トリガ | 同一 scope の supersedes 追加時だけ旧判断を superseded にして valid_to を設定 |
| `v_active` | approved かつ valid_to が NULL かつ期限内。注入対象 |

実行ログ（`work/ddl/c_ddl_run.log`）の確認事項:
- 同一 scope の supersede で DEC-0002 が失効し、scope 違いの DEC-0001 は有効のまま。
- as-of 2026-03-01 の照会が当時有効だった判断を返す。
- trigram で `外部公開` が bm25 順に引ける。`削除`（2文字）は 0 件、LIKE なら引ける。
- 再帰 CTE で supersedes 連鎖をたどれる（DEC-0002 → DEC-0001）。
- UPDATE 後の FTS 同期と `integrity-check` がエラーなし。
- 不正な INSERT 6件（日付逆転、不正 status、proposed+agent_ok、one_way+agent_ok、自己エッジ、存在しない FK）は全て Error。
- 親の削除でエッジが CASCADE で消え、`open_question.related_id` は NULL になる。

根拠: C07（FTS5 仕様）、C16（実測）。確認できた: 上記の挙動。推測: 日本語の検索精度（件数が少なく、合成データ4〜5件で測っただけ）。
破綻しうる条件:
- 本文が長文化し、trigram の索引が肥大する（未計測）。
- 2文字語が多い領域（略語・固有名）で LIKE の全走査が遅くなる。
- `PRAGMA foreign_keys` は接続ごとに ON が必要。MCP サーバーの接続初期化で必ず設定する。
- SQLite の別バージョンで trigram が無い場合（3.34 未満は推測。取得した FTS5 文面にはバージョン記載なし）。

### 2.4 検索（ハイブリッド）の段階
1. 絞り込み: `scope IN (現在のproject,'global')` かつ `v_active`。まず構造フィルタで母集団を小さくする。
2. 語彙検索: FTS5 trigram（3文字以上）。2文字以下は LIKE。
3. 意味検索（任意）: FTS で再現率が足りないと測定で分かった時だけ sqlite-vec を追加。
4. 統合: RRF（Reciprocal Rank Fusion）で順位統合。pgvector 側の文書でも併用法として挙げられている（C15）。
5. グラフ展開: ヒットした判断の `supersedes`/`contradicts`/`depends_on` を1〜2ホップ辿って付ける。
6. 衝突解決: global と project の両方がヒットしたら project を優先、など優先規則をアプリ側で適用（2.7 参照）。

sqlite-vec は実測で動いた（Windows、Python 3.11、sqlite-vec 0.1.9、`c_vec_run.log`）。`vec0` に partition key で scope を持たせた KNN が通った。ただし pre-v1 で破壊的変更がありうる（C08）。埋め込みモデルは未選定で、日本語での精度は未測定。
破綻しうる条件: Python ビルドが `enable_load_extension` を無効にしている環境（一部の OS 同梱 Python で起こるとされるが、本調査では未確認＝推測）。その場合は FTS のみで運用する。

### 2.5 MCP サーバー設計（stdio、project スコープ）
`.mcp.json` に登録する。project スコープは初回に承認プロンプトが出る（C02）。

| ツール | 動作 | 権限 |
|---|---|---|
| `decisions_search(query, scope, as_of?)` | 2.4 の手順。上限 N 件、各件は要約+id | 読取 |
| `decisions_get(id)` | 本文・根拠 ref・エッジ | 読取（sensitivity=restricted は伏せる） |
| `decisions_propose(draft)` | `_inbox/` に proposed の Markdown を書く。status は強制的に proposed | 書込（inbox のみ） |
| `questions_enqueue(q, default_used, related_id?)` | `open_question` に積む。呼出し側は待たない | 書込 |

- 出力は小さく保つ。Claude Code は MCP 出力が 10,000 tokens で警告、既定 25,000 tokens で打切り（C02）。ツール定義は tool search で必要時のみ読込まれる（C02）ので、ツール数を増やしても常時コストは増えにくい。
- `approved` の書換えツールは作らない。承認は Git 側で行う。
- 本文に含まれる文字列は、モデルから見ればデータであり指示ではない。ログ由来のテキストにプロンプトインジェクションが混ざりうる（C02 の警告）ため、返却時に「引用データ」として囲む。これは担当 F・D と詰める。
- 根拠: C02、C06（公式 memory サーバーは削除系を含む9ツールで、承認や時間の概念がない）。推測: 4ツールで足りるか。
破綻しうる条件: 一度に注入すべき判断が多く、1回の出力上限を超える場合（段階的開示との設計が必要、担当 D）。

### 2.6 手順（実装順）
1. `decisions/` と frontmatter を決める（A と合意）。
2. `schema.sql` から索引を作る再構築スクリプトを書く（Markdown を読んで INSERT。**未実装**）。content_hash が変わった行だけ更新する。
3. pre-commit/CI で frontmatter の検証と再構築テストを回す（Hooks の強制は D・F と整合）。
4. MCP サーバーを実装し `claude mcp add --scope project` で登録（C02）。
5. 小さなバックテスト（F の評価）で、FTS のみと FTS+vec を比較し、vec を入れる価値を測る。

### 2.7 未決の設計穴（実測で判明）
- ~~global と project の衝突時の優先規則~~ → §2.12 で規則 R0〜R3 を定義し、実行確認した（再調査）。`v_active` 自体は scope と優先規則を適用しない（`c_effective.sql` が適用する）。A・F との一本化は未了。
- 期限切れ（`expires_at`）の判断を「無効」にするか「要再確認」にするか。現在は view から外すだけで、再確認の依頼はキューに積まない。

### 2.8 方式比較

| 方式 | 強み | 弱み | 判断記憶への適合 | 根拠 |
|---|---|---|---|---|
| Markdown(Git) | 人間が読める、PR 承認、差分・履歴、再構築の正本 | 構造検索・時点照会が弱い | 正本として最適 | C01, C14 |
| JSON/YAML のみ | 機械可読。memory MCP サーバーが JSONL を採用 | 承認フロー・検索は自前 | frontmatter としてのみ採用 | C06 |
| SQLite | 単一ファイル、FTS5、制約、トリガ、再帰 CTE | 同時書込みに弱い、意味検索は拡張が要る | 派生索引として最適 | C07, C16 |
| PostgreSQL+pgvector | 同時書込み、HNSW/IVFFlat、全文検索と併用 | 運用負荷が高い | 複数人が書く規模になったら移行 | C15 |
| Vector DB 単独 | 曖昧な言い換えに強い | 時間・承認・矛盾管理ができない、説明しにくい | 補助。単独は不採用 | C08（拡張としての位置づけ） |
| Graph DB（時間付き KG） | 関係の多段探索、bitemporal を標準で持つ（Graphiti） | 運用重い、抽出は LLM 依存で誤りを含む | 件数が増え多段関係が主になるまで保留 | C03, C04 |

### 2.9 E1: C の必須要件と、統合スキーマへの対応表
E1 の統合スキーマは A が `work/ddl/unified_schema.sql` に作成中。C が譲れない要件を、実行して確かめられる形で書く。検証は `c_r2_test.py`（C のスキーマに対して実行済み）。統合版に対しては、同じ観点で A が流す必要がある。

| ID | 必須要件 | 検証 | 確認/推測 |
|---|---|---|---|
| R-C1 | bitemporal を2軸で持つ。実世界の有効期間(valid_from/valid_to)と記録時間(recorded_from/recorded_to)を**版ごとに**残し、「9月に分かった訂正を知る前の8月時点で、7/15 は有効だったか」を答えられる | テスト BT の3件。`decision_history` を Git 履歴から作る | 確認（C のスキーマで実行） |
| R-C2 | 派生索引は Markdown(Git) と `governance/role_grant.csv` だけから空の DB に再構築でき、正準ハッシュが一致する。DB にしか無い状態を作らない | テスト RB-1〜5（再構築2回のハッシュ一致、integrity_check、FTS integrity-check） | 確認 |
| R-C3 | 日本語の全文検索が引ける（FTS5 trigram + 2文字以下は LIKE）。FTS は external content で、INSERT/UPDATE/DELETE トリガ同期 | c_ddl_run.log、RB-5、c_ja_eval.log | 確認（小規模） |
| R-C4 | supersede は新旧とも approved、かつ旧が needs_human なら新も needs_human のときだけ有効。status の直接 UPDATE も同じ条件で縛る | テスト E3-1〜7 | INSERT 経路は確認。**直接 UPDATE は C の DDL に無い**（A の `trg_dec_st_gate_supersede` に任せる。未検証） |
| R-C5 | scope は (現在の project, global) の鎖。優先規則 R0〜R3 と、決まらない場合の矛盾チケット | テスト E9-1〜8 | 確認 |
| R-C6 | 根拠は参照(ref)と quote のハッシュで持ち、本文・抜粋の複製を DB と Git に作らない | RB-6 | 確認（C のスキーマ）。A の `evidence.quote`（300字まで）とは**衝突**（§2.13） |
| R-C7 | 接続ごとに `PRAGMA foreign_keys=ON`。日時は ISO8601 の `YYYY-MM-DD` 文字列で統一（比較が文字列比較のため。混在すると壊れる） | c_ddl_run.log の FK 違反テスト | 確認 / 混在時の破綻は推測 |
| R-C8 | 衝突検出は topic_key（または明示の conflicts リンク）で行える | テスト E9 の `topic_key` と contradicts エッジの両方 | topic_key は確認。contradicts エッジ経路は SQL にあるが、テストでは使っていない（**未検証**） |

C の列 → `unified_schema.sql` の列（暫定。A のファイルの該当部分 82〜190 行を読んだだけで、**実行はしていない**）:

| C | unified（A） | 備考 |
|---|---|---|
| decision.id | decision.decision_id | |
| body | decision_text + rationale | |
| status proposed | candidate | C の `approved/superseded/revoked` は同名 |
| reversibility (2値) | reversibility (4値) | reversible → two_way または costly、one_way → one_way。C は unknown を持たない |
| authority agent_ok/needs_human | agent_mode | follow, follow_and_log → agent_ok。ask_async, human_only → needs_human |
| valid_to | valid_until | |
| recorded_at | recorded_at | |
| （decision_history の recorded_to） | invalidated_at | A は1列のみ。版ごとの履歴が無い → R-C1 を満たさない恐れ（下記） |
| scope | scope_project（+ decision_scope, scope_path） | |
| decided_by（役割名） | decided_by → principal | |
| approval_ref | approval 表 | E2 は A が担当 |
| topic_key | 対応する列なし | R-C8 のため要追加、または conflicts_with リンクで代替 |
| overridable | link_type 'overrides' で近似 | 意味が同じかは未確認 |
| role_grant (role, scope, rank) | authority_grant | A は (主体, scope) ごと。同じ発想 |
| decision_edge | decision_link | contradicts → conflicts_with |
| decision_conflict | conflict_ticket | |
| evidence.ref/kind/quote_sha256 | evidence.source_id + quote | §2.13 |
| open_question | review_queue | A が1本化 |
| decision_history | **無し** | 要追加 |

R-C1 の懸念（推測。A のファイルの読解のみ）: A は `valid_until` を承認後に短縮できる（`trg_dec_valid_until_shrink`）。短縮は同じ行の上書きなので、版履歴が無ければ「短縮前にどう認識されていたか」が DB から消える。`invalidated_at` の1列では、2回以上の訂正や、valid_from の訂正は表せない。
破綻しうる条件（R-C1/R-C2 共通）: Git 履歴を書き換える運用（rebase、squash マージ）をすると `decision_history` の recorded_from が変わる。履歴を保つ運用（merge commit または、履歴を別途保存）が前提。コミット日時は author date を使ったため、日付の偽装は可能（承認の証明にはしない）。

### 2.10 E3: supersede ガード（解消）
- 変更: `edge_supersede_guard`（BEFORE INSERT ON decision_edge）を追加。`rel='supersedes'` のとき、(a) src が approved でなければ ABORT、(b) dst が approved でなければ ABORT、(c) dst が needs_human で src が agent_ok なら ABORT。DDL は `work/ddl/c_schema_r2.sql`。
- 再構築側: Markdown の `status` は `proposed|approved|revoked` のみ。`superseded` は索引が導出する。エッジは src.valid_from の昇順に挿入し、ガードに拒否されたエッジは `rejected_edges` に記録して続行する（`c_rebuild.py`）。
- 実行ログ（`c_r2_run.log`、全て PASS）:
  - E3-1 proposed の DEC-0005（`_inbox` 由来）が approved の DEC-0002 を supersede → 拒否 `supersede: src must be approved`。
  - E3-2 拒否後も DEC-0002 は approved のまま、`v_active` に残る。
  - E3-3 agent_ok の DEC-0017 が needs_human の DEC-0018 を supersede → 拒否。
  - E3-4 approved 同士・同 scope の DEC-0015 → DEC-0016 は有効で、DEC-0016 が superseded（valid_to = 新判断の valid_from）。
  - E3-5〜7 直接 SQL の INSERT で、proposed が端点・superseded 済みが端点・revoked が src のいずれも拒否。
- 根拠: E-review の指摘本文、`c_r2_run.log`。確認できた: 上記の挙動。
- 破綻しうる条件: (1) `UPDATE decision SET status='superseded'` を直接実行されると、C の DDL は止めない（A の `status_transition` ゲートが必要）。(2) `approval_ref` は自由文字列なので、approved の行そのものを偽造して INSERT できる（E2。A の `approval` 表で扱う）。(3) 承認後に src が revoked になっても、既に失効させた dst は自動で復活しない（未設計）。

### 2.11 E4（C の v_active 部分）: 除外と矛盾ヒット、タグ誤発火
範囲: C が持つのは SQL 層（`v_active` と `c_effective.sql`）。D の `inject_hook.py` は D の成果物で、C は編集していない。以下はフックがこの SQL を呼ぶ場合の結果。
- 除外（`c_r2_run.log` E4-1〜6、PASS）: 期限切れ（expires_at が過去）、superseded、valid_to 済み（事後訂正で終了）、proposed は `v_active` に出ない。scope 違い（proj-z）は proj-x の対象に出ない。proj-y から見ると global の DEC-0001 が残り、proj-x の DEC-0002 は出ない。
- 矛盾する2件の同時ヒット: 同 rank の別人（DEC-0009 と DEC-0010）は `conflict=1` で**両方**返り、`decision_conflict` にチケットが1件作られる（再実行しても増えない）。呼び出し側は conflict=1 の組を「未決の矛盾」として注入し、保守的な選択をして `review_queue` に積む（動作表は A/F と統合）。
- タグ逆引きの誤発火（`c_ja_eval.log`。合成プロンプト30件、語彙12語、正解は私が付けた。語彙の重なりは意図的に作ったので、率は実運用の値ではない）:

| 方式 | 発火 | 誤発火 | 誤発火率 | 再現率 |
|---|---|---|---|---|
| 部分文字列（D の現行方式） | 39 | 9 | 0.23 | 1.00 |
| 語彙の最長一致＋重なり抑止 | 34 | 4 | 0.12 | 1.00 |
| janome の完全一致 | 31 | 3 | 0.10 | 0.93 |

  誤発火の型: 「ログ」が「ログイン」「カタログ」「ダイアログ」、「管理」が「管理者」「管理職」、「DB」が「DBA」。最長一致は前者（語彙内の包含）を直すが、語彙外の語（カタログ）は直せない。janome は「管理者」を「管理」+「者」に割り、取りこぼしが出た。
- 根拠: C16/C18。確認できた: 上記の数値（合成）。推測: 実プロンプトでの率。
- 破綻しうる条件: 語彙が増えると包含関係が増える。語彙外の語は最長一致では防げない。**フック本体への反映と、実フックでの確認は未実施**。

### 2.12 E9: 優先規則と矛盾の扱い（C のスキーマ内で解消）
大域ランクをやめ、ランクは `role_grant(role, scope, rank)` で scope ごとに持つ。同一 scope 内でしか比較しない。順序は次の1本（`c_effective.sql` に SQL）。

| 順 | 規則 | 結果 |
|---|---|---|
| R0 | global で `overridable=0`（全社ポリシー）は、狭い scope の判断より常に優先 | 狭い方を落とす |
| R1 | scope が異なる（global と project）: 狭い方が勝つ | global を落とす（そのプロジェクトのみ） |
| R2 | 同一 scope: `role_grant.rank` が高い方。どちらかに権限表が無ければ決めない | 勝者、または tie(no_rank) |
| R3 | rank 同値: 同一人物なら valid_from が新しい方。別人なら決めない | 勝者、または tie(same_rank_diff_person) |
| tie | 決まらない | `decision_conflict` にチケット。両方を conflict=1 で返す。どちらも落とさない |

- 順序を決めた理由（推測。設計判断）: 全社ポリシーは project の裁量で外せないため R0 を最上位にした。confidence は自己申告（エージェントが付けうる）なので順序に使わない。A は `confirmed > 権限 > 新しさ > 確信度`、F は `権限 > 新しさ > 具体性`、A §2.5 は scope の狭さを3番目に置く。C の規則はこれらと**順序が違う**ので、統合時に A・F と1本にする必要がある（未解決）。
- 合成シナリオの実行結果（`c_r2_run.log` E9-1〜8、全て PASS。ランク: proj-x で boss=3、senior-a=2、senior-a2=2、lead-x=1、senior-b は権限なし）:

| シナリオ | 組 | 結果 |
|---|---|---|
| global vs project | DEC-0001(boss, global) / DEC-0002(lead-x, proj-x) | proj-x では DEC-0002（R1）。proj-y では DEC-0001 のまま |
| 全社ポリシー vs project | DEC-0003(overridable=0) / DEC-0004 | DEC-0003（R0）。DEC-0004 は落ちる |
| 上司 vs 先輩（先輩の方が新しい） | DEC-0007(boss, 2/1) / DEC-0008(senior-a, 6/1) | 上司（R2）。新しさより権限が先 |
| 同 rank の別人 | DEC-0009(senior-a) / DEC-0010(senior-a2) | tie。チケット1件、両方 conflict=1 |
| 権限表に無い人 | DEC-0011(senior-b) / DEC-0012(senior-a) | tie(no_rank)。チケット |
| 同一人物の新旧 | DEC-0013(2/1) / DEC-0014(5/1) | 新しい方（R3） |

  proj-x の注入結果: DEC-0002, 0003, 0007, 0009(conflict), 0010(conflict), 0011(conflict), 0012(conflict), 0014, 0015, 0018。
- 「上司と先輩が別部署」: 先輩 B のように、その scope に権限が無い人の判断は rank が付かず、tie（no_rank）になる。人間に聞く（review_queue）に回る。部署をまたぐ権限の定義は規則側では決められない（権限表を誰がどう作るかは未解決）。
- チケットの状態: `decision_conflict.state` は DB にしか無い状態で、再構築すると失われる。チケットは勝者が決まれば消える派生物とし、「解決」は Markdown に新しい承認済み判断（または role_grant の更新）を足すことで表す。この再構築後の挙動は**未検証**。
- 根拠: E-review E9、C18。確認できた: 表の挙動。破綻しうる条件: 3件以上が連鎖して衝突する場合、組ごとに独立に判定するため、推移律が成り立たない（A>B>C>A）ケースがありうる（未検証）。topic_key の付け忘れ（検出漏れ）。

### 2.13 E12: 日本語検索の実測と、抜粋の保管ルール
**(a) evidence の方針整合。** C のスキーマは `excerpt` 列を廃止し、`ref`（300字まで）と `quote_sha256` だけにした。引用の検証は、検証ジョブが ref 先のソースを読んで hash を照合する。本文が Git・DB のどちらにも複製されない。
- A の統合版は `evidence.quote`（300字まで、`quote_verified`）を持つ。これは B の quote 検証の要件を満たすが、C の方針とは衝突する。Git は追記専用で、一度コミットした抜粋を後から消すには履歴の書換えが要る（保持期間の運用ができない）。**C の推奨**: 抜粋を残すなら、(1) sensitivity が restricted のソースは hash のみ、(2) 抜粋は Git に入れず、再構築対象外の別テーブル（保持期間つきで削除可能）に置く。ただし (2) は R-C2（DB にしか無い状態を作らない）と緊張関係がある。A が決める（未解決）。
- 確認できた/推測: スキーマの挙動は確認（RB-6）。Git 履歴からの抜粋削除が難しいことは Git の一般的な性質で、本調査で取得した出典は無く推測。

**(b) 形態素解析は要るか。** `c_ja_eval.py`（janome 0.5.2。文書36・クエリ24・top5。文書、クエリ、正解は合成で私が作った。語彙の重なりを意図的に設計）。

| 方式 | recall@5 | precision@5 | 備考 |
|---|---|---|---|
| trigram + LIKE（2文字以下） | 0.74 | 0.67 | 依存なし |
| unicode61（既定） | 0.00 | 0.00 | 連続した日本語が1語になり、部分語が引けない（この合成での値） |
| janome → unicode61 | 0.75 | 0.73 | 索引サイズは trigram の約64%（352 / 552 KiB、4,032行）、構築は 4.3 秒 vs 0.1 秒 |

- 型別（recall/precision）: 部分文字列の罠（ログ vs ログイン、管理 vs 管理者。n=4）は trigram+LIKE が 0.75/0.72、janome が 1.00/0.84。活用・語形違い（n=11）は 0.73/0.70 と 0.73/0.74 でほぼ同じ。短い語（n=6）は 0.78/0.65 と 0.72/0.59。言い換え（n=3）はどちらも取りこぼす。
- 読み取れること（推測を含む）: recall は同等で、janome の利点は「ログ」が「ログイン」に当たる型の誤ヒットを減らすこと。n=24 なので差が有意とは言えない。**「形態素解析は不要」と判断できる測定にはなっていない**。方針: 既定は trigram+LIKE（依存なし、辞書で索引が変わらない）。誤ヒットが問題になったら janome を足すが、辞書の版を固定して再構築で再現できるようにする。MeCab 本体・ICU は未導入で未測定。
- 破綻しうる条件: 実データの語彙・文体は合成と違う。janome の辞書更新で索引が変わる。純 Python のため大量文書の構築が遅い（4,032件で 4.3 秒。これより大きい規模は未測定）。
- 根拠: C07、C17、C18。

## 3. 検討して棄却した案と理由
| 案 | 棄却理由 | 確認/推測 |
|---|---|---|
| Graphiti+Neo4j/FalkorDB を最初から採用 | 対応 DB はサーバー型（Neo4j 5.26、FalkorDB 1.1.2、Neptune）で運用が重い。参照 MCP サーバーは認証なし・本番非推奨（C03）。承認フローがない | 確認 |
| Kuzu（組込みグラフ DB） | リポジトリがアーカイブ済み（C13） | 確認 |
| GraphRAG | メンテナンスモードで、インデックス作成が高コスト（C12）。判断は少数の構造化レコードで、大量文書の要約用途と合わない | 確認 |
| 公式 memory MCP サーバーをそのまま使用 | JSONL のみ、時間・承認・可逆性の列がない。delete 系ツールで承認済み記録を AI が消せる（C06） | 確認 |
| Basic Memory をそのまま採用 | 方向性は近いが AGPL-3.0（C14）で、社内利用・配布時の条件確認が要る。承認状態の制約は持たない（取得文面に記載なし＝推測） | 一部推測 |
| Letta のメモリブロックを正本にする | ブロックは文字数上限つきの常時コンテキスト、値の全置換で並行書込みが上書きされうる（C10）。履歴・承認の用途に合わない。長期の判断集合ではなく常時表示の要約向き | 確認 |
| Mem0 を採用 | 保管先と MCP 対応を README から確認できず（C11）、評価不能。判断の承認・失効の仕組みは確認できていない | 未確認 |
| Vector DB のみで運用 | 時間・失効・矛盾が扱えず、なぜその判断が出たか説明しにくい。再現性の検証も難しい | 推測 |
| FTS5 の unicode61 | 取得文面では CJK への言及がなく、連続した漢字・かなが1語になる可能性（C07 からの推測。未実測）。trigram を実測で採用 | 推測 |

## 4. 未解決・不確実な点
1. 検索精度の定量比較（FTS のみ vs +vec）は未実施。合成データが4〜5件では測れない。F のバックテスト用データセットが要る。
2. 日本語の形態素解析は janome のみ、合成24件で比較した（§2.13）。MeCab/ICU は未測定。実データでの比較は未実施。
3. Zep 論文の数値（DMR 94.8% など）は著者自身の評価（C04）。第三者の検証は未確認。
4. Mem0 の保管先とグラフ機能、Letta の現行ストレージ（letta-code に移行）は一次情報で未確認。
5. Graphiti の最新リリース番号は取得できず（Releases が空）。Graph DB へ移行する閾値（件数・多段クエリの頻度）は推測で、基準を決められていない。
6. 再構築スクリプトは再調査で実装した（`c_rebuild.py`。YAML は部分集合のみで PyYAML は未使用）。MCP サーバー本体は未実装で、Claude Code からの実呼び出しは未検証。
7. 期限切れの扱い（無効か要再確認か）は未決。優先規則は §2.12 で定義済みだが、A・F との一本化、推移律が崩れる連鎖衝突、contradicts エッジ経路、再構築後のチケット挙動は未検証。
7b. 統合版（A の `unified_schema.sql`）への反映: R-C1（版履歴）、R-C8（topic_key）、R-C6（抜粋の保管）が未反映の恐れ。A のファイルは読んだだけで実行していない。
8. C02 のページ後半（56k字）と FTS5 後半（72k字）は未読。必要な記述が後半にある可能性がある。
9. Windows 以外（macOS 同梱 Python の拡張ロード）は未検証。
10. 並行書込み: SQLite を MCP サーバー1プロセスが専有する前提。複数エージェントが同時に書く場合の挙動は未検証。
11. Web 取得は要約モデル経由で、逐語確認ではない（ライセンスや数値は再確認が要る）。pgvector のライセンスは取得文面から不明。

## 5. 試した検索クエリ一覧
再調査: Web 検索は使っていない。`pip install janome` のみ実施（実在と版 0.5.2 を確認、出典 C17）。自前実験は C18。
Web 検索ツールは使わず、URL を直接取得した。取得先は次のとおり。
- code.claude.com/docs/en/memory（CLAUDE.md、auto memory）
- code.claude.com/docs/en/mcp（MCP の追加、スコープ、出力上限）
- github.com/getzep/graphiti
- arxiv.org/abs/2501.13956（Zep）
- arxiv.org/abs/2310.08560（MemGPT）
- github.com/letta-ai/letta
- docs.letta.com/guides/agents/memory-blocks
- github.com/mem0ai/mem0
- github.com/microsoft/graphrag
- github.com/kuzudb/kuzu
- github.com/basicmachines-co/basic-memory
- github.com/pgvector/pgvector
- github.com/asg017/sqlite-vec
- github.com/modelcontextprotocol/servers/tree/main/src/memory
- sqlite.org/fts5.html

実測の成果物:
- `work/ddl/c_schema.sql`（DDL）
- `work/ddl/c_test.sql`（テスト）
- `work/ddl/c_ddl_run.log`（実行ログ）
- `work/ddl/c_vec_run.log`（sqlite-vec）
- 再調査: `c_schema_r2.sql`、`c_effective.sql`、`c_rebuild.py`、`c_r2_test.py`、`c_r2_run.log`、`c_schema_r2_cli.log`、`c_ja_eval.py`、`c_ja_eval.log`
