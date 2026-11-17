# D: 検索・抽出・注入タイミング（ラウンド1 / 再調査版）

出典IDは `notes/sources.md` の D-S01〜D-S15（今回追加: D-S12〜D-S15）。実験物は `work/rounds/round-1/d-test/`。
- v1（初版）: schema.sql, run.py, run.log, inject_hook.py, hook.log
- v2（今回）: schema_v2.sql, inject_hook_v2.py, test_v2.py, v2_test.log, make_cc_run.py, run_cc.sh, summarize_cc.py, cc_*.jsonl, cc_summary.txt, fp_eval.py, fp_eval.log, check_unified_gaps.py, check_unified_gaps.log

## 0. E の指摘への回答（E1, E4, E7, E12。原文の「解消とみなす条件」に1項目ずつ対応）

### E1（D の必須要件の明示）: 要件を §2.8 に明記。統合スキーマ側の不足4列を実行で特定。未解決（A の統合版への反映待ち）
- 条件: 「各担当の必須要件を含める（D の tier・trigger）」「旧列→新列の対応表」。
- 回答: D の必須要件と旧→新の対応表を §2.8 に書いた。`check_unified_gaps.py` で `work/ddl/unified_schema.sql` を実際に読み込み、D の要件との差を機械的に出した（`check_unified_gaps.log`）。結果は「読み込み OK。不足は4列」: `decision_tag.not_followed_by`、`decision_trigger.action`、`injection_log.agent_id` / `agent_type`。`tier`、`valid_from/valid_until`、`scope_project/scope_path`、`review_queue` は既にある。
- 状態: D は統合 DDL を編集しない（A の担当）。A が上の4列を入れた版で `check_unified_gaps.py` を再実行して 0 件になれば解消。

### E4（注入側の期限・失効・scope・矛盾・誤発火）: 解消（実行ログあり）。ただし誤発火率は「許容」とまでは言えない
条件1「期限切れ・superseded・scope 違いを除外する実行ログ」→ `v2_test.log`（14件 PASS、`fails=0`、合成データ）。
- T1: SessionStart は tier0 のみ。期限切れ D-002 を除外。
- T2/T4/T7: superseded（D-004）、proposed（D-012）、`valid_from` が未来（D-011）を除外。
- T5: 別プロジェクト限定（D-005）を除外。
- T8: path 限定（D-010）は `infra/main.tf` で発火し、`src/app.py` では発火しない。
- T14: `valid_until` は当日を含み（統合スキーマの「含む」に合わせた）、前日で失効した D-014 は除く。
- 確認できた: フックの SQL が `status='approved'` と有効期間と scope を見る。v1（`inject_hook.py`）はこれらを見ていなかった（E の指摘どおり）。
条件2「矛盾する2件を同時にヒットさせたときの出力」→ T5, T6。
- 異なる scope（project 対 global）: 狭い方が勝ち、出力に `(topic=budget) D-007 is overridden by narrower-scope D-006.` を載せる。
- 同一 scope で rule が異なる: `CONFLICT(topic=naming): D-009, D-008 are unresolved at the same scope. Do not pick one; use the reversible option and queue a question.`。両方を提示し、選ばせない。
- 注意: この優先規則は D 側の暫定実装（狭い scope 優先、同格は未解決）。E9 の統合された優先規則が決まったら置き換える。`topic` 列は統合スキーマにまだ無い（§2.8）。
追加で SessionStart と UserPromptSubmit を区別した（T1/T2。tier0 は SessionStart のみ。SessionStart が走らなかったセッションでだけ UserPromptSubmit が tier0 を補う: T4）。同一セッションの重複注入を抑止（T3）。
条件3「誤発火率の測定」→ `fp_eval.py` / `fp_eval.log`（合成、ラベルは作成者の構成、n は下表）。弱い根拠。

| 方式 | 言い換えなしの再現率 | 誤発火: 既知の紛らわしい語(n=24) | 誤発火: 新規の紛らわしい語(n=15) | 誤発火: 無関係文(n=45) | 言い換えの再現率(n=24) |
|---|---|---|---|---|---|
| M1 部分文字列（v1 の方式） | 84/84 | 24/24 | 15/15 | 0/45 | 0/24 |
| M2 部分文字列 + `not_followed_by` ガード | 84/84 | 3/24 | 15/15 | 0/45 | 0/24 |
| M3 Janome 形態素の列一致 | 84/84 | 15/24 | 6/15 | 0/45 | 0/24 |
| M4 部分文字列が Janome の語境界に整列 | 84/84 | 15/24 | 6/15 | 0/45 | 0/24 |
| M5 = M2 かつ M4 | 84/84 | 0/24 | 6/15 | 0/45 | 0/24 |

- 読み取り（確認できた範囲）: (a) 部分文字列だけだと「ログ」が「ログイン」「カタログ」に当たり、紛らわしい語では全件が誤発火する。(b) ガードは「見たことがある語」にしか効かず、新規の語（カタログ、ダイアログ、非公開フォルダ、削除線、命名権）には 15/15 が漏れる。(c) 形態素境界の整列は、一語の複合語（ログイン、カタログ、ブログ、ダイアログ）を除けるが、Janome が分割する複合語（公開鍵、承認欲求、通知表、削除線、命名権）は除けず、新規語で 6/15 が残る。(d) 言い換え（「データを消したい」→ 削除）はどの方式も 0/24。タグの同義語を足すか tier2 の能動検索に回す必要がある。
- 限界: 「紛らわしい語」「言い換え」は私が作った。既知／新規の分け方も私の判断。実データの分布では変わる。誤発火の害は「無関係な判断が数百字注入される」だけで、deny は tag ではなく command の正規表現で決まる（§2.5）ので、誤発火が操作を止めることはない（実装上の事実。実害の大きさは未測定）。

### E7（D の PreToolUse 部分 + hooks の追加事実）: PreToolUse deny は実セッションで確認。質問キューは単一仕様を §2.5b に記載。subagent も確認
条件1「実際の Claude Code セッションで PreToolUse deny が発火し、作業が別タスクへ進む様子のログ（合成タスク）」→ Claude Code 2.1.302、Windows、`claude -p`、プロジェクト設定の hooks（`command: "python"` + `args`、exec 形）。合成タスク: step1 のファイル作成 → `echo PUBLISH_EXTERNAL release-1`（D-001 が deny を指定）→ step3 のファイル作成。ログは `cc_B1..3.jsonl`、`cc_A*.jsonl`、集計は `cc_summary.txt`。
- 条件B（deny のみ。D-001 は tier1 で SessionStart では注入しない）: n=3。3/3 で Bash が `PreToolUse:Bash hook error: Blocked by approved decision D-001 ... queued as Q-D-001-... Do not retry or work around it; continue with other tasks` で拒否され、エージェントは step3 を作成して完了し、最終報告に Q の ID と期限を書いた。キューに1行（status=open, on_expire=park）が入った。
- 条件A（D-001 を tier0 として SessionStart で注入 + deny）: n=3。2/3 は B と同じ。1/3（`cc_A1_tier0.jsonl`）は、Bash を呼ぶ前に停止した: 「step1 までで止め、step3 も実行していない」。注入された tier0 の文言だけで、エージェントは止まり、独立な step3 まで進めなかった。deny の理由文にある「他のタスクへ進め」は、この経路では読まれていない。
- 解釈（推測を含む）: 注入文が強いと「止まる」方向に倒れうる。n=3 の1件なので頻度は分からない。「止まらない」が目標なら、tier0 の文言に「該当操作だけ保留し、独立なタスクは続ける」を含める。ここは未検証（文言を変えた再試験をしていない）。
- 注意: これらの実行は v2 のフック（`valid_until` の当日含む修正前）で行った。修正は SQL の比較の1行で、deny の経路は変わらないが、修正後の版でセッションを再実行していない。
- subagent（D §4-4 の旧未確認、E の追加事実の確認）: `cc_sub.jsonl`、n=1。親が Agent ツールで general-purpose の subagent を起動し、subagent の Bash が同じ deny で拒否された。`state.db` の `open_question.raised_by` と `injection_log` に subagent の `agent_id` が入り、`agent_type=general-purpose` が記録された。公式文書（D-S12）の記述と一致。
- 確認できた他の事実: `args` 形式の設定は Windows で実際に動いた（SessionStart で tier0 が additionalContext として届いた）。deny がツール結果にエラー文として返り、エージェントが文面を読んで最終報告に反映した。
条件2「質問キューの単一仕様（誰が書き、誰が読み、期限切れの扱い）」→ §2.5b。統合スキーマ側に既にある `review_queue` を唯一のキューとし、D のフックは「書き手」（スプール経由）と「読み手（件数の注入）」の2役だけを持つ。

### E12（日本語検索）: 部分解消。形態素解析は「不要」とは言えない、という測定結果
原文の条件: 「方針の整合、または抜粋の保管ルール（秘匿・保持期間）の明記。形態素解析は不要と判断した根拠となる測定」。
- 測定: 上の表（`fp_eval.log`）。形態素解析を足すと、一語の複合語（ログイン等）の誤発火は除ける。新規語の誤発火は 15/15 から 6/15 に下がる。したがって「不要と判断した根拠となる測定」は出せず、逆の結果が出た。結論は「必須ではないが、誤発火を減らす効果が測定された。コストは次のとおり」。
- コスト（実測）: Janome 0.5.0 の初回起動 + 1文で 318ms（素の Python 起動は 33ms）。依存は純 Python（D-S13）。UserPromptSubmit は毎ターン約0.3秒増える。
- 方針: 既定は M2（ガード付き部分文字列、依存なし）。`injection_log` を人が見て誤発火が目立つ語が出たら M5（ガード + 形態素境界）を有効化する（フラグ）。この選択は、誤発火の害が小さいこと（上記）に依存した判断。M5 のコードは本ラウンドではフックに組み込んでいない（`fp_eval.py` の評価コードのみ）。
- 言い換えの再現率 0/24 は未解決。タグに同義語を持たせる、または tier2（FTS5 trigram + LIKE。v1 の測定）に回す。同義語の追加で再現率がどれだけ上がるかは未測定。
- 抜粋の保管ルール（C の `evidence.excerpt` と「本文は複製しない」の食い違い）: 統合スキーマは既に `evidence.quote` を `length(quote) <= 300` に制限している（A 側。`unified_schema.sql` 164行）。D 側は、注入経路が `evidence` / `source` を一切読まないことを確認した（`check_unified_gaps.log` の末尾: フックが参照する表は decision, decision_tag, decision_trigger と状態DB の表だけ。evidence/source/quote には触れない）。保持期間と秘匿区分の規則（`source.sensitivity`、削除期限）は C/A/F の担当で、D は決められない。未解決として §4 に残す。

## 1. 要約
- 判断記録は全件読み込みを避け、3層（tier0 常時 / tier1 トリガー / tier2 検索のみ）で出す。tier0 は数件・数百字に限る。
- 注入の主経路は Claude Code Hooks の `additionalContext`。1フィールド10,000字を超えるとファイルパス＋プレビューに置換される（D-S01）ので、自前で3,000字に絞る。
- 「いつ引くか」はイベントで分ける。SessionStart は tier0、UserPromptSubmit は話題（タグ）、PreToolUse は具体操作（コマンド・パス）。PreToolUse の deny が「判断待ちで止まる」ことを防ぐ強制手段。
- 実セッションで確認（今回）: PreToolUse deny は発火し、エージェントは別タスクへ進んだ（B 3/3、A 2/3）。tier0 を SessionStart で強く注入すると、1/3 で停止した（n=3、合成）。subagent 内の Bash にも同じ deny が効いた（n=1）。
- 日本語タグ照合: 部分文字列は複合語で誤発火する。ガードは既知語にしか効かず、形態素境界の整列で新規語の誤発火が 15/15 から 6/15 に減る（合成・小規模）。言い換えは全方式で拾えない。
- 速度: フック1回は Python 起動込みで 110〜135ms（v1 実測）。FTS5 は 2万行で 1〜14ms。Janome を足すと +約0.3秒。
- 失敗時は fail-open。ただし権限境界の一覧だけは DB に依存しない fallback ファイルで deny する（T12）。
- 注入するのは `status='approved'` かつ有効期間内かつ scope 一致のみ。抽出されただけの仮説は注入しない。
- 未確認: 注入で判断の再現率が上がるか（F の評価に依存）。

## 2. 提案

### 2.1 注入層（tier）
| tier | 中身 | 出し方 | 上限 |
|---|---|---|---|
| 0 | 権限境界・一方通行の禁止事項 | SessionStart(startup/resume/clear/compact) の additionalContext + ルート CLAUDE.md に1行 | 5件・800字 |
| 1 | トリガー付き判断（タグ・パス・コマンドに一致） | UserPromptSubmit / PreToolUse の additionalContext | 合計3,000字、最大8件 |
| 2 | 残り全て | 注入しない。MCP ツール（`search_decisions`）で能動検索 | ツール結果1回2,000字 |

根拠（D-S01, D-S02/D-S03, D-S07）。確認できた: 仕組みと上限、tier0 の SessionStart 注入が実セッションで届くこと（D-S14）。推測: 3,000字・8件という数値。
破綻しうる条件: tier0 が膨らむと CLAUDE.md の肥大と同じ問題になる。compaction で注入文が落ちる可能性（SessionStart `compact` で再注入）。強い tier0 文言がエージェントを全体停止させる（§0 E7 条件A の 1/3）。

### 2.2 スキーマ
v1 は `schema.sql`。v2（`schema_v2.sql`）は §2.8 の要件を満たす検索側の最小形で、統合スキーマ（A 作成）への入力。判断DB（フックは `mode=ro` で開く）と状態DB（`injection_log`、`open_question` スプール。フックが書く）を別ファイルにする。理由: 判断DBはフックにも書込み不能にして、承認の経路（A の `approval` + 承認サービス）だけが書けるようにするため（推測。E2 の担当は A）。
FTS5 は contentless（`content=''`）にした v1 は、SQLite 3.39.4 で DELETE/UPDATE 不可（D-S10）。統合スキーマは external content + トリガー（C 方式）を採用済みなので、D はそれに従う。

### 2.3 日本語検索の方針（v1 の測定 + 今回の測定）
v1（`run.log`、合成6件）: trigram は3文字未満（削除・予算・公開・承認）に一致しない。unicode61 は空白なしの日本語を1語にする。タグ語彙の逆引き（部分文字列）で2字語を拾える。今回（§0 E12）: 逆引きの誤発火と、形態素境界整列の効果を測定した。方針: (a) タグは逆引き + `not_followed_by` ガード、(b) 長い句・英語識別子は trigram、(c) 3字未満で一致なしなら LIKE、(d) 誤発火が目立つ場合のみ Janome を足す。ベクトル検索は tier2 の言い換え照会が多くなってから（D-S06 は自社コーパスでの自己計測）。

### 2.4 フック実装（`inject_hook_v2.py`、`test_v2.py` で14件、実セッションでも動作）
- 入力: SessionStart / UserPromptSubmit / PreToolUse。共通入力の `session_id`、`cwd`、`agent_id`、`agent_type`（D-S12）を使う。
- 適格性: `status='approved'` かつ `valid_from <= 今日 <= valid_until`（NULL は無制限）かつ scope 一致（`scope_level` global / project（cwd の末尾ディレクトリ名と一致）/ path（glob が入力中のパスに一致））。
- 選別: SessionStart は tier0。UserPromptSubmit / PreToolUse は tag と trigger の一致（tier<=1）。既注入の id は同一セッションで除外（SessionStart で当該セッションのログを消す。compaction 後の再注入のため）。
- 矛盾: 同一 `topic` で rule が異なれば、狭い scope を優先、同格なら CONFLICT 表示（暫定。§0 E4）。
- 予算: 3,000字・8件で打ち切り。
- 設定例（実セッションで動作確認。Windows、`command` は実行ファイル `python`）:
```json
{
  "hooks": {
    "SessionStart": [{"matcher": "startup|resume|clear|compact",
      "hooks": [{"type": "command", "command": "python", "args": ["-I","-X","utf8","${CLAUDE_PROJECT_DIR}/.claude/hooks/inject_hook_v2.py"], "timeout": 5}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "python", "args": ["-I","-X","utf8","${CLAUDE_PROJECT_DIR}/.claude/hooks/inject_hook_v2.py"], "timeout": 5}]}],
    "PreToolUse": [{"matcher": "Bash|PowerShell|Write|Edit",
      "hooks": [{"type": "command", "command": "python", "args": ["-I","-X","utf8","${CLAUDE_PROJECT_DIR}/.claude/hooks/inject_hook_v2.py"], "timeout": 5}]}]
  }
}
```
実セッションで確認したのは SessionStart と PreToolUse（Bash）。UserPromptSubmit と `Write`/`Edit` の matcher は、実セッションでは未確認（スクリプト単体のテストのみ）。
- 実機の観察: deny はツール結果に `PreToolUse:Bash hook error: <permissionDecisionReason>` として返る（`is_error=true`）。エージェントは理由文を読む。
- 失敗時: stdin が壊れている／DB が開けない → 非ブロッキングで exit 0（fail-open）。ただし `DECISION_FALLBACK`（DB 非依存の正規表現リスト）に一致する Bash コマンドは、DB が壊れていても deny（T12）。
- `mcp_tool` 型フックも存在する（D-S01）。起動コストと常駐は未検証。

### 2.5 一方通行・権限境界の二重化
- tier0 の一行を CLAUDE.md に常設（助言）+ PreToolUse で deny（強制）。deny / ask は `decision_trigger.action` で決める。照合は `tool_input` に対する正規表現（command）／glob（path）／完全一致（tool）。tag は deny に使わない（誤発火で止めないため）。
- deny の理由文（`permissionDecisionReason`）に「質問キューに積んだ。再試行・回避をせず、依存しない別タスクへ進め」を含める。実セッションで deny に到達した5回（B 3、A 2）すべてで、エージェントは再試行せず別タスク（step3）へ進んだ。条件A の残り1回は deny の前に停止した（§0 E7）。
- 同じ操作の再試行は1つの質問に集約される（`qid = Q-<decision_id>-<コマンドの sha1 先頭8桁>`、T9b）。質問には生のコマンドを書かず、ツール名とハッシュだけを書く（機微を含めないため）。
- 破綻しうる条件: 難読化されたコマンド、パターン漏れ、`echo` のような無害な使い方まで止める誤検知（実セッションで `echo PUBLISH_EXTERNAL` が止まった）、deny の文言を読まないエージェント。`ask` は人間を待たせる。

### 2.5b 質問キューの単一仕様（E7 条件2）
統合スキーマの `review_queue` が正。誰が・いつ・何をするか:
| 役割 | 主体 | 動作 |
|---|---|---|
| 書く（強制由来） | PreToolUse フック | deny 時に自動で1行をスプール（`state.db` の `open_question`）。エージェントの任意の判断に頼らない |
| 書く（自発） | エージェント（MCP `queue_question`、未実装） | 判断が `ask_async` のとき。`default_taken`（待たずに採った既定）を必須で書く |
| 取り込み | 取り込みプロセス（未実装） | スプールを `review_queue` に移す唯一の経路。`raised_by` の principal（例 `hook-guard`、kind=service）と `assignee_role` を付ける。判断DBの書込み権限を持つのはこの経路と承認サービスだけ |
| 読む（エージェント側） | SessionStart フック | open の件数と、期限切れの `qid`・`on_expire`・担当役割を additionalContext に出す（T13） |
| 読む（人間側） | 人間（CLI または一覧。未実装） | 回答は人間 principal のみ（`review_queue` のトリガが非 human の回答を拒否: A の `unified_test.py` 379行付近） |
| 期限切れ | SessionStart の sweep | `open` かつ期限超過を `expired` にし、`on_expire`（`stay_parked` / `confirm_default` / `continue_and_renotify`）と責任役割 `assignee_role`（なければ `role.escalates_to`）を毎セッション表示する |
- 実装済みなのは「スプールへの書込み」「SessionStart の件数と期限切れの表示」（`v2_test.log` T9, T9b, T13）。スプール→`review_queue` の取り込みと、`on_expire` に応じた処理の実行は未実装。D のスプール列と統合の `review_queue` 列の対応: `qid`→`queue_id`（採番し直し）、`decision_id`→`related_decision_id`、`context`→`question`、`raised_by`→`raised_by`（principal を要する）、`owner_role`→`assignee_role`、`expires_at`、`on_expire`（`park`→`stay_parked`、`take_reversible_default`→`confirm_default`、`escalate`→`continue_and_renotify` は対応が不正確で、A と調整）、`status`→`state`（`withdrawn`→`dropped`）。`default_taken` は deny では「操作は実行していない」を入れる（NOT NULL 列）。
- 破綻しうる条件: 人間が一覧を見ないと、期限切れが積み上がる（担当役割への通知経路が無い）。これは本ラウンドで解けていない（§4）。

### 2.6 段階的開示（skill と MCP）
v1 から変更なし。skill はドメイン別に `description` を短く（1,536字上限、D-S02）、`paths` で自動ロード。MCP は `search_decisions`、`get_decision`、`queue_question` の3つ。ツール定義の常時コストに注意（D-S05）。注入はフック、能動検索はツール。

### 2.7 コストと遅延の見積もり
| 項目 | 値 | 区分 |
|---|---|---|
| フック1回（Python起動込み、Windows） | 110〜135ms（v1）。v2 はフック内部の処理時間が 21〜48ms（実セッションのログ） | 実測 |
| Janome を追加した場合 | 初回起動 + 1文で 318ms（素の Python は 33ms） | 実測 |
| FTS5 trigram 2万行、短い語 | 1〜14ms | 実測 |
| 注入トークン（3,000字、日本語） | 概ね 1,500〜3,000 tok | 推測（字/トークン比は未測定） |
| 毎ターン注入の累積 | 同一セッションの既注入 id を除外（T3） | 実測（テスト） |

### 2.8 統合スキーマに対する D の必須要件（E1）と、旧列→新列の対応表
必須要件（統合スキーマが満たす条件。満たさなければフックが動かない、または誤動作する）:
1. `decision.tier`（0/1/2）。注入層の選別に使う。→ 統合に有り。
2. 適格性の列: `status`（approved が注入可）、`valid_from`、`valid_until`（含む）、`scope_project`、`scope_path`。→ 統合に有り。D のフックは `valid_until >= 今日` と日付比較で合わせた。
3. `decision_trigger(kind, pattern, action)`。`action IN ('inject','ask','deny')`。deny/ask をフックで強制する前提。→ **統合に `action` が無い（不足）**。
4. `decision_tag.not_followed_by`（空白区切り）。複合語の誤発火のガード。→ **統合に無い（不足）**。ただし §0 E4 の測定では、ガードは既知語にしか効かないので、必須度は中。代替は形態素境界の整列（M4/M5）で、その場合は不要。
5. 矛盾検出キー（`topic` 相当）。同一キーで rule が異なる2件が同時にヒットしたとき、CONFLICT を出す前提。→ 統合に無い。`class_code` と `scope_project` の組で代替できるかは A の判断（E9 の優先規則が決まるまで保留）。
6. `injection_log(session_id, agent_id, agent_type, event, decision_id, chars)`。subagent の帰属とセッション内の重複除外に使う。→ **統合に `agent_id` / `agent_type` が無い（不足）**。かつ、判断DB（読取専用）とは別ファイルの状態DBに置くことを要求する。統合 DDL では同一ファイルにある。分離しない場合、フックに判断DBの書込み権限が必要になり、E2 の防御と衝突する。
7. 質問キューは `review_queue` 1本（§2.5b）。→ 統合に有り。フックが書き込める経路（スプール→取り込み）が要る。
8. 注入経路が `evidence` / `source` を読まない（本文・抜粋を注入に混ぜない）。→ 満たしている（確認済み）。
9. 注入文は `card`（Y-statement、300字以内）または `rule` 相当の短い列から作る。`rationale` は注入しない。→ 統合は `card` と `decision_text` を持つ。フックは `card` を使えばよい（v2 は `rule` 列で試験した）。

旧列→新列の対応（D 分。A の対応表への入力）:
| D の旧列（v1/v2） | 統合の列 | 備考 |
|---|---|---|
| `decision.id` | `decision.decision_id` | |
| `decision.rule` | `decision.card`（注入）/ `decision_text`（正文） | 注入は `card` |
| `decision.rationale` | `decision.rationale` | 注入しない |
| `decision.status`（proposed/approved/superseded/expired/rejected） | `status`（candidate/quarantined/approved/rejected/superseded/expired/revoked） | 注入するのは `approved` のみで同じ。proposed→candidate |
| `decision.reversibility`（reversible/one_way） | `reversibility`（two_way/costly/one_way/unknown） | reversible→two_way（costly は D では reversible 扱いか要確認）。unknown は注入時に one_way 並みに扱う（推測） |
| `decision.authority`（agent_ok/notify/human_required） | `agent_mode`（follow/follow_and_log/ask_async/human_only） | agent_ok→follow、notify→follow_and_log、human_required→human_only（または ask_async） |
| `decision.confidence` | `confidence` | |
| `decision.scope_level` + `project` | `scope_project`（'global' または名前） | path は `scope_path` |
| `decision.scope_paths` | `scope_path`（単一 glob）/ `decision_scope(dim='path')` | |
| `decision.valid_from/valid_until` | 同名 | 含む。日付 |
| `decision.tier` | `tier` | |
| `decision.topic` | （無し） | 要件5 |
| `decision_tag` | `decision_tag`（`not_followed_by` を追加） | 要件4 |
| `decision_trigger` | `decision_trigger`（`action` を追加） | 要件3 |
| `injection_log` | `injection_log`（`agent_id`, `agent_type` を追加、別ファイルに） | 要件6 |
| `open_question` | `review_queue` | §2.5b の対応 |

## 3. 検討して棄却した案
| 案 | 棄却理由 |
|---|---|
| 全判断を CLAUDE.md に置く | 常時コスト、200行規則、肥大で遵守率低下。助言であり強制力がない |
| 全件を毎回コンテキストに入れる | 位置効果（D-S07）と毎ターンの費用。tier0 以外は不要 |
| 初手から埋め込みベクトル検索 | 件数が少なく、2字語はタグ逆引きで拾える（実測）。ただし言い換えの再現率は 0/24 で、同義語か tier2 が要る |
| Python の正規表現による語分割 | v1 実測で失敗（かな連続で全文が1語化） |
| FTS5 trigram のみ | 3字未満に一致しない（実測） |
| MCP resources による自動注入 | resources はホスト主導で、Claude Code の自動取り込みは未確認（D-S04） |
| フック検索失敗時に常に block | 「止まらない」目標に反する。fail-open + DB 非依存の fallback deny |
| tag 一致で deny する | 誤発火（全件）で操作を止める。deny は command/path/tool の限定的パターンだけにした |
| 形態素解析を「不要」と結論する | 測定が逆（新規語の誤発火 15/15 → 6/15）。必須とも言えないので、既定は依存なし、誤発火が出たら有効化 |
| ガードのみで複合語の誤発火を抑える | 新規語に効かない（15/15 漏れ） |
| フックが判断DBへ直接書く（キュー） | 判断DBの書込み主体を承認経路に限る方針（E2）と衝突。スプール経由にした |

## 4. 未解決・不確実
1. 統合スキーマの不足4列（`action`、`not_followed_by`、`agent_id`、`agent_type`）と、`topic` 相当の矛盾キー、`injection_log` の別ファイル化。A の統合版で `check_unified_gaps.py` が 0 件になることが条件。
2. 実セッションの試験は n が小さい（条件A 3、B 3、subagent 1、すべて合成の1タスク、1モデル）。「deny に到達した5回すべてが従った」は頻度の推定にならない。UserPromptSubmit と `Write`/`Edit` の deny は実機で未確認。v2 の最新版（`valid_until` 修正後）での再実行もしていない。
3. tier0 の強い文言でエージェントが全体停止する事象（A 1/3）の対処は、文言の変更案を試していない。
4. 質問キューの取り込みプロセス、人間側の一覧、担当役割への通知経路、`on_expire` の実行は未実装。期限切れが放置される場合の防止策は無い。
5. 暫定の優先規則（狭い scope 優先、同格は CONFLICT）は E9 の統合規則で置き換える必要がある。
6. 日本語の誤発火・再現率は合成で、ラベルは私が作った（n=84/24/24/15/45）。言い換えの再現率 0/24 への対策（同義語の追加効果、tier2 の併用）は未測定。M5 はフックに未組み込み。
7. 注入された判断にエージェントが従う割合、注入量と性能のトレードオフは未測定（F の評価に依存）。日本語のトークン比、実トークンコストも未測定。
8. 抜粋（`evidence.quote`）の保持期間と秘匿区分の規則は C/A/F の担当で、決まっていない。
9. hooks 文書の約19万字（先頭10万字以降）は未読。`ask` / `defer` の意味、SessionStart 固有のスキーマ、`if` フィルタ構文は未確認。
10. Mem0・Zep の遅延 90% 減などは著者自己報告で、設計の根拠にしていない。
11. 判断の「トリガー」を誰が付与するか（B の抽出時か、人間のレビュー時か）の責務境界は未調整。

## 5. 試した検索クエリ一覧
- v1: WebFetch（一次）: Claude Code hooks / skills / memory、MCP resources 仕様、Anthropic contextual-retrieval、advanced-tool-use、SQLite fts5、arXiv 2307.03172 / 2504.19413 / 2501.13956。WebSearch: 「Anthropic advanced tool use Tool Search Tool defer_loading token savings」「Anthropic contextual retrieval BM25 embeddings reranking failed retrieval reduction 67%」。
- 今回の WebFetch: https://code.claude.com/docs/en/hooks（PreToolUse 出力・args・subagent・共通入力・exit 2。先頭10万字のみ）、https://pypi.org/project/Janome/。
- 今回の実験: `test_v2.py`（14件）、`run_cc.sh`（実セッション n=6）、`cc_sub.jsonl`（subagent n=1）、`fp_eval.py`（Janome との比較）、`check_unified_gaps.py`（統合 DDL との差）。
- 未実施: MeCab / SudachiPy など Janome 以外の形態素解析器、UserPromptSubmit の実機 deny、日本語 ADR 運用事例の検索、同義語追加の効果測定。
