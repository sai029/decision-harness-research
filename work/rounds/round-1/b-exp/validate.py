import json,re,sys
thread=open(sys.argv[2],encoding='utf-8').read()
msgs={m.group(1):m.group(0) for m in re.finditer(r'\[(M\d+)\][^\n]*',thread)}
raw=open(sys.argv[1],encoding='utf-8').read().strip()
raw=re.sub(r'^```(?:json)?\s*|\s*```$','',raw)
d=json.loads(raw)
bad=0;tot=0
for x in d['decisions']:
    if x.get('status')!='hypothesis': print('STATUS NOT HYPOTHESIS',x['id']); bad+=1
    for e in x['evidence']:
        tot+=1
        ok=e['message_id'] in msgs and e['quote'] in msgs[e['message_id']]
        if not ok: bad+=1; print('QUOTE MISMATCH',x['id'],e)
print('decisions',len(d['decisions']),'quotes',tot,'bad',bad)
for x in d['decisions']: print(x['id'],'|',x['title'],'| decider=',x['decider'],'| sup=',x.get('superseded_by'),'| conf=',x['confidence'])
print('pending',[p if isinstance(p,str) else p for p in d.get('pending_questions',[])])
print('injection',d.get('injection_suspected'))
