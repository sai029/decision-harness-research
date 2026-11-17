import sqlite3
c=sqlite3.connect(':memory:'); c.executescript(open('candidate.sql',encoding='utf-8').read())
c.execute("INSERT INTO source_item VALUES('s1','slack','ken','2026-03-02','human','abc',NULL)")
c.execute("INSERT INTO decision_candidate(cand_id,title,decision,decider,decider_evidence,extractor,extracted_at) VALUES('D1','t','d','ken','M2','sonnet','2026-11-17')")
c.execute("INSERT INTO evidence VALUES('D1','s1','q',0,'decision')")
def t(name,sql):
    try: c.execute(sql); print('OK  ',name)
    except Exception as e: print('FAIL',name,'->',e)
t('confirm without verified evidence (expect FAIL)',"UPDATE decision_candidate SET status='confirmed',confirmed_by='me',confirmed_at='x' WHERE cand_id='D1'")
c.execute("UPDATE evidence SET quote_verified=1")
t('confirm without confirmer (expect FAIL)',"UPDATE decision_candidate SET status='confirmed' WHERE cand_id='D1'")
t('confirm with verified evidence+confirmer (expect OK)',"UPDATE decision_candidate SET status='confirmed',confirmed_by='me',confirmed_at='x' WHERE cand_id='D1'")
t('decider without evidence (expect FAIL)',"INSERT INTO decision_candidate(cand_id,title,decision,decider,extractor,extracted_at) VALUES('D2','t','d','ken','s','x')")
