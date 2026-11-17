"""注入側/CI が使う独立検証。DB の status を信用せず、confirmation の署名を公開鍵で再検証して confirmed を数える。"""
import sys,json,sqlite3,os
from sigcommon import make_verifier
HERE=os.path.dirname(os.path.abspath(__file__))
def verified_confirmed(db):
    v=make_verifier(json.load(open(f'{HERE}/approvers.pub.json')))
    c=sqlite3.connect(f'file:{db}?mode=ro',uri=True); ok=[];bad=[]
    q="""SELECT d.cand_id,k.title,k.decision,k.rationale,k.decider,k.scope,k.approver_id,k.approved_at,k.sig,
         (k.title=d.title AND k.decision=d.decision AND k.rationale IS d.rationale AND k.decider IS d.decider AND k.scope IS d.scope)
         FROM decision_candidate d LEFT JOIN confirmation k ON k.cand_id=d.cand_id AND k.approver_id=d.confirmed_by AND k.approved_at=d.confirmed_at
         WHERE d.status='confirmed'"""
    for r in c.execute(q):
        good = r[8] is not None and r[9]==1 and v(*r[:9])==1
        (ok if good else bad).append(r[0])
    return ok,bad
if __name__=='__main__': print(verified_confirmed(sys.argv[1]))
