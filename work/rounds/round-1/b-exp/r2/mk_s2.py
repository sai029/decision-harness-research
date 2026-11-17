import json,re,sys
v,t=sys.argv[1],sys.argv[2]
raw=open(f'out/{v}_{t}.json',encoding='utf-8').read().strip()
raw=re.sub(r'^```(?:json)?\s*|\s*```$','',raw)
d=json.loads(raw)
print(open('pS2.txt',encoding='utf-8').read())
print('--- スレッド（データ）---'); print(open(f'{t}.txt',encoding='utf-8').read())
print('--- 判断候補 ---')
for x in d['decisions']:
    print(json.dumps({'id':x['id'],'decision':x['decision'],'evidence':x['evidence']},ensure_ascii=False))
