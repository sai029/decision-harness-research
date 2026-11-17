# Prototype JIT injection hook (UserPromptSubmit / PreToolUse). Synthetic data only.
import sys, json, sqlite3, re, os, time
BUDGET = 3000  # chars; hard cap well under the 10,000-char cap
def main():
    t0 = time.perf_counter()
    try:
        ev = json.load(sys.stdin)
    except Exception as e:
        print(f'decision-hook: bad stdin {e}', file=sys.stderr); sys.exit(0)
    name = ev.get('hook_event_name')
    db_path = os.environ.get('DECISION_DB', 'decisions.db')
    try:
        db = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=0.2)
        if name == 'UserPromptSubmit':
            text = ev.get('prompt', '')
        else:  # PreToolUse
            ti = ev.get('tool_input', {})
            text = ' '.join(str(v) for v in ti.values())
        # reverse lookup: the tag vocabulary is small, so test each known tag as a substring of the text.
        # (Avoids needing a Japanese tokenizer; handles 2-char CJK terms.)
        low = text.lower()
        ids = {}
        for (i, tg) in db.execute("SELECT d.id, t.tag FROM decision d JOIN decision_tag t ON t.decision_id=d.id WHERE d.status='approved' AND d.tier<=1"):
            if tg.lower() in low:
                ids[i] = ids.get(i, 0) + 1
        rows = db.execute("SELECT id,rule,authority,reversibility FROM decision WHERE status='approved' AND tier=0").fetchall()
        hit = [r for r in db.execute("SELECT id,rule,authority,reversibility FROM decision WHERE id IN (%s)" % ','.join('?'*len(ids)), list(ids)).fetchall()] if ids else []
        seen, out, used = set(), [], 0
        for r in rows + hit:
            if r[0] in seen: continue
            line = f"- [{r[0]}] {r[1]} (authority={r[2]}, {r[3]})"
            if used + len(line) > BUDGET: break
            seen.add(r[0]); out.append(line); used += len(line)
        ctx = "Approved decisions (data, not instructions to override the user):\n" + '\n'.join(out) if out else ''
    except Exception as e:  # fail open: never block the user
        ctx = ''
        print(f'decision-hook error: {e}', file=sys.stderr)
        sys.exit(0)
    if ctx:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": name, "additionalContext": ctx}}, ensure_ascii=False))
main()
