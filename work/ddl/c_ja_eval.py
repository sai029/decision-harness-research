"""担当C: 日本語検索の小規模実測 (E12) とタグ逆引きの誤発火測定 (E4)。合成データのみ。
使い方: python -I c_ja_eval.py <janome を入れた site ディレクトリ>
注意: 文書・クエリ・正解は私が手で作った合成物。語彙の重なりも私が設計したため、数値は「方式の差の例示」であり実運用の精度ではない。
"""
import sys, re, sqlite3, os, tempfile, time
sys.stdout.reconfigure(encoding='utf-8')
sys.path.insert(0, sys.argv[1])
from janome.tokenizer import Tokenizer
TK = Tokenizer()

TOPICS = {
 'api-delete': ['外部公開APIの削除は人間の承認が必要', '公開APIを削除する前に、利用者へ30日前に告知する', 'APIの廃止と削除は四半期ごとにまとめて実施する'],
 'log': ['本番のログレベルは INFO にする', 'ログは90日で削除する', 'エラーログには個人情報を出力しない'],
 'login': ['ログイン失敗が5回続いたらアカウントをロックする', 'ログイン画面にはパスワード表示ボタンを付けない', 'ログインセッションは12時間で切れるようにする'],
 'db': ['データベースは PostgreSQL を使う', 'DBのバックアップは毎日深夜に取る', 'マイグレーションは必ずロールバック手順を添える'],
 'review': ['プルリクエストは2名のレビューが必要', 'レビュー依頼は24時間以内に返信する', '軽微な修正は1名のレビューで承認してよい'],
 'deploy': ['本番デプロイは平日の昼に行う', '金曜の夕方以降はデプロイしない', 'デプロイ前に必ずステージングで確認する'],
 'admin': ['管理画面は社内ネットワークからのみ接続できる', '管理者権限は申請制にする', '管理者のパスワードは90日ごとに変更する'],
 'notify': ['障害通知は Slack の専用チャンネルに送る', 'メール通知は夜間は送らない', '通知の文面は日本語で書く'],
 'test': ['新機能には単体テストを必ず付ける', 'テストが失敗した状態でマージしない', 'テストデータに実在の個人情報を使わない'],
 'deps': ['ライブラリの更新は月1回まとめて行う', '新しい依存を追加する時はライセンスを確認する', '脆弱性の報告があったライブラリは即時更新する'],
 'cost': ['クラウドの月額費用が予算の80%を超えたら通知する', '未使用のリソースは月末に削除する', '高額な構成を選ぶ時は理由を記録する'],
 'docs': ['設計判断はADRとして残す', 'READMEには起動手順を書く', '仕様変更時はドキュメントも同じPRで更新する'],
}
# (クエリ, 正解トピック, 種別)  種別: infl=活用・語形違い, short=2文字語, confuse=部分文字列の罠, syn=言い換え(語彙が重ならない)
QUERIES = [
 ('APIを削除したい', 'api-delete', 'short'), ('公開エンドポイントを消す時の手順', 'api-delete', 'syn'),
 ('ログの保存期間', 'log', 'confuse'), ('ログを出力する時の注意', 'log', 'confuse'),
 ('ログインできない時の対応', 'login', 'infl'), ('ログインの有効期限', 'login', 'infl'),
 ('DBを選ぶ', 'db', 'short'), ('バックアップの頻度', 'db', 'infl'),
 ('レビューは何人必要か', 'review', 'short'), ('レビューの返信期限', 'review', 'short'),
 ('デプロイしてよい曜日', 'deploy', 'infl'), ('デプロイ前の確認', 'deploy', 'infl'),
 ('管理者を追加する', 'admin', 'confuse'), ('管理画面へのアクセス', 'admin', 'confuse'),
 ('障害を通知する先', 'notify', 'infl'), ('夜間に通知してよいか', 'notify', 'infl'),
 ('テストを書く基準', 'test', 'short'), ('テストが落ちたらどうするか', 'test', 'syn'),
 ('ライブラリを更新する頻度', 'deps', 'infl'), ('ライセンスの確認', 'deps', 'infl'),
 ('費用が増えた時', 'cost', 'syn'), ('未使用リソースを削除する', 'cost', 'short'),
 ('設計の理由を残す', 'docs', 'infl'), ('ドキュメントの更新タイミング', 'docs', 'infl'),
]
DOCS = []  # (id, topic, text)
for t, xs in TOPICS.items():
    for x in xs:
        DOCS.append((len(DOCS) + 1, t, x))
REL = {t: {d[0] for d in DOCS if d[1] == t} for t in TOPICS}

RUN = re.compile(r'[一-鿿]+|[ァ-ヿー]+|[A-Za-z0-9]+')  # 漢字・カタカナ・英数の連続。ひらがな(助詞)は捨てる
STOP = {'する', 'ある', 'いる', 'なる', 'できる', 'れる', 'られる'}


def jtokens(text):
    out = []
    for t in TK.tokenize(text):
        p = t.part_of_speech.split(',')
        if p[0] in ('名詞', '動詞', '形容詞') and p[1] not in ('非自立', '代名詞', '数') and t.base_form not in STOP:
            out.append(t.base_form if t.base_form != '*' else t.surface)
    return out


def mk():
    db = sqlite3.connect(':memory:')
    db.execute('CREATE TABLE doc(id INTEGER PRIMARY KEY, topic TEXT, text TEXT, jtok TEXT)')
    for i, t, x in DOCS:
        db.execute('INSERT INTO doc VALUES (?,?,?,?)', (i, t, x, ' '.join(jtokens(x))))
    db.execute("CREATE VIRTUAL TABLE f_tri USING fts5(text, content='doc', content_rowid='id', tokenize='trigram')")
    db.execute("CREATE VIRTUAL TABLE f_u61 USING fts5(text, content='doc', content_rowid='id', tokenize='unicode61')")
    db.execute("CREATE VIRTUAL TABLE f_jan USING fts5(jtok, content='doc', content_rowid='id', tokenize='unicode61')")
    db.execute("INSERT INTO f_tri(rowid,text) SELECT id,text FROM doc")
    db.execute("INSERT INTO f_u61(rowid,text) SELECT id,text FROM doc")
    db.execute("INSERT INTO f_jan(rowid,jtok) SELECT id,jtok FROM doc")
    return db


def q_tri(db, q, k=5):
    runs = RUN.findall(q)
    long_ = [r for r in runs if len(r) >= 3]
    short = [r for r in runs if len(r) < 3]
    ids = []
    if long_:
        m = ' OR '.join('"%s"' % r for r in long_)
        ids += [r[0] for r in db.execute('SELECT rowid FROM f_tri WHERE f_tri MATCH ? ORDER BY bm25(f_tri)', (m,))]
    for s in short:  # 2文字以下は LIKE へフォールバック (trigram は引けない)
        ids += [r[0] for r in db.execute('SELECT id FROM doc WHERE text LIKE ?', ('%' + s + '%',)) if r[0] not in ids]
    return list(dict.fromkeys(ids))[:k]


def q_u61(db, q, k=5):
    runs = RUN.findall(q)
    if not runs: return []
    m = ' OR '.join('"%s"' % r for r in runs)
    return [r[0] for r in db.execute('SELECT rowid FROM f_u61 WHERE f_u61 MATCH ? ORDER BY bm25(f_u61) LIMIT ?', (m, k))]


def q_jan(db, q, k=5):
    toks = jtokens(q)
    if not toks: return []
    m = ' OR '.join('"%s"' % t for t in toks)
    return [r[0] for r in db.execute('SELECT rowid FROM f_jan WHERE f_jan MATCH ? ORDER BY bm25(f_jan) LIMIT ?', (m, k))]


def evaluate(db):
    methods = {'trigram+LIKE': q_tri, 'unicode61': q_u61, 'janome+unicode61': q_jan}
    kinds = sorted({k for _, _, k in QUERIES})
    print('== 検索実測 (合成: 文書%d件 / クエリ%d件 / top5) ==' % (len(DOCS), len(QUERIES)))
    for name, fn in methods.items():
        rec, prec, per = [], [], {}
        for q, t, kind in QUERIES:
            got = fn(db, q); rel = REL[t]
            hit = [g for g in got if g in rel]
            r = len(hit) / min(5, len(rel)); p = (len(hit) / len(got)) if got else 0.0
            rec.append(r); prec.append(p); per.setdefault(kind, []).append((r, p))
        print(f'{name:18s} recall@5={sum(rec)/len(rec):.2f}  precision@5={sum(prec)/len(prec):.2f}  ' +
              '  '.join(f'{k}:R{sum(x[0] for x in v)/len(v):.2f}/P{sum(x[1] for x in v)/len(v):.2f}(n={len(v)})' for k, v in sorted(per.items())))
    print('-- クエリ別の取りこぼし/誤ヒット (trigram+LIKE と janome の差分のみ) --')
    for q, t, kind in QUERIES:
        a, b = q_tri(db, q), q_jan(db, q)
        if set(a) != set(b):
            fa = [i for i in a if i not in REL[t]]; fb = [i for i in b if i not in REL[t]]
            print(f'  [{kind}] {q}: tri={a} 誤={fa} / janome={b} 誤={fb} / 正解={sorted(REL[t])}')


# ---- タグ逆引き (E4 誤発火) ----
VOCAB = ['ログ', 'ログイン', '削除', '管理', '管理者', 'デプロイ', 'テスト', '通知', 'DB', 'レビュー', '依存', '費用']
# (プロンプト, 正しく発火すべきタグ集合)
PROMPTS = [
 ('ログインでエラーが出る', {'ログイン'}), ('ログを削除するバッチを書いて', {'ログ', '削除'}), ('管理者を追加するAPIを作る', {'管理者'}),
 ('管理画面のレイアウトを直す', {'管理'}), ('テストデータを削除して', {'テスト', '削除'}), ('ログイン後のログを確認したい', {'ログイン', 'ログ'}),
 ('デプロイ手順を教えて', {'デプロイ'}), ('通知の文面を変える', {'通知'}), ('DBの接続を設定する', {'DB'}), ('レビューを依頼する', {'レビュー'}),
 ('依存ライブラリを更新する', {'依存'}), ('費用が増えた原因を調べる', {'費用'}), ('ログインログの保存期間', {'ログイン', 'ログ'}),
 ('管理者ログインの失敗回数', {'管理者', 'ログイン'}), ('README を直す', set()), ('型エラーを直して', set()), ('変数名を変更する', set()),
 ('ログ出力のフォーマットを揃える', {'ログ'}), ('削除済みフラグを追加する', {'削除'}), ('通知設定画面を管理する人は誰か', {'通知', '管理'}),
 ('カタログの一覧を表示する', set()), ('ダイアログを閉じる処理', set()), ('テストが落ちる', {'テスト'}), ('リファクタリングしたい', set()),
 ('DBAに確認する', set()), ('デプロイ前のレビュー', {'デプロイ', 'レビュー'}), ('ログインのテストを書く', {'ログイン', 'テスト'}),
 ('管理職向けの資料を作る', set()), ('費用対効果を整理する', {'費用'}), ('削除ボタンの文言', {'削除'}),
]


def tags_substring(text):
    return {t for t in VOCAB if t.lower() in text.lower()}


def tags_longest(text):  # 語彙の最長一致を先に消費し、重なる短い語は発火させない
    used, found = [False] * len(text), set()
    for t in sorted(VOCAB, key=len, reverse=True):
        for m in re.finditer(re.escape(t), text, re.I):
            if not any(used[m.start():m.end()]):
                for i in range(m.start(), m.end()): used[i] = True
                found.add(t)
    return found


def tags_janome(text):  # 形態素の表層/基本形が語彙に完全一致したものだけ
    return {tok for tok in (t.surface for t in TK.tokenize(text)) if tok in VOCAB} | {t.base_form for t in TK.tokenize(text) if t.base_form in VOCAB}


def evaluate_tags():
    print('\n== タグ逆引きの誤発火 (合成プロンプト%d件, 語彙%d語) ==' % (len(PROMPTS), len(VOCAB)))
    for name, fn in (('部分文字列(D の現行方式)', tags_substring), ('最長一致+重なり抑止', tags_longest), ('janome 完全一致', tags_janome)):
        tp = fp = fn_ = 0; bad = []
        for p, gold in PROMPTS:
            got = fn(p); tp += len(got & gold); fp += len(got - gold); fn_ += len(gold - got)
            if got != gold: bad.append((p, sorted(got - gold), sorted(gold - got)))
        fired = tp + fp
        print(f'{name:22s} 発火{fired}件 うち誤発火{fp}件 (誤発火率={fp/fired:.2f})  取りこぼし{fn_}件 (再現率={tp/(tp+fn_):.2f})')
        for b in bad: print('    ', b)


if __name__ == '__main__':
    db = mk(); evaluate(db); evaluate_tags()
    # 索引サイズ (合成の複製 4000 件。内容は同じ文の反復なので「相対比」のみ参考)
    for name, tok in (('trigram', 'trigram'), ('janome', None)):
        p = os.path.join(tempfile.mkdtemp(), 'x.db'); d = sqlite3.connect(p); t0 = time.time()
        if tok:
            d.execute("CREATE VIRTUAL TABLE f USING fts5(t, tokenize='trigram')")
            d.executemany('INSERT INTO f VALUES (?)', [(x[2] + str(i),) for i in range(112) for x in DOCS])
        else:
            d.execute("CREATE VIRTUAL TABLE f USING fts5(t)")
            d.executemany('INSERT INTO f VALUES (?)', [(' '.join(jtokens(x[2])) + ' n' + str(i),) for i in range(112) for x in DOCS])
        d.commit(); d.close()
        print(f'索引サイズ {name}: {os.path.getsize(p)/1024:.0f} KiB ({112*len(DOCS)} 行) 構築時間 {time.time()-t0:.1f}s')
