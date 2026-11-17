import json, sqlite3, sys
sys.stdout.reconfigure(encoding="utf-8")
print("== stream: tool calls / results / final (claude -p, model from init) ==")
for l in open('e7_stream.jsonl', encoding='utf-8'):
    d = json.loads(l); t = d.get('type')
    if t == 'system' and d.get('subtype') == 'init': print('model:', d.get('model'))
    if t == 'assistant':
        for b in d['message']['content']:
            if b['type'] == 'tool_use': print('TOOL_USE', b['name'], json.dumps(b['input'], ensure_ascii=False)[:160])
    elif t == 'user':
        for b in d['message']['content']:
            if isinstance(b, dict) and b.get('type') == 'tool_result': print('RESULT is_error=%s' % b.get('is_error'), str(b.get('content'))[:260].replace('\n', ' '))
    elif t == 'result': print('FINAL', d.get('result', '')[:700])
print("== hook.log (hook invoked per tool call) ==")
for l in open('e7-proj/hook.log', encoding='utf-8'): print(l[:170].strip())
print("== review_queue / ai_decision (written by the hook via the agent connection) ==")
c = sqlite3.connect('e7-proj/decisions.db')
for r in c.execute("select queue_id,state,assignee_role,on_expire,question from review_queue"): print(r)
print("ai_decision actions:", c.execute("select action from ai_decision").fetchall())
