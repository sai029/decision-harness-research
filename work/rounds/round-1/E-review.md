# E レビュー: ラウンド1（A, B, C, D, F）

入力は `A.md B.md C.md D.md F.md`、`notes/sources.md`、`work/ddl/` と `d-test/` の実物。
注意: 私の環境にはシェルが無く、DDL の再実行はしていない。下の「DDL の不具合」は DDL 本文と実行ログの読解による。解消の確認には担当が実行ログを示すこと。
修正は加えない。指摘のみ。

## 総評（事実のみ）
- 各担当は「確認」と「推測」を分けて書いており、記述の誠実さは高い。
- 一方、5担当が互いに非互換なスキーマを別々に作っている。
- 各担当が確かめたのは「DDL が通る」「制約が働く」までで、「判断再現率が上がる」は誰も示していない。
- 「承認」の強制が、各 DDL では自由記述の `approved_by` 列にすぎない。

## 指摘

### E1. スキーマが5本に分裂している（設計変更要 / A, B, C, D, F）
- 根拠:
  - 可逆性: A は `two_way|costly|one_way`、C と D は `reversible|one_way`、F は `R0|R1|R2`、B は `one_way|reversible|unknown`。
  - 権限: A は `agent_mode`（4値）、C は `agent_ok|needs_human`、D は `agent_ok|notify|human_required`、F は `A0|A1|A2`。
  - 状態: A は `proposed|accepted|superseded|deprecated|rejected`。C は `approved|revoked`。F は `candidate/approved/…/quarantined`。
  - 正本: C は Markdown(Git)、A は Markdown が正で DB は索引、D と F は DB 直書き。
  - 表名: `decision`（A, C, D）と `memory_entry`（F）、B は `decision_candidate`。
  - F 自身も §4 で「A〜D の最新出力は未読」と書いている。
- 解消とみなす条件: 単一の統合スキーマ（列・列挙値・状態遷移図）を1つ示す。
- 統合スキーマの要件:
  - 各担当の必須要件を含める: A の可逆性・期限・優先規則、B の quote 検証、C の bitemporal、D の tier・trigger、F の consent・source・trust_tier・eval。
  - 統合版の DDL を実行したログを `work/ddl/` に残す。
  - 各担当の旧列から新列への対応表を付ける。

### E2. 「承認」の強制が名目だけ（設計変更要 / A, B, C, F）
- 根拠:
  - A、C、F の CHECK は `approved_by IS NOT NULL` だけを見る。B の `confirmed_by` も同様。
  - `approved_by` は自由文字列なので、エージェントが任意の値を書けば通る。
  - 現状の防御は「エージェントは approved に書かない」という運用の約束だけで、DDL の外にある。
  - F の `trg_no_agent_only_approval` は `BEFORE UPDATE OF status` のみ。`INSERT ... status='approved'` は通る。ただし approved の INSERT には approver が要る（CHECK）が、証拠の検査は無い（読解）。
  - A のトリガ `decision_immutable` も UPDATE のみが対象で、INSERT 時は何も縛らない。
- 解消とみなす条件:
  - 承認の主体を、DB の外の検証可能な事実に結びつける。例: Git の PR マージ者を `approved_by` の唯一の書込み経路にする、または承認用の別プロセスだけが書込み権限を持つ。
  - エージェントが `approved_by` を偽造した INSERT/UPDATE が拒否される実行ログを示す（INSERT 経路も含む）。

### E3. supersede トリガで「提案しただけ」の行が承認済みを失効させる（設計変更要 / A, C）
- 根拠:
  - A の `link_supersede` は `decision_link` に `supersedes` を挿入すると、`new.from_id` の status を見ずに旧判断を `superseded` に更新する。
  - 更新対象の `status` は `decision_immutable` の列リストに入っておらず、止まらない。
  - C の `edge_supersede` も、同一 scope であれば `src` の status を見ない。
  - つまり、`proposed` / `hypothesis` の行（エージェントが書ける）が `accepted` / `approved` の行を失効できる。
  - A は §4-5 で権限検査の欠如を認めているが、承認すら不要という点まで書いていない。
  - 失効すると `v_effective` / `v_active` から消え、注入されなくなる（無言の判断消失）。
- 解消とみなす条件:
  - supersede は新旧両方が承認済み（かつ権限条件を満たす）のときだけ有効にする。
  - 「proposed が accepted を supersede しようとして拒否される」テストの実行ログを示す。

### E4. 注入側が有効期限・失効・信頼度の検査を実装していない（設計変更要 / D, C）
- 根拠:
  - D.md §2.1 / §2.2 は「注入するのは approved かつ `valid_until` 未超過のみ」と書く。
  - ところが `d-test/inject_hook.py` の SQL は `status='approved'` と `tier` だけで、`valid_until` を見ない。
  - 同じフックは PreToolUse での `deny` / `ask` を実装していない。
  - tier0 は SessionStart と UserPromptSubmit を区別せず常に出す。
  - 同期的な矛盾解決（global と project の衝突）も未実装。C の `v_active` も両方返し、C は §2.7 で認めている。
  - タグの逆引きは部分文字列一致なので、例えば「ログ」が「ログイン」にも当たる。誤発火の評価が無い。
- 解消とみなす条件:
  - フックが期限切れ・superseded・scope 違いを除外する実行ログ（合成データ）。
  - 矛盾する2件を同時にヒットさせたときの出力。
  - 誤発火率の測定。

### E5. 効果の定量的根拠がゼロのまま、設計が確定的に書かれている（再調査要 / A, F, 指揮側）
- 根拠:
  - A は「ADR を足せば AI が従う」の一次定量根拠は見つからなかったと書く（A16 を不採用）。
  - 私の検索で、実務の定量報告を1件見つけた（Pallet "Memory-Bench"、ベンダー自己計測）。
    - 本番判断に由来する78タスクのうち、信頼できる正解のある44件で、7モデルの first-try 正解率が 22% から 62% に上がった。
    - 記憶には SOP、過去の実行、人間が AI の出力を直した事例を含む。
    - 1決定点のみ評価、サンプルが小さい、詳細な方法は別 brief にあり未確認。
    - URL: https://www.pallet.com/labs/memory-bench （取得日 2026-11-17）
  - これは根拠として弱い。だが「判断再現の効果は未確認」という A の記述より情報がある。
- 解消とみなす条件:
  - A、F が上記を含む既存の定量報告を一次情報で検討し、弱さを明記して台帳に載せる。
  - 自前の最小実験（合成データ・n を明記）で、注入あり/なしの差を1つ示す。実験は一致率の定義（F §2.1）に従う。

### E6. 評価（F）に人間ラベルの入手経路が無い（設計変更要 / F）
- 根拠:
  - F の手順は「判断記録を `decided_at` で分割し、テスト事例の正解は人間の選択」とする。しかし本リポジトリには実データを入れない規約がある。
  - 実データでの評価をどこで、誰が、どの権限で回すかが書かれていない。
  - 再テスト（天井）を取る手順も、取れない間の代替が「天井不明と明記」だけ。
  - F の §4 自身が「人間の判断が誤りの場合を測る手段が未設計」と認めている。
  - 合成データでの評価は、モデルの一般常識と「個人の判断」を区別できないため、`shuffled_memory` 腕の意味が薄まる。
- 解消とみなす条件:
  - 評価を「リポジトリの外のプライベート環境で、同じスクリプトを回す」設計にする（入出力契約、集計値だけ持ち帰る形式）。
  - 合成データで `shuffled_memory` が機能する最小例を示す（例: 合成の2人の判断者で、互いの記録をシャッフルすると一致率が落ちる）。
  - 閾値 0.8/0.5（A）、k、割合（F）を決める手順を、実データが無くても進められる形に直す。

### E7. 暗黙知・低確信時の動作が「止まらない」の中でどう実体化されるか未検証（再調査要 / A, F, D）
- 根拠:
  - A の動作表は2.3、F の動作表は2.2 に別々にあり、列挙値も条件も異なる（E1 と同根）。
  - どちらも実際のエージェント・ループで動かした証拠が無い。
  - 質問キューは C の `open_question`、F の `review_queue` に別々に存在し、誰がいつ読み、期限切れ時に誰が責任を持つかが担当間で未接続。
  - D の PreToolUse deny は人間を待たせない形（deny＋理由）を提案するが、Claude Code で発火させた確認が無い。
- 追加の事実（私が確認）:
  - 公式 hooks ページに `args`（exec 形）の記載があり、D の設定例の形式は妥当。ただし Windows では `command` が実行ファイルに解決される必要があり、`.cmd` / `.bat` は不可（D は `python` なので問題なし）。
  - 設定ファイル由来の hooks は subagent 内でも発火し、入力に `agent_id` / `agent_type` が入る。D §4-4 の未確認は解消できる。
  - 出典: https://code.claude.com/docs/en/hooks （取得日 2026-11-17、先頭10万字のみ確認）
- 解消とみなす条件:
  - 実際に Claude Code セッションで PreToolUse deny が発火し、作業が別タスクへ進む様子のログ（合成タスク）。
  - 質問キューの単一仕様（誰が書き、誰が読み、期限切れの扱い）。

### E8. B の抽出実験は「動作確認」であり、プロンプトインジェクション耐性も効果も示していない（再調査要 / B）
- 根拠:
  - n=3、1スレッド、正解は作成者が仕込んだもの、モデル1種（B 自身が認めている）。
  - 注入は明白な1種のみ。ガード文なしでも従ったか否かの差が出ておらず、ガード文の効果は不明。
  - 「保留」を決定として余分に抽出する誤りが 3/3 で再現し、プロンプトで直らなかった。この誤りへの対策が検出ルール以外に無い。
  - 決定者の帰属が実行間でぶれた（B は検出手段になりうると書くが未検証）。
- 解消とみなす条件:
  - 巧妙な注入（判断者の発言に見せかける、引用内に埋める、日本語）を含む複数スレッドで、人が付けた正解との適合率・再現率を出す（合成でよいが、件数と作り方を明記）。
  - 保留誤抽出を直す手段（二段目の分類、反例プロンプト等）を試した結果。

### E9. 優先規則・矛盾（上司と先輩）が「大域ランク」の前提で壊れる（設計変更要 / A, C, F）
- 根拠:
  - A の `v_precedence` は `confirmed > 権限ランク > 新しさ > 確信度` で並べるが、ランクは `role` 表の大域値。A 自身が「部署が違うと決まらない」と認めている。
  - C は scope 違いの supersede をやめた結果、global と project の判断が両方 `v_active` に出る。
  - F は「決まらなければ矛盾チケットを作り確信度を閾値未満に固定」と書くが、DDL に矛盾チケットの表が無い。
  - 3者の優先規則の順序も一致しない（A: 権限が新しさに優先。F: 権限、新しさ、具体性。A §2.5 は scope の狭さを3番目に置く）。
- 解消とみなす条件:
  - 1つの優先規則と、その DDL またはクエリ。
  - 合成シナリオ（上司 vs 先輩、global vs project、新旧）での実行結果。
  - 「決まらない場合」の動作（矛盾チケット表を含む）。

### E10. プライバシー・法務の一次確認が未了（再調査要 / F, B）
- 根拠:
  - 個人情報保護委員会の注意喚起は、F03 がページの存在のみ、F04 が報道要約のみ。別添 PDF は未読。B-10 の PDF も未読。
  - 2026年改正の内容は PwC の解説（二次）に依存し、F 自身が「未施行」「法務確認が必要」と書く。
  - Slack、Teams、GitHub の規約の AI 処理可否は「未確認」のまま。
  - 退職者・本人の撤回の扱い、従業員の同意は「同意ベースで設計する」と決めたが、同意が実際に取れない場合の設計が無い。
- 解消とみなす条件:
  - PPC の一次資料（PDF 本文）の該当箇所を引用して台帳に載せる。
  - 主要サービス2〜3社の規約の AI 処理条項の確認（一次、URL と取得日）。
  - 同意が取れないソースの扱い（取り込まない／匿名化のみ）を DDL の状態に反映する。

### E11. 暗黙知の引き出しが原典未確認の質問テンプレに依存（軽微 / B）
- 根拠:
  - Klein の CDM のプローブ原文は未取得で、質問文は B の設計（B が明記している）。
  - 回答者の事後合理化への対策は「質問は3問以内」のみ。
- 解消とみなす条件: CDM の原典または一次的なレビュー論文の取得。事後合理化を測る方法（回答と実際の行動の突き合わせ）を1つ書く。

### E12. 検索の日本語対応は小規模実測に留まる（軽微 / C, D）
- 根拠:
  - C と D の実測は合成の4〜6件。D の2万行は性能のみ。
  - 形態素解析（MeCab 等）・ICU は C が未調査と明記。
  - C の `evidence.excerpt` は本文を複製でき、「本文は複製しない」の方針と食い違う（機微情報の保管場所が増える）。
- 解消とみなす条件: 方針の整合、または抜粋の保管ルール（秘匿・保持期間）の明記。形態素解析は不要と判断した根拠となる測定。

### E13. 出典の確認度の偏り（軽微 / 指揮側, A, D, F）
- 根拠:
  - 台帳の多くが「abstract のみ」「検索結果要約のみ」「WebFetch の要約モデル経由」。
  - Mem0、Letta、Tyree&Akerman、F12〜F14 は実在確認のみ。
  - 本ラウンドの抜き取りでは、次の4件の題名・著者・日付・主張は台帳の記述と一致した。
    - arXiv 2608.17694（GADR、2026-08-18）
    - 2607.05029（FARMA/SENTINEL、2026-07-06、326件の良性トレースで誤検知0は著者自己申告）
    - 2604.03826（直近3〜5件が最良。ただし abstract だけで数値は未確認）
    - 2605.06527（STALE、55.2%）
  - 台帳 B-01 の「arXiv 2608.17694」と F10 の記載に不整合は無い。
- 解消とみなす条件: `99` に一次確認率（本文確認 / abstract のみ / 要約のみ）を載せる。主要な設計判断を支える出典は本文確認に上げる。

## 新規に見つけた手法・事例
`work` 内の記述に無かったもの。件数は「新規主要候補」のみ数える。

- 新規主要候補 1: 判断の書込み経路での「決定時点キャプチャ」（context graph / decision traces）
  - 内容: 決定が起きた時点（承認・例外・ポリシー版を含むイベント）をその場で記録し、後からの抽出に頼らない。
  - 根拠: Foundation Capital の論考に由来するとされ、GitLab 等が製品化しているとの記載を検索で確認。多くはブログ・ベンダー資料で、独立した評価は見つけていない。「標準的な定義が無い」「トレースは文書より匿名化が難しい」との指摘もある。
  - 例: https://about.gitlab.com/topics/context-graph/decision-events/ , https://arize.com/blog/how-context-graphs-turn-agent-traces-into-durable-business-assets.md
  - 設計への影響: B の抽出中心（後から読んで拾う）と別に、エージェント自身の判断と人間の承認を「その場で」記録する経路を第一級にする余地がある。A の `deviation_note` と B の「逸脱時の理由記録」は部分的に近いが、独立した経路として設計されていない。F の `agent_trace` は「自動昇格しない」と書くが、記録の価値の扱いは別。
  - 本文は未取得。採用の可否は担当が一次を確認して判断すること。
- 新規主要候補 2: Anthropic のクライアント側 memory tool（`memory_20250818`、`/memories` ディレクトリ、6コマンド）
  - 取得して確認: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool （2026-11-17）。保存先はアプリ側で実装、パス走査対策は実装者の責任、記憶の期限切れは実装者の責任と明記。
  - 設計への影響: API 経由のエージェント基盤では、MCP ではなくこの標準ツールが有力な「読み書き」の仕様になる。C が棄却した公式 memory MCP と同様に、`delete` / `str_replace` で記録を AI が書き換えられる。判断記録の保護（E2、E3）をハンドラ側で実装する要件が生じる。Claude Code 外での運用を想定するなら、C の MCP 設計と併記が必要。
- 参考（設計変更には至らない、担当の確認対象）:
  - Generative Agents（Park et al., arXiv 2304.03442）: relevance / recency / importance による検索と reflection。D の再順位付けの重み決めに関係。重みの数値は二次情報で食い違っており未確認。
  - A-MEM（arXiv 2502.12110、NeurIPS 2025 採択との記載）: Zettelkasten 型でメモが自己更新・リンクされる。不変性・承認の設計と逆方向で、採用しない根拠として記録する価値がある。
  - Memento（arXiv 2508.16153）: 成功・失敗の軌跡を case bank に保存して再利用。
  - 組織記憶（arXiv 2607.03228、2026-07-03、位置づけ論文）: 組織固有の手続き知識を共有・ガバナンス付きの参照層として持つ提案。C と F の設計の裏付けではなく、比較対象として扱う。
  - LongMemEval-V2（"experienced colleagues"）、ContextWeave（arXiv 2608.04830）、EvoMemBench（arXiv 2605.18421）: 評価ベンチマーク。F の評価設計の比較対象。本文は未取得（検索結果での存在のみ）。

## 試した検索クエリ一覧（E）
WebSearch:
1. context graph decision traces enterprise agents capture why decisions were made
2. Anthropic memory tool context management API memory directory agents 2026
3. A-MEM agentic memory Zettelkasten LLM agents arXiv
4. Generative Agents Park memory stream reflection importance recency relevance retrieval
5. LLM agent decision preference learning from past human decisions benchmark organizational memory 2026 arXiv

WebFetch:
- arXiv 2608.17694 / 2607.05029 / 2604.03826 / 2605.06527（台帳記述の抜き取り確認）
- https://www.pallet.com/labs/memory-bench
- arXiv 2607.03228
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
- https://code.claude.com/docs/en/hooks （`args`、subagent、`permissionDecision`。先頭10万字のみ。残り約19万字は未読）

読んだ実物: `A.md B.md C.md D.md F.md`、`notes/sources.md`、`docs/plan.md`、`work/ddl/c_schema.sql`、`work/ddl/c_ddl_run.log`、`d-test/run.log`、`d-test/inject_hook.py`。

## 「見つからなかった」ことの確認と、未実施の範囲
- 反証の試み（実施）:
  - 「判断記録で AI の判断再現率が上がる」ことを否定する／支持する一次の研究は、上の検索では見つからなかった。Pallet は支持する側の自己計測のみ。
  - 抜き取りで取れた4件は台帳の記述と一致。架空の論文名は見つからなかった。
- 反証の限界:
  - 検索は5本で、広くない。Slack / PR レビュー特化の決定抽出、LLM-as-judge の較正、プロンプトインジェクションの防御文献、Letta の sleep-time、Mem0 の本文、Graphiti の bi-temporal 項目名、日本語の ADR 運用事例は、私も取得していない（ラウンド2の候補）。
  - 本ラウンドで私が確認できなかった項目は、「無い」とは言えない。
- 実行検証の限界: 私はシェルを持たず DDL を再実行していない。E2、E3、E4 は読解による指摘。

## 飽和の判定材料
- 新規主要候補: 2件（決定時点キャプチャ、Anthropic memory tool）。どちらも設計を変えうるが、現時点では採用案ではない（本文・一次の確認が必要）。
- 前ラウンドとの比較: 第1ラウンドのため比較対象なし。
- 終了条件との照合（事実のみ）:
  - 「再調査要／設計変更要」の指摘は E1〜E10 に集中（E11〜E13 は軽微）。
  - 条件2の「直近2ラウンド連続で0件」は未達（今回2件）。
  - 条件3（具体性）: DDL の実行ログは A（本文内）、B、C、D、F（scratchpad の保存先のみ）に分散。A と F の SQL は `work/` に保存されていない（A は自己申告。F のファイルは scratchpad）。ファイルでの証拠として `work/ddl/` へ保存が要る。
  - 判定は指揮側と人間が行う。
