"""人の承認ツール。秘密鍵はここ（承認プロセス）だけが読める前提（OS の権限で分離。デモでは keys/ に置く）。
使い方: python approve.py keygen <approver_id> | confirm <db> <cand_id> <approver_id>"""
import sys,json,sqlite3,datetime,os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as S
from sigcommon import canon,make_verifier
HERE=os.path.dirname(os.path.abspath(__file__))
def keygen(aid):
    os.makedirs(f'{HERE}/keys',exist_ok=True)
    sk=Ed25519PrivateKey.generate()
    open(f'{HERE}/keys/{aid}.key','wb').write(sk.private_bytes(S.Encoding.Raw,S.PrivateFormat.Raw,S.NoEncryption()))
    pub=sk.public_key().public_bytes(S.Encoding.Raw,S.PublicFormat.Raw).hex()
    reg=json.load(open(f'{HERE}/approvers.pub.json')) if os.path.exists(f'{HERE}/approvers.pub.json') else {}
    reg[aid]=pub; json.dump(reg,open(f'{HERE}/approvers.pub.json','w'),indent=1)
def confirm(db,cand_id,aid):
    sk=Ed25519PrivateKey.from_private_bytes(open(f'{HERE}/keys/{aid}.key','rb').read())
    reg=json.load(open(f'{HERE}/approvers.pub.json'))
    c=sqlite3.connect(db); c.create_function('verify_confirmation',-1,make_verifier(reg))
    r=c.execute('SELECT cand_id,title,decision,rationale,decider,scope FROM decision_candidate WHERE cand_id=?',(cand_id,)).fetchone()
    now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    sig=sk.sign(canon(*r,aid,now)).hex()
    c.execute('INSERT INTO confirmation VALUES(?,?,?,?,?,?,?,?,?)',(*r,aid,now,sig))
    c.execute("UPDATE decision_candidate SET status='confirmed',confirmed_by=?,confirmed_at=? WHERE cand_id=?",(aid,now,cand_id)); c.commit()
if __name__=='__main__':
    if sys.argv[1]=='keygen': keygen(sys.argv[2])
    else: confirm(*sys.argv[2:5])
