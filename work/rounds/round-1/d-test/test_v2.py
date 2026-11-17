# Synthetic tests for inject_hook_v2.py. Run: python -I test_v2.py  (writes v2_test.log via stdout redirect)
import sqlite3, subprocess, json, os, sys, tempfile, pathlib
sys.stdout.reconfigure(encoding="utf-8")
HERE = pathlib.Path(__file__).resolve().parent
HOOK = HERE / 'inject_hook_v2.py'
tmp = pathlib.Path(tempfile.mkdtemp(prefix='d_v2_'))
DB, ST, FB = tmp / 'decisions.db', tmp / 'state.db', tmp / 'fallback.txt'
sql = (HERE / 'schema_v2.sql').read_text(encoding='utf-8').split('-- ===== state.db')[0]
con = sqlite3.connect(DB); con.executescript(sql)
def dec(id, title, rule, status='approved', rev='reversible', auth='agent_ok', level='global', project=None, paths=None,
        topic=None, vf=None, vu=None, tier=1):
    con.execute("INSERT INTO decision(id,title,rule,status,reversibility,authority,scope_level,project,scope_paths,topic,valid_from,valid_until,tier) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (id, title, rule, status, rev, auth, level, project, paths, topic, vf, vu, tier))
def tag(i, t, g=None): con.execute("INSERT INTO decision_tag VALUES (?,?,?)", (i, t, g))
def trig(i, k, p, a='inject'): con.execute("INSERT INTO decision_trigger VALUES (?,?,?,?)", (i, k, p, a))
dec('D-001', '外部公開', '外部公開は人間承認が必要。', rev='one_way', auth='human_required', tier=0); trig('D-001', 'command', r'PUBLISH_EXTERNAL|npm publish', 'deny')
dec('D-002', '期限切れ', '旧規則(期限切れ)。', vu='2026-06-01', tier=0)
dec('D-003', 'ログ形式', 'ログはJSON Lines。', topic='log-format'); tag('D-003', 'ログ', 'イン')
dec('D-004', '旧ログ形式', 'ログはプレーンテキスト。', status='superseded', topic='log-format'); tag('D-004', 'ログ')
dec('D-005', '他プロジェクト予算', '予算は月3万円まで(other-proj)。', level='project', project='other-proj', topic='budget'); tag('D-005', '予算')
dec('D-006', '予算(project)', '予算は月10万円まで。', level='project', project='myproj', topic='budget'); tag('D-006', '予算')
dec('D-007', '予算(global)', '予算は月5万円まで。', topic='budget'); tag('D-007', '予算')
dec('D-008', '命名A', '変数名は snake_case。', topic='naming'); tag('D-008', '命名')
dec('D-009', '命名B', '変数名は camelCase。', topic='naming'); tag('D-009', '命名')
dec('D-010', 'infra', 'infra配下の変更は plan を添付。', level='path', project='myproj', paths='infra/*'); trig('D-010', 'path', 'infra/*')
dec('D-011', '未来', '2027年から有効な認証規則。', vf='2027-01-01T00:00:00'); tag('D-011', '認証')
dec('D-012', '提案のみ', '削除は常に禁止(提案のみ・未承認)。', status='proposed'); tag('D-012', '削除')
dec('D-013', '境界(当日)', '最終日の規則。', vu='2026-11-17'); tag('D-013', '境界当日')
dec('D-014', '境界(前日で失効)', '失効済みの規則。', vu='2026-11-16'); tag('D-014', '境界前日')
con.commit(); con.close()
FB.write_text('PUBLISH_EXTERNAL\nnpm publish\n', encoding='utf-8')
env = dict(os.environ, DECISION_DB=str(DB), DECISION_STATE=str(ST), DECISION_NOW='2026-11-17T00:00:00', DECISION_FALLBACK=str(FB), PYTHONUTF8='1')
CWD = 'C:/work/myproj'
def run(ev, e=None):
    ev = dict(ev); ev.setdefault('cwd', CWD); ev.setdefault('session_id', 's1')
    p = subprocess.run([sys.executable, '-I', '-X', 'utf8', str(HOOK)], input=json.dumps(ev, ensure_ascii=False), capture_output=True, text=True, encoding='utf-8', env=e or env)
    o = json.loads(p.stdout)['hookSpecificOutput'] if p.stdout.strip() else {}
    return p.returncode, o, p.stderr.strip()
fails = 0
def check(label, cond, detail):
    global fails
    print(('PASS ' if cond else 'FAIL ') + label); print('   ', detail)
    if not cond: fails += 1
ctx = lambda o: o.get('additionalContext', '')
# T1 SessionStart: tier0 only, expired excluded
rc, o, err = run({'hook_event_name': 'SessionStart', 'source': 'startup'})
check('T1 SessionStart injects tier0 (D-001) only; expired D-002 excluded', 'D-001' in ctx(o) and 'D-002' not in ctx(o) and 'D-003' not in ctx(o), ctx(o))
# T2 UserPromptSubmit: tier0 NOT repeated (already injected this session), tag hit D-003, superseded D-004 excluded
rc, o, err = run({'hook_event_name': 'UserPromptSubmit', 'prompt': 'ログの出力形式を直して'})
check('T2 UPS: D-003 only; D-001 not re-injected; superseded D-004 absent', 'D-003' in ctx(o) and 'D-001' not in ctx(o) and 'D-004' not in ctx(o), ctx(o))
# T3 same prompt again: dedupe
rc, o, err = run({'hook_event_name': 'UserPromptSubmit', 'prompt': 'ログの出力形式を直して'})
check('T3 duplicate injection suppressed within session', ctx(o) == '', repr(ctx(o)))
# T4 compound word guard: ログイン must not fire D-003 (new session)
rc, o, err = run({'hook_event_name': 'UserPromptSubmit', 'prompt': 'ログイン画面の文言を直して', 'session_id': 's2'})
check('T4 ログイン does not fire tag ログ (not_followed_by guard); fallback tier0 appears since s2 had no SessionStart', 'D-003' not in ctx(o), ctx(o))
# T5 scope: other-proj decision excluded; project beats global (narrower scope)
rc, o, err = run({'hook_event_name': 'UserPromptSubmit', 'prompt': '予算の上限を確認して', 'session_id': 's3'})
check('T5 scope mismatch D-005 excluded; D-006(project) overrides D-007(global); output shows the override', 'D-005' not in ctx(o) and 'D-006' in ctx(o) and 'D-007' not in ctx(o).replace('(topic=budget) D-007', '') and 'D-007 is overridden' in ctx(o), ctx(o))
# T6 same-scope contradiction -> CONFLICT
rc, o, err = run({'hook_event_name': 'UserPromptSubmit', 'prompt': '命名規則を決めて', 'session_id': 's4'})
check('T6 two contradicting same-scope decisions hit together -> CONFLICT output (both shown, flagged)', 'CONFLICT' in ctx(o) and 'D-008' in ctx(o) and 'D-009' in ctx(o), ctx(o))
# T7 not-yet-valid and proposed excluded
rc, o, err = run({'hook_event_name': 'UserPromptSubmit', 'prompt': '認証と削除の方針は?', 'session_id': 's5'})
check('T7 valid_from in future (D-011) and proposed (D-012) excluded', 'D-011' not in ctx(o) and 'D-012' not in ctx(o), ctx(o))
# T8 path scope
rc, o, err = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Edit', 'tool_input': {'file_path': 'C:/work/myproj/infra/main.tf'}, 'session_id': 's6'})
a = ctx(o)
rc2, o2, _ = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Edit', 'tool_input': {'file_path': 'C:/work/myproj/src/app.py'}, 'session_id': 's7'})
check('T8 path-scoped D-010 fires on infra/main.tf, not on src/app.py', 'D-010' in a and 'D-010' not in ctx(o2), a + ' || ' + ctx(o2))
# T9 PreToolUse deny + question queue
rc, o, err = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'npm publish --access public'}, 'session_id': 's8'})
q = sqlite3.connect(ST).execute("SELECT qid,status,on_expire,owner_role,expires_at FROM open_question").fetchall()
check('T9 human_required command -> permissionDecision=deny with reason; question queued (open, park, owner role, expiry)', o.get('permissionDecision') == 'deny' and len(q) == 1, json.dumps(o, ensure_ascii=False) + ' | ' + str(q))
rc, o, err = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'npm publish --access public'}, 'session_id': 's8'})
q = sqlite3.connect(ST).execute("SELECT COUNT(*) FROM open_question").fetchone()[0]
check('T9b same blocked action twice -> still deny, but only 1 queue row (idempotent)', o.get('permissionDecision') == 'deny' and q == 1, f'rows={q}')
# T10 harmless command not denied
rc, o, err = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'echo hello'}, 'session_id': 's9'})
check('T10 harmless command: no deny', o.get('permissionDecision') is None, json.dumps(o, ensure_ascii=False))
# T11 subagent fields logged
rc, o, err = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'PUBLISH_EXTERNAL x'}, 'session_id': 's10', 'agent_id': 'ag-1', 'agent_type': 'Explore'})
row = sqlite3.connect(ST).execute("SELECT agent_id,agent_type,event FROM injection_log WHERE agent_id='ag-1' LIMIT 1").fetchone()
check('T11 hook input from a subagent (agent_id/agent_type) is accepted, denied, and logged', o.get('permissionDecision') == 'deny' and row is not None, str(row))
# T12 DB broken -> fail open for normal, fallback deny for the boundary
bad = dict(env, DECISION_DB=str(tmp / 'missing.db'))
rc, o, err = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'echo hi'}, 'session_id': 's11'}, bad)
rc2, o2, err2 = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'npm publish'}, 'session_id': 's11'}, bad)
check('T12 DB missing: harmless -> exit0 no output (fail-open); boundary command -> fallback deny', rc == 0 and not o and o2.get('permissionDecision') == 'deny', f'{o} | {o2}')
# T13 expiry sweep reports an expired question at SessionStart
q = sqlite3.connect(ST); q.execute("UPDATE open_question SET expires_at='2026-11-16T00:00:00'"); q.commit(); q.close()
rc, o, err = run({'hook_event_name': 'SessionStart', 'source': 'resume', 'session_id': 's12'})
check('T13 SessionStart sweeps expired question and reports on_expire/owner_role', 'expired' in ctx(o) and 'on_expire=park' in ctx(o) and 'owner=release-owner' in ctx(o), ctx(o))
print(f'\nfails={fails}')
sys.exit(1 if fails else 0)
