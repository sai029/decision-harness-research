"""Markdown(Git) 正本 -> SQLite 派生索引の再構築 (担当C round-1 再調査)。
使い方: python -I c_rebuild.py <repo_dir> <db_path> [schema.sql]
- decisions/*.md と decisions/_inbox/*.md を読む。frontmatter は単純な YAML 部分集合 (key: value, [a, b])。
- status は Markdown では proposed|approved|revoked のみ。superseded は索引側がエッジから導出する。
- git 履歴があれば decision_history を版ごとに作る (recorded_from = コミット日時)。
- supersedes エッジは src.valid_from 昇順で挿入。DB のガード(E3)に拒否されたら rejected に記録して続行。
"""
import sys, os, re, sqlite3, subprocess, hashlib, json

HERE = os.path.dirname(os.path.abspath(__file__))
LIST_KEYS = {'supersedes', 'contradicts', 'depends_on', 'tags', 'evidence'}


def parse(text):
    m = re.match(r'^---\n(.*?)\n---\n?(.*)$', text, re.S)
    if not m:
        raise ValueError('no frontmatter')
    fm = {}
    for line in m.group(1).split('\n'):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        k, _, v = line.partition(':')
        k, v = k.strip(), re.sub(r'\s+#.*$', '', v).strip()
        if k in LIST_KEYS:
            v = v.strip('[]')
            fm[k] = [x.strip() for x in v.split(',') if x.strip()] if v else []
        else:
            fm[k] = None if v in ('', 'null') else v
    fm['body'] = m.group(2).strip()
    return fm


def git(repo, *args):
    return subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, encoding='utf-8')


def rebuild(repo, db_path, schema=None):
    schema = schema or os.path.join(HERE, 'c_schema_r2.sql')
    if os.path.exists(db_path):
        os.remove(db_path)
    db = sqlite3.connect(db_path)
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript(open(schema, encoding='utf-8').read())
    files = []
    for sub in ('decisions', os.path.join('decisions', '_inbox')):
        d = os.path.join(repo, sub)
        if os.path.isdir(d):
            files += [os.path.join(sub, f) for f in sorted(os.listdir(d)) if f.endswith('.md')]
    rejected, docs = [], []
    gp = os.path.join(repo, 'governance', 'role_grant.csv')   # 役割の権限ランク (scope ごと)。承認済みのファイルとして Git 管理
    if os.path.exists(gp):
        for line in open(gp, encoding='utf-8').read().splitlines()[1:]:
            if line.strip():
                r_, s_, k_ = line.split(',')
                db.execute('INSERT INTO role_grant VALUES (?,?,?)', (r_.strip(), s_.strip(), int(k_)))
    for rel in files:
        raw = open(os.path.join(repo, rel), encoding='utf-8').read()
        fm = parse(raw)
        h = hashlib.sha256(raw.encode('utf-8')).hexdigest()
        db.execute('INSERT INTO decision(id,title,body,status,reversibility,authority,confidence,scope,topic_key,'
                   'overridable,decided_by,approval_ref,valid_from,valid_to,recorded_at,expires_at,source_path,content_hash)'
                   ' VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                   (fm['id'], fm['title'], fm['body'], fm['status'], fm['reversibility'], fm['authority'],
                    float(fm['confidence']) if fm.get('confidence') else None, fm.get('scope') or 'global',
                    fm.get('topic_key'), int(fm.get('overridable') or 1), fm['decided_by'], fm.get('approval_ref'),
                    fm['valid_from'], fm.get('valid_to'), fm['recorded_at'], fm.get('expires_at'),
                    rel.replace(os.sep, '/'), h))
        for t in fm.get('tags', []):
            db.execute('INSERT INTO decision_tag VALUES (?,?)', (fm['id'], t))
        for ev in fm.get('evidence', []):
            kind, ref, sens = ev.split('|')
            db.execute('INSERT INTO evidence(decision_id,kind,ref,sensitivity) VALUES (?,?,?,?)', (fm['id'], kind, ref, sens))
        docs.append((rel, fm))
        # 版履歴 (git があれば)
        log = git(repo, 'log', '--format=%H|%aI', '--reverse', '--', rel.replace(os.sep, '/'))
        revs = [l.split('|') for l in log.stdout.strip().split('\n') if l] if log.returncode == 0 else []
        for i, (ch, when) in enumerate(revs, 1):
            shown = git(repo, 'show', f'{ch}:{rel.replace(os.sep, "/")}')
            f2 = parse(shown.stdout)
            nxt = revs[i][1] if i < len(revs) else None
            db.execute('INSERT INTO decision_history VALUES (?,?,?,?,?,?,?,?)',
                       (fm['id'], i, when[:10], nxt[:10] if nxt else None, f2['valid_from'], f2.get('valid_to'), f2['status'], ch[:12]))
    edges = []
    for rel, fm in docs:
        for r in ('supersedes', 'contradicts', 'depends_on'):
            for dst in fm.get(r, []):
                edges.append((fm['valid_from'], fm['id'], dst, r))
    for _, src, dst, r in sorted(edges):
        try:
            db.execute('INSERT INTO decision_edge VALUES (?,?,?)', (src, dst, r))
        except sqlite3.DatabaseError as e:
            rejected.append({'src': src, 'dst': dst, 'rel': r, 'error': str(e)})
    db.commit()
    return db, rejected


def canonical_hash(db):
    parts = []
    for t, order in (('decision', 'id'), ('decision_tag', 'decision_id,tag'), ('evidence', 'decision_id,ref'),
                     ('decision_edge', 'src,dst,rel'), ('decision_history', 'id,rev')):
        parts.append(t + json.dumps(db.execute(f'SELECT * FROM {t} ORDER BY {order}').fetchall(), ensure_ascii=False))
    return hashlib.sha256('\n'.join(parts).encode('utf-8')).hexdigest()


if __name__ == '__main__':
    d, rej = rebuild(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    print('hash', canonical_hash(d))
    print('rejected_edges', json.dumps(rej, ensure_ascii=False))
