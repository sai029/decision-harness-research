"""担当C round-1 再調査: E3 / E4(v_active) / E9 / bitemporal / 再構築性 の実行テスト (合成データのみ)。
使い方: python -I c_r2_test.py <作業ディレクトリ(空)>
"""
import sys, os, subprocess, sqlite3, json, re

sys.stdout.reconfigure(encoding='utf-8')
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import c_rebuild as R

work = sys.argv[1]
repo = os.path.join(work, 'repo')
os.makedirs(os.path.join(repo, 'decisions', '_inbox'), exist_ok=True)
results = []


def check(name, cond, detail=''):
    results.append(cond)
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{detail}]' if detail else ''))


def g(*a, date=None):
    env = dict(os.environ)
    if date:
        env['GIT_AUTHOR_DATE'] = env['GIT_COMMITTER_DATE'] = date
    r = subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-C', repo, *a],
                       capture_output=True, text=True, env=env, encoding='utf-8')
    assert r.returncode == 0, r.stderr


def doc(id, title, body, status='approved', rev='reversible', auth='agent_ok', scope='proj-x', topic='',
        by='role:lead-x', vf='2026-03-01', vt='', exp='', sup=(), inbox=False, over=1, ref=None, tags=()):
    ref = ref if ref is not None else ('' if status == 'proposed' else f'pr-{id[-4:]}')
    t = (f"---\nid: {id}\ntitle: {title}\nstatus: {status}\nreversibility: {rev}\nauthority: {auth}\nconfidence: 0.8\n"
         f"scope: {scope}\ntopic_key: {topic}\noverridable: {over}\ndecided_by: {by}\napproval_ref: {ref}\n"
         f"valid_from: {vf}\nvalid_to: {vt}\nrecorded_at: {vf}\nexpires_at: {exp}\nsupersedes: [{', '.join(sup)}]\n"
         f"tags: [{', '.join(tags)}]\nevidence: [chat|chat-export#m-{id[-4:]}|internal]\n---\n{body}\n")
    p = os.path.join(repo, 'decisions', *(['_inbox'] if inbox else []), id + '.md')
    open(p, 'w', encoding='utf-8').write(t)


g('init')
os.makedirs(os.path.join(repo, 'governance'), exist_ok=True)
open(os.path.join(repo, 'governance', 'role_grant.csv'), 'w', encoding='utf-8').write(
    'role,scope,rank\nrole:boss,proj-x,3\nrole:senior-a,proj-x,2\nrole:senior-a2,proj-x,2\nrole:lead-x,proj-x,1\nrole:boss,global,3\n')
# --- 合成の判断。rank: proj-x で boss=3, senior-a=2, senior-a2=2, lead-x=1。senior-b は proj-x に権限なし
doc('DEC-0001', 'DBは PostgreSQL を既定にする', '全社標準。', scope='global', topic='db', by='role:boss', auth='needs_human', vf='2026-01-01', tags=('db',))
doc('DEC-0002', 'proj-x の DB は SQLite にする', '小規模のため。', topic='db', by='role:lead-x', vf='2026-03-01', tags=('db',))
doc('DEC-0003', '外部公開APIの削除は人間承認が必須', '全社ポリシー。', scope='global', topic='api-delete', by='role:boss', auth='needs_human', vf='2026-01-01', over=0, tags=('削除',))
doc('DEC-0004', 'proj-x では外部公開APIの削除を自動で行う', '運用省力化。', topic='api-delete', by='role:lead-x', vf='2026-04-01', tags=('削除',))
doc('DEC-0005', 'DEC-0002 を取り消し PostgreSQL に戻す(提案)', 'エージェント抽出の仮説。', status='proposed', auth='needs_human', topic='db', by='role:agent', vf='2026-05-01', sup=('DEC-0002',), inbox=True)
doc('DEC-0006', '期限切れの判断', '再確認期限を過ぎた。', exp='2025-01-01', tags=('期限',))
doc('DEC-0007', 'ログレベルは INFO にする', '上司の判断。', topic='log-level', by='role:boss', auth='needs_human', vf='2026-02-01', tags=('ログ',))
doc('DEC-0008', 'ログレベルは DEBUG にする', '先輩の判断(後日)。', topic='log-level', by='role:senior-a', vf='2026-06-01', tags=('ログ',))
doc('DEC-0009', 'デプロイは火曜にする', '先輩Aの判断。', topic='deploy-day', by='role:senior-a', vf='2026-03-01')
doc('DEC-0010', 'デプロイは木曜にする', '先輩A2の判断。', topic='deploy-day', by='role:senior-a2', vf='2026-03-05')
doc('DEC-0011', 'レビューは2名必須にする', '先輩Bの判断。proj-x に権限なし。', topic='review', by='role:senior-b', vf='2026-03-01')
doc('DEC-0012', 'レビューは1名でよい', '先輩Aの判断。', topic='review', by='role:senior-a', vf='2026-03-02')
doc('DEC-0013', 'lint は warning で止めない', '先輩Aの旧判断。', topic='lint', by='role:senior-a', vf='2026-02-01')
doc('DEC-0014', 'lint は error で止める', '先輩Aの新判断。', topic='lint', by='role:senior-a', vf='2026-05-01')
doc('DEC-0015', 'キャッシュは 5 分にする(新)', '更新。', topic='cache', vf='2026-05-01', sup=('DEC-0016',))
doc('DEC-0016', 'キャッシュは 1 分にする(旧)', '旧版。', topic='cache', vf='2026-02-01')
doc('DEC-0017', 'バックアップは週次にする(agent_ok)', '新。', topic='backup', vf='2026-05-01', sup=('DEC-0018',))
doc('DEC-0018', 'バックアップは日次にする(人間判断)', '旧。', auth='needs_human', topic='backup', by='role:boss', vf='2026-02-01')
doc('DEC-0020', 'proj-z 専用の判断', '別プロジェクト。', scope='proj-z', vf='2026-03-01')
doc('DEC-0019', '一時的な凍結期間を設ける', '当初は無期限。', vf='2026-03-01')
g('add', '-A'); g('commit', '-m', 'v1', date='2026-03-01T10:00:00+09:00')
doc('DEC-0019', '一時的な凍結期間を設ける', '後日、2026-06-30 で終了していたと判明。', vf='2026-03-01', vt='2026-06-30')
g('add', '-A'); g('commit', '-m', 'v2 retro-correct', date='2026-09-01T10:00:00+09:00')

db_path = os.path.join(work, 'index.sqlite')
db, rej = R.rebuild(repo, db_path)
db.row_factory = None
print('== rebuild: rejected edges =='); [print(' ', json.dumps(x, ensure_ascii=False)) for x in rej]
for ro in db.execute("SELECT id,status,valid_to FROM decision WHERE id IN ('DEC-0002','DEC-0016','DEC-0018','DEC-0005') ORDER BY id"):
    print(' ', ro)

print('\n== E3: supersede ガード ==')
rej_map = {(x['src'], x['dst']): x['error'] for x in rej}
check('E3-1 proposed(DEC-0005) が approved(DEC-0002) を supersede しようとして拒否される', ('DEC-0005', 'DEC-0002') in rej_map, rej_map.get(('DEC-0005', 'DEC-0002')))
check('E3-2 拒否後も DEC-0002 は approved のまま', db.execute("SELECT status FROM decision WHERE id='DEC-0002'").fetchone()[0] == 'approved')
check('E3-3 agent_ok が needs_human を supersede しようとして拒否', ('DEC-0017', 'DEC-0018') in rej_map, rej_map.get(('DEC-0017', 'DEC-0018')))
check('E3-4 approved 同士・同 scope の supersede は有効 (DEC-0016 が superseded)', db.execute("SELECT status FROM decision WHERE id='DEC-0016'").fetchone()[0] == 'superseded')
# 直接 SQL (エージェントが DB を触った場合) でも同じ
for src, dst, name in (('DEC-0005', 'DEC-0004', 'E3-5 直接INSERT: proposed->approved'), ('DEC-0014', 'DEC-0016', 'E3-6 直接INSERT: approved->superseded済み')):
    try:
        db.execute("INSERT INTO decision_edge VALUES (?,?, 'supersedes')", (src, dst)); check(name, False, '通ってしまった')
    except sqlite3.DatabaseError as e:
        check(name + ' が拒否', True, str(e))
db.execute("UPDATE decision SET status='revoked' WHERE id='DEC-0004'")  # revoked な src も拒否されるか
try:
    db.execute("INSERT INTO decision_edge VALUES ('DEC-0004','DEC-0014','supersedes')"); check('E3-7 revoked src', False)
except sqlite3.DatabaseError as e:
    check('E3-7 revoked の src からの supersede が拒否', True, str(e))
db.execute("UPDATE decision SET status='approved' WHERE id='DEC-0004'")
db.commit()

SQL = open(os.path.join(HERE, 'c_effective.sql'), encoding='utf-8').read()
sec = dict(re.findall(r'-- @@(\w+)\n(.*?)(?=-- @@|\Z)', SQL, re.S))
pre = 'WITH t_pairs AS (' + sec['pairs'].strip() + ')\n'


def effective(scope, now='2026-11-17'):
    db.execute(pre + re.sub(r'^--.*\n', '', sec['ticket'], flags=re.M), {'scope': scope, 'now': now})
    return db.execute(pre + sec['effective'], {'scope': scope}).fetchall()


def pairs(scope):
    return {(a, b): o for a, b, o in db.execute(pre + 'SELECT a_id,b_id,outcome FROM t_pairs', {'scope': scope})}


print('\n== E4: v_active の除外 (expires_at は date(now) 比較) ==')
va = {r[0] for r in db.execute('SELECT id FROM v_active')}
check('E4-1 期限切れ DEC-0006 は v_active に無い', 'DEC-0006' not in va)
check('E4-2 superseded の DEC-0016 は v_active に無い', 'DEC-0016' not in va)
check('E4-3 valid_to 済み DEC-0019 は v_active に無い', 'DEC-0019' not in va)
check('E4-4 proposed の DEC-0005 は v_active に無い', 'DEC-0005' not in va)
ex = effective('proj-x'); ids_x = {r[0] for r in ex}
check('E4-5 scope 違い DEC-0020(proj-z) は proj-x の注入対象に無い', 'DEC-0020' not in ids_x)
ey = effective('proj-y'); ids_y = {r[0] for r in ey}
check('E4-6 proj-y では global の DEC-0001 が残り、proj-x の DEC-0002 は出ない', 'DEC-0001' in ids_y and 'DEC-0002' not in ids_y)

print('\n== E9: 優先規則 (proj-x 視点) ==')
p = pairs('proj-x')
for k in sorted(p): print(' ', k, p[k])
check('E9-1 global(boss) vs project(lead-x): project が勝つ(R1) -> DEC-0001 が注入から落ちる', p[('DEC-0001', 'DEC-0002')] == 'b:R1' and 'DEC-0001' not in ids_x and 'DEC-0002' in ids_x)
check('E9-2 overridable=0 の global は project に勝つ(R0) -> DEC-0004 が落ちる', p[('DEC-0003', 'DEC-0004')] == 'a:R0' and 'DEC-0003' in ids_x and 'DEC-0004' not in ids_x)
check('E9-3 上司(rank3) vs 先輩(rank2): 先輩が新しくても上司が勝つ(R2)', p[('DEC-0007', 'DEC-0008')] == 'a:R2' and 'DEC-0007' in ids_x and 'DEC-0008' not in ids_x)
check('E9-4 同 rank の別人(先輩A vs A2)は決めない -> 両方 conflict=1', p[('DEC-0009', 'DEC-0010')] == 'tie:same_rank_diff_person' and {'DEC-0009', 'DEC-0010'} <= ids_x)
check('E9-5 権限表に無い人(先輩B)が絡むと決めない(no_rank)', p[('DEC-0011', 'DEC-0012')] == 'tie:no_rank')
check('E9-6 同一人物の新旧(同 rank)は新しい方が勝つ(R3)', p[('DEC-0013', 'DEC-0014')] == 'b:R3' and 'DEC-0013' not in ids_x and 'DEC-0014' in ids_x)
cf = {r[0]: r[3] for r in ex}
check('E9-7 conflict フラグ: DEC-0009/10/11/12 が 1、DEC-0007 は 0', all(cf.get(i) == 1 for i in ('DEC-0009', 'DEC-0010', 'DEC-0011', 'DEC-0012')) and cf.get('DEC-0007') == 0)
tk = db.execute("SELECT a_id,b_id,reason,state FROM decision_conflict ORDER BY a_id").fetchall()
print('  decision_conflict:', tk)
check('E9-8 矛盾チケットが2件 open で作られる (再実行しても増えない)', len(tk) == 2 and (effective('proj-x') is not None) and db.execute('SELECT count(*) FROM decision_conflict').fetchone()[0] == 2)
print('  effective(proj-x):', [(r[0], r[3]) for r in ex])
print('  effective(proj-y):', [(r[0], r[3]) for r in ey])

print('\n== bitemporal (decision_history) ==')
Q = ("SELECT id FROM decision_history WHERE id='DEC-0019' AND recorded_from<=:r AND (recorded_to IS NULL OR recorded_to>:r)"
     " AND valid_from<=:v AND (valid_to IS NULL OR valid_to>=:v) AND status='approved'")
for r, v, exp, name in (('2026-08-01', '2026-07-15', True, '当時(8月)の認識では 7/15 は有効'), ('2026-10-01', '2026-07-15', False, '9月の訂正後は 7/15 は無効'), ('2026-10-01', '2026-05-01', True, '訂正後でも 5/1 は有効')):
    got = bool(db.execute(Q, {'r': r, 'v': v}).fetchall())
    check(f'BT {name} (記録時点={r}, 実世界={v})', got == exp)
print('  history:', db.execute("SELECT * FROM decision_history WHERE id='DEC-0019' ORDER BY rev").fetchall())

print('\n== 再構築性 ==')
h1 = R.canonical_hash(db); db.close()
db2, _ = R.rebuild(repo, os.path.join(work, 'index2.sqlite'))
# 注: db1 には上のテストで手を加えた (revoked->approved の往復のみ・エッジは拒否) ため、デタミニズムは db2 と db3 で比べる
h2 = R.canonical_hash(db2); db2.close()
os.remove(os.path.join(work, 'index2.sqlite'))
db3, _ = R.rebuild(repo, os.path.join(work, 'index2.sqlite'))
h3 = R.canonical_hash(db3)
check('RB-1 DB を削除して再構築しても正準ハッシュが一致', h2 == h3, h3[:16])
check('RB-2 テスト操作後の db1 とも一致 (往復の UPDATE は結果に残らない)', h1 == h3)
check('RB-3 PRAGMA integrity_check = ok', db3.execute('PRAGMA integrity_check').fetchone()[0] == 'ok')
try:
    db3.execute("INSERT INTO decision_fts(decision_fts) VALUES('integrity-check')"); check('RB-4 FTS integrity-check', True)
except sqlite3.DatabaseError as e:
    check('RB-4 FTS integrity-check', False, str(e))
n = db3.execute("SELECT count(*) FROM decision_fts WHERE decision_fts MATCH '外部公開'").fetchone()[0]
check('RB-5 FTS が再構築後に引ける (外部公開: DEC-0003/0004 の2件)', n == 2)
check('RB-6 evidence に excerpt 列が無い (本文複製なし)', 'excerpt' not in [c[1] for c in db3.execute('PRAGMA table_info(evidence)')])

print(f'\nTOTAL {sum(results)}/{len(results)} PASS')
sys.exit(0 if all(results) else 1)
