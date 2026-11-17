"""E11: 事後合理化の検出指標（合成デモ）。面接で語られた判断軸(stated)を、過去の実際の選択(revealed)に当てて一致率を測る。
これは指標の動作確認であり、妥当性の証拠ではない（合成データ。回答者の挙動は私が決めた）。"""
import random
random.seed(7)
# 合成の過去判断: 各ケースに2案(各案は cost 低いほど良い, speed 高いほど良い)。実際の選択は revealed 規則で決まる。
def make_cases(n=24):
    cs=[]
    for _ in range(n):
        a=dict(cost=random.randint(1,9),speed=random.randint(1,9)); b=dict(cost=random.randint(1,9),speed=random.randint(1,9))
        cs.append((a,b))
    return cs
RULE={'cost_first':lambda o:(-o['cost'],o['speed']),'speed_first':lambda o:(o['speed'],-o['cost'])}
def choose(rule,a,b):
    ka,kb=RULE[rule](a),RULE[rule](b)
    return 0 if ka>=kb else 1
cases=make_cases()
people={'honest(states=acts)':('cost_first','cost_first'),'rationalizer(states cost, acts speed)':('cost_first','speed_first')}
train,test=cases[:12],cases[12:]   # 時系列分割に相当: 前半=面接前の記録で revealed を推定、後半=held-out
for name,(stated,acts) in people.items():
    actual_test=[choose(acts,a,b) for a,b in test]
    actual_train=[choose(acts,a,b) for a,b in train]
    # revealed 規則の推定: 前半の選択を最もよく説明する規則
    fit={r:sum(choose(r,a,b)==c for (a,b),c in zip(train,actual_train)) for r in RULE}
    revealed=max(fit,key=fit.get)
    agree_stated=sum(choose(stated,a,b)==c for (a,b),c in zip(test,actual_test))/len(test)
    agree_revealed=sum(choose(revealed,a,b)==c for (a,b),c in zip(test,actual_test))/len(test)
    gap=agree_revealed-agree_stated
    print(f"{name:40s} stated={stated:11s} revealed(est)={revealed:11s} held-out agreement: stated={agree_stated:.2f} revealed={agree_revealed:.2f} gap={gap:+.2f} -> {'FLAG rationalization?' if gap>=0.25 else 'ok'}")
