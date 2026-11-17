# False-fire / recall measurement for tag matching in Japanese. SYNTHETIC; labels are by the author (construction), see D.md.
# Methods: M1 substring reverse lookup, M2 substring + not_followed_by guard, M3 Janome token-sequence match,
#          M4 substring that must align to Janome token boundaries.
import sys, json, itertools
from janome.tokenizer import Tokenizer
sys.stdout.reconfigure(encoding='utf-8')
tk = Tokenizer()
def toks(s): return [t.surface for t in tk.tokenize(s)]
TAGS = ['削除','公開','承認','予算','ログ','認証','本番データ','命名','返金','契約','権限','通知','暗号化','移行']
T = ["{x}の件を確認して", "{x}を実行する前に方針を確認したい", "今日は{x}に関するタスクを進めて", "{x}について手順を整理して", "来週の{x}の扱いを決めたい", "{x}する場合の注意点は?"]
# confusables: contain the tag string but mean something else (author's judgment). DEV = used to write guards; HELD = not used.
DEV  = {'ログ':['ログイン','ログアウト','ブログ'], '公開':['公開鍵'], '承認':['承認欲求'], '予算':['予算委員会'], '通知':['通知表'], '契約':['契約社員']}
HELD = {'ログ':['カタログ','ダイアログ'], '公開':['非公開フォルダ'], '削除':['削除線'], '命名':['命名権']}  # new words not in DEV
# guards derived ONLY from DEV (what a maintainer would write after seeing these false fires)
GUARD = {'ログ':['イン','アウト'], '公開':['鍵'], '承認':['欲求'], '予算':['委員会'], '通知':['表'], '契約':['社員']}
# note: ブログ has ログ preceded by ブ, not followed -> not_followed_by cannot catch it (documented limitation)
PARA = {'削除':'データを消したい','公開':'世の中に出す前に','予算':'使えるお金の上限を','承認':'上長のOKをもらう','認証':'パスワードで本人確認','返金':'お客様にお金を戻す','暗号化':'中身を読めないようにする','権限':'誰が操作できるか'}
CLEAN_NOUNS = ['天気','請求書の書式','会議室の予約','弁当','週報','フォント','色の選択','ランチ','出張の旅程','資料の誤字','テストの並び順','アイコン','翻訳','議事録の要約','カレンダー']
def has_tag(s): return [t for t in TAGS if t in s]
pos  = [(T[i].format(x=t), t) for t in TAGS for i in range(len(T))]
neg_dev  = [(T[i].format(x=c), t) for t, cs in DEV.items() for c in cs for i in range(3)]
neg_held = [(T[i].format(x=c), t) for t, cs in HELD.items() for c in cs for i in range(3)]
clean = [(T[i].format(x=n), None) for n in CLEAN_NOUNS for i in range(3)]
para  = [(T[i].format(x=p), t) for t, p in PARA.items() for i in range(3)]
assert all(not has_tag(s) for s, _ in clean + para), [s for s, _ in clean + para if has_tag(s)]
# held-out confusables that do NOT actually contain the tag would be meaningless: check they contain it
assert all(t in s for s, t in neg_dev + neg_held)

def m1(s, t): return t in s
def m2(s, t):
    g = GUARD.get(t, []); st = 0
    while True:
        i = s.find(t, st)
        if i < 0: return False
        if not any(s[i+len(t):].startswith(x) for x in g): return True
        st = i + 1
def subseq(a, b):
    n = len(b)
    return any(a[i:i+n] == b for i in range(len(a) - n + 1))
def m3(s, t): return subseq(toks(s), toks(t))
def m4(s, t):
    ts = toks(s); bounds = {0}; p = 0
    for x in ts: p += len(x); bounds.add(p)
    st = 0
    while True:
        i = s.find(t, st)
        if i < 0: return False
        if i in bounds and (i + len(t)) in bounds: return True
        st = i + 1
def m5(s, t): return m2(s, t) and m4(s, t)
M = {'M5 guard AND janome-aligned': m5, 'M1 substring': m1, 'M2 substring+guard(dev-derived)': m2, 'M3 janome token-seq': m3, 'M4 substring aligned to janome boundaries': m4}
print(f'n: literal-positive={len(pos)} paraphrase-positive={len(para)} neg_dev={len(neg_dev)} neg_heldout={len(neg_held)} neg_clean={len(clean)}')
print('janome tokenization samples:', {w: toks(w) for w in ['ログイン','カタログ','ブログ','公開鍵','本番データ','削除','暗号化','承認欲求','通知表','契約社員']})
print(f"{'method':46s} {'recall(literal)':>16s} {'recall(paraphrase)':>19s} {'FP dev':>8s} {'FP heldout':>11s} {'FP clean':>9s}")
for name, f in M.items():
    r = sum(f(s, t) for s, t in pos); rp = sum(f(s, t) for s, t in para)
    fd = sum(f(s, t) for s, t in neg_dev); fh = sum(f(s, t) for s, t in neg_held); fc = sum(any(f(s, t) for t in TAGS) for s, _ in clean)
    print(f'{name:46s} {r:>3d}/{len(pos):<3d}={r/len(pos):.2f}     {rp:>3d}/{len(para):<3d}={rp/len(para):.2f}      {fd:>3d}/{len(neg_dev):<3d}  {fh:>3d}/{len(neg_held):<3d}={fh/len(neg_held):.2f}  {fc:>3d}/{len(clean)}')
print('\nheld-out false fires under M2 (guard from dev only):')
for s, t in neg_held:
    if m2(s, t): print('  ', t, '<-', s)
print('\nliteral-positive misses under M3 (tokenizer split disagreement):')
for s, t in pos:
    if not m3(s, t): print('  ', t, toks(t), '|', toks(s))
