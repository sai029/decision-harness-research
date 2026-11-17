import sqlite3, json, os, subprocess, sys
H = os.path.dirname(os.path.abspath(__file__)); os.chdir(H)
DB = 'e2_test.db'
for f in (DB, 'approvers.pub.json', 'keys/ken.key'):
    if os.path.exists(f): os.remove(f)
subprocess.run([sys.executable, 'approve.py', 'keygen', 'ken'], check=True)  # 合成の承認者 ken（実在の人物ではない）
c = sqlite3.connect(DB); c.executescript(open('candidate_v2.sql', encoding='utf-8').read()); c.commit()
c.execute("INSERT INTO source_item VALUES('s1','slack','ken','2026-03-02','human','abc',NULL)")
for i in (1, 2, 3, 4):
    c.execute("INSERT INTO decision_candidate(cand_id,title,decision,decider,decider_evidence,extractor,extracted_at) VALUES(?,?,?,?,?,?,?)",
              (f'D{i}', f't{i}', f'd{i}', 'ken', 'M2', 'sonnet', '2026-11-17'))
    c.execute("INSERT INTO evidence VALUES(?,?,?,1,'decision')", (f'D{i}', 's1', 'q'))
c.commit(); c.close()
res = []
def t(name, fn, expect_fail):
    try:
        fn(); ok = not expect_fail; msg = 'OK'
    except Exception as e:
        ok = expect_fail; msg = f'FAIL({type(e).__name__}: {e})'
    for cc in OPEN:
        try: cc.rollback(); cc.close()
        except Exception: pass
    OPEN.clear()
    res.append(ok); print(('PASS ' if ok else 'BAD  ') + name + ' -> ' + msg)
OPEN=[]
def agent():  # エージェントの接続: 検証関数なし
    c=sqlite3.connect(DB, timeout=0.5); OPEN.append(c); return c
FSIG = 'ab' * 64
def f1():
    a = agent()
    a.execute("INSERT INTO decision_candidate(cand_id,title,decision,decider,decider_evidence,status,extractor,extracted_at,confirmed_by,confirmed_at) VALUES('X1','t','d','ken','M2','confirmed','agent','x','ken','2026-11-17T00:00:00Z')")
    a.commit()
t('1 agent INSERT decision_candidate status=confirmed, approver=ken (INSERT path) -> must be rejected', f1, True)
def f2():
    a = agent(); a.execute("UPDATE decision_candidate SET status='confirmed',confirmed_by='ken',confirmed_at='2026-11-17T00:00:00Z' WHERE cand_id='D1'"); a.commit()
t('2 agent UPDATE to confirmed with approver=ken, no signed confirmation row -> must be rejected', f2, True)
def f2b():
    a = agent(); a.execute("INSERT INTO confirmation VALUES('D1','t1','d1',NULL,'ken',NULL,'ken','2026-11-17T00:00:00Z','" + FSIG + "')"); a.commit()
t('2b agent INSERT forged confirmation row, no verifier fn -> must be rejected', f2b, True)
def f3():
    a = agent(); a.create_function('verify_confirmation', -1, lambda *x: 1)
    a.execute("INSERT INTO confirmation VALUES('D2','t2','d2',NULL,'ken',NULL,'ken','2026-11-17T00:00:00Z','" + FSIG + "')")
    a.execute("UPDATE decision_candidate SET status='confirmed',confirmed_by='ken',confirmed_at='2026-11-17T00:00:00Z' WHERE cand_id='D2'"); a.commit()
t('3 agent registers its own always-1 verifier and forges D2 (DB-level defense bypassed; expected to SUCCEED = known limit)', f3, False)
from verify_chain import verified_confirmed
ok, bad = verified_confirmed(DB); print('   verify_chain: verified=', ok, 'forged=', bad)
res.append(bad == ['D2'] and ok == []); print(('PASS ' if res[-1] else 'BAD  ') + '4 out-of-band verify_chain flags D2 as forged and does not count it as confirmed')
subprocess.run([sys.executable, 'approve.py', 'confirm', DB, 'D3', 'ken'], check=True)
ok, bad = verified_confirmed(DB); print('   verify_chain: verified=', ok, 'forged=', bad)
res.append(ok == ['D3'] and bad == ['D2']); print(('PASS ' if res[-1] else 'BAD  ') + '5 legit confirm via approve.py is verified (D3), D2 stays forged')
sig = sqlite3.connect(DB).execute("SELECT sig,approved_at FROM confirmation WHERE cand_id='D3'").fetchone()
from sigcommon import make_verifier
reg = json.load(open('approvers.pub.json'))
def f6():
    a = agent(); a.create_function('verify_confirmation', -1, make_verifier(reg))
    a.execute("INSERT INTO confirmation VALUES('D4','t4','d4',NULL,'ken',NULL,'ken',?,?)", (sig[1], sig[0])); a.commit()
t('6 replay D3 signature onto D4 (real verifier) -> must be rejected', f6, True)
def f7():
    a = agent(); a.create_function('verify_confirmation', -1, make_verifier(reg))
    a.execute("INSERT INTO confirmation VALUES('D4','t4','d4',NULL,'ken',NULL,'mallory','x','" + 'cd' * 64 + "')"); a.commit()
t('7 unregistered approver id (real verifier) -> must be rejected', f7, True)
def f8():
    a = agent(); a.execute("UPDATE decision_candidate SET decision='tampered' WHERE cand_id='D3'"); a.commit()
t('8 edit decision text of confirmed D3 -> must be rejected', f8, True)
def f9():
    a = agent(); a.execute("UPDATE decision_candidate SET status='hypothesis' WHERE cand_id='D3'"); a.commit()
t('9 downgrade confirmed D3 to hypothesis -> must be rejected', f9, True)
def f10():
    a = agent(); a.execute("INSERT INTO decision_candidate(cand_id,title,decision,extractor,extracted_at) VALUES('H1','t','d','agent','x')"); a.commit()
t('10 agent INSERT of hypothesis row -> allowed', f10, False)
def f11():
    a = sqlite3.connect(f'file:{DB}?mode=ro', uri=True); OPEN.append(a)
    a.execute("INSERT INTO decision_candidate(cand_id,title,decision,extractor,extracted_at) VALUES('H2','t','d','agent','x')")
t('11 agent read-only connection INSERT -> must be rejected', f11, True)
def f12():
    r=subprocess.run([sys.executable, 'approve.py', 'confirm', DB, 'H1', 'ken'], capture_output=True, text=True, encoding='utf-8')
    print('   approve.py stderr tail:', r.stderr.strip().splitlines()[-1] if r.stderr.strip() else '')
    if r.returncode: raise RuntimeError('approve.py failed')
t('12 legit signature but no verified evidence (H1) -> must be rejected', f12, True)
print('ALL EXPECTATIONS MET' if all(res) else 'SOME EXPECTATIONS NOT MET', f'{sum(res)}/{len(res)}')

os.remove('keys/ken.key')  # 合成デモ鍵を残さない
