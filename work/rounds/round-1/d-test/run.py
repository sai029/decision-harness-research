import sqlite3, time, json, sys
db = sqlite3.connect(':memory:'); db.executescript(open('schema.sql',encoding='utf-8').read())
# synthetic data only
rows = [
 ('D-001','外部公開前は人間承認','外部へ公開するリリースは必ず人間の承認を取る','公開は戻せない','approved','one_way','human_required',0.95,'',None,0,'release 公開 承認'),
 ('D-002','DB削除','本番データの削除はエージェントが行わない','削除は復元不能','approved','one_way','human_required',0.9,'db/**',None,0,'削除 delete'),
 ('D-003','ログ形式','ログはJSON Linesで出力する','解析容易性','approved','reversible','agent_ok',0.8,'src/**',None,1,'ログ logging'),
 ('D-004','予算','月額5万円以内の新規SaaS契約は事後報告','予算枠','approved','reversible','notify',0.7,'',None,1,'予算 契約 budget'),
 ('D-005','命名','変数名は英語のsnake_caseにする','一貫性','approved','reversible','agent_ok',0.85,'src/**',None,2,'命名 naming'),
 ('D-006','旧方針','CSVで出力する','古い','superseded','reversible','agent_ok',0.4,'',None,2,'出力 csv'),
]
for i,r in enumerate(rows,1):
    db.execute('INSERT INTO decision VALUES (?,?,?,?,?,?,?,?,?,?,?)', r[:11])
    for t in r[11].split(): db.execute('INSERT INTO decision_tag VALUES (?,?)',(r[0],t))
    for tb in ('decision_fts','decision_fts_uni'):
        db.execute(f'INSERT INTO {tb}(rowid,title,rule,rationale,tags) VALUES (?,?,?,?,?)',(i,r[1],r[2],r[3] or '',r[11]))
def q(tb, m):
    try:
        return [x[0] for x in db.execute(f'SELECT rowid FROM {tb} WHERE {tb} MATCH ? ORDER BY bm25({tb},5.0,3.0,1.0,2.0) LIMIT 5',(m,))]
    except Exception as e: return 'ERR '+str(e)
for m in ['削除','本番データの削除','公開','承認','予算','ログ','release','snake_case','JSON']:
    print(repr(m),'trigram=',q('decision_fts',m),'unicode61=',q('decision_fts_uni',m))
# LIKE fallback for short CJK terms via a plain join (no index)
print('LIKE 予算 ->',[x[0] for x in db.execute("SELECT id FROM decision WHERE status='approved' AND (title LIKE ? OR rule LIKE ?)",('%予算%','%予算%'))])
# tags exact lookup (indexed path)
print('tag 削除 ->',[x[0] for x in db.execute("SELECT d.id FROM decision d JOIN decision_tag t ON t.decision_id=d.id WHERE t.tag=? AND d.status='approved'",('削除',))])
# latency at scale
import random,string
db.commit(); db.execute('BEGIN')
words=['認証','キャッシュ','リトライ','予算','公開','削除','テスト','命名','ログ','依存','移行','権限']
for i in range(7,20007):
    t=''.join(random.choice(words) for _ in range(4)); r=''.join(random.choice(words)+'は' for _ in range(8))
    for tb in ('decision_fts',): db.execute(f'INSERT INTO {tb}(rowid,title,rule,rationale,tags) VALUES (?,?,?,?,?)',(i,t,r,'',''))
db.execute('COMMIT')
for m in ['"リトライ"','"移行は"','"権限は認証"']:
    t=time.perf_counter(); n=0
    for _ in range(20): n=len(q('decision_fts',m))
    print(m,'20k rows avg ms',(time.perf_counter()-t)/20*1000,n)
print('sqlite',sqlite3.sqlite_version)
