# Summarize a claude -p stream-json log: hook events, tool calls, tool results, final result.
import json, sys
sys.stdout.reconfigure(encoding='utf-8')
for l in open(sys.argv[1], encoding='utf-8'):
    o = json.loads(l); t = o.get('type'); s = o.get('subtype')
    if t == 'system' and s in ('hook_started', 'hook_response'):
        if s == 'hook_response': print('HOOK', o.get('hook_event'), 'exit', o.get('exit_code'), o.get('outcome'), '|', str(o.get('output') or '')[:420].replace('\n', ' / '))
    elif t == 'assistant':
        for c in o['message']['content']:
            if c['type'] == 'text': print('ASSISTANT:', c['text'][:400].replace('\n', ' / '))
            elif c['type'] == 'tool_use': print('TOOL_USE:', c['name'], json.dumps(c['input'], ensure_ascii=False)[:160])
    elif t == 'user':
        for c in o['message']['content']:
            if isinstance(c, dict) and c.get('type') == 'tool_result': print('TOOL_RESULT(is_error=%s):' % c.get('is_error'), str(c.get('content'))[:420].replace('\n', ' / '))
    elif t == 'result': print('FINAL:', str(o.get('result'))[:400], '| turns', o.get('num_turns'), '| cost', o.get('total_cost_usd'))
