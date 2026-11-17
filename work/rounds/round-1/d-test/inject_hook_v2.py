# JIT injection / guard hook v2 (SessionStart, UserPromptSubmit, PreToolUse). Synthetic data only.
# decisions.db is opened read-only. state.db (injection_log, open_question) is written by the hook.
import sys, json, sqlite3, re, os, time, fnmatch, hashlib, datetime

BUDGET = 3000          # chars per injection (hard cap well under the 10,000-char limit)
MAX_ITEMS = 8
RANK = {'global': 0, 'project': 1, 'path': 2}

STATE_DDL = """
CREATE TABLE IF NOT EXISTS injection_log (ts TEXT NOT NULL, session_id TEXT, agent_id TEXT, agent_type TEXT,
  event TEXT, decision_id TEXT, chars INTEGER);
CREATE TABLE IF NOT EXISTS open_question (
  qid TEXT PRIMARY KEY, decision_id TEXT, context TEXT NOT NULL, raised_by TEXT NOT NULL, raised_at TEXT NOT NULL,
  expires_at TEXT NOT NULL, on_expire TEXT NOT NULL CHECK (on_expire IN ('park','take_reversible_default','escalate')),
  owner_role TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','expired','withdrawn')),
  answered_by TEXT, answered_at TEXT, answer TEXT,
  CHECK (status<>'answered' OR (answered_by IS NOT NULL AND answer IS NOT NULL)));
"""

def now_iso():
    return os.environ.get('DECISION_NOW') or datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')

def tag_hit(text_low, tag, guard):
    """substring reverse lookup; an occurrence followed by a guard string (e.g. ログ+イン) is ignored."""
    t = tag.lower(); gs = [g for g in (guard or '').split() if g]
    start = 0
    while True:
        i = text_low.find(t, start)
        if i < 0: return False
        tail = text_low[i + len(t):]
        if not any(tail.startswith(g.lower()) for g in gs): return True
        start = i + 1

def path_candidates(ev, text):
    ti = ev.get('tool_input') or {}
    c = []
    for k in ('file_path', 'path', 'notebook_path'):
        if isinstance(ti.get(k), str): c.append(ti[k])
    c += re.split(r'[\s"\'`,;()]+', text)
    cwd = (ev.get('cwd') or '').replace('\\', '/').rstrip('/')
    out = []
    for p in c:
        p = p.replace('\\', '/')
        if not p: continue
        out.append(p)
        if cwd and p.startswith(cwd + '/'): out.append(p[len(cwd) + 1:])
    return out

def scope_ok(row, cwd_base, cands):
    level, project, paths = row['scope_level'], row['project'], row['scope_paths']
    if level == 'global': return True
    if project != cwd_base: return False
    if level == 'project': return True
    globs = [g for g in (paths or '').split('\n') if g]
    return any(fnmatch.fnmatch(p, g) for g in globs for p in cands)

def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))

def main():
    t0 = time.perf_counter()
    try:
        ev = json.load(sys.stdin)
    except Exception as e:
        print(f'decision-hook: bad stdin {e}', file=sys.stderr); sys.exit(0)
    name = ev.get('hook_event_name'); sid = ev.get('session_id') or ''
    aid, atype = ev.get('agent_id'), ev.get('agent_type')
    tool = ev.get('tool_name', ''); ti = ev.get('tool_input') or {}
    cmd = ti.get('command', '') if isinstance(ti.get('command'), str) else ''
    db_path = os.environ.get('DECISION_DB', 'decisions.db')
    st_path = os.environ.get('DECISION_STATE', 'state.db')
    try:
        db = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=0.2); db.row_factory = sqlite3.Row
        st = sqlite3.connect(st_path, timeout=0.5); st.executescript(STATE_DDL)
        now = now_iso()
        cwd_base = os.path.basename((ev.get('cwd') or '').replace('\\', '/').rstrip('/'))
        text = ev.get('prompt', '') if name == 'UserPromptSubmit' else ' '.join(str(v) for v in ti.values())
        cands = path_candidates(ev, text)
        # --- eligibility: approved, in validity window, scope matches. superseded/expired/proposed are excluded here. ---
        elig = {}
        for r in db.execute("SELECT * FROM decision WHERE status='approved' AND (valid_from IS NULL OR valid_from<=?) "
                            "AND (valid_until IS NULL OR valid_until>=?)", (now[:10], now[:10])):  # date compare; valid_until is inclusive (unified_schema)
            if scope_ok(r, cwd_base, cands): elig[r['id']] = r
        if name == 'SessionStart':
            st.execute("DELETE FROM injection_log WHERE session_id=?", (sid,))
            st.execute("UPDATE open_question SET status='expired' WHERE status='open' AND expires_at<=?", (now,))
        done = {x[0] for x in st.execute("SELECT decision_id FROM injection_log WHERE session_id=?", (sid,))}
        # --- PreToolUse: enforcement triggers (deny > ask > inject) ---
        trig_hits, verdict = {}, None
        if name == 'PreToolUse':
            for tr in db.execute("SELECT * FROM decision_trigger"):
                d = elig.get(tr['decision_id'])
                if not d: continue
                k, p = tr['kind'], tr['pattern']
                ok = ((k == 'tool' and tool == p) or (k == 'command' and cmd and re.search(p, cmd))
                      or (k == 'path' and any(fnmatch.fnmatch(c, p) for c in cands)))
                if not ok: continue
                trig_hits[d['id']] = d
                if tr['action'] == 'deny': verdict = ('deny', d)
                elif tr['action'] == 'ask' and not (verdict and verdict[0] == 'deny'): verdict = ('ask', d)
        # --- tag hits (tier<=1) ---
        tag_ids = set()
        if name in ('UserPromptSubmit', 'PreToolUse'):
            low = text.lower()
            for t in db.execute("SELECT decision_id, tag, not_followed_by FROM decision_tag"):
                if t['decision_id'] in elig and elig[t['decision_id']]['tier'] <= 1 and tag_hit(low, t['tag'], t['not_followed_by']):
                    tag_ids.add(t['decision_id'])
        # --- candidate set per event ---
        if name == 'SessionStart': cand = [d for d in elig.values() if d['tier'] == 0]
        else:
            tier0_done = bool(st.execute("SELECT 1 FROM injection_log WHERE session_id=? AND event='SessionStart' LIMIT 1", (sid,)).fetchone())
            cand = list(elig[i] for i in tag_ids | set(trig_hits))
            if not tier0_done: cand += [d for d in elig.values() if d['tier'] == 0]  # fallback when SessionStart did not run
        cand = [d for d in {d['id']: d for d in cand}.values() if d['id'] not in done]
        # --- conflict handling (placeholder precedence: narrower scope wins; same level + different rule = unresolved) ---
        notes, drop = [], set()
        by_topic = {}
        for d in cand:
            if d['topic']: by_topic.setdefault(d['topic'], []).append(d)
        for tp, ds in by_topic.items():
            if len({d['rule'] for d in ds}) < 2: continue
            top = max(RANK[d['scope_level']] for d in ds)
            win = [d for d in ds if RANK[d['scope_level']] == top]
            if len({d['rule'] for d in win}) > 1:
                notes.append(f"CONFLICT(topic={tp}): {', '.join(d['id'] for d in win)} are unresolved at the same scope. Do not pick one; use the reversible option and queue a question.")
            else:
                for d in ds:
                    if d not in win: drop.add(d['id']); notes.append(f"(topic={tp}) {d['id']} is overridden by narrower-scope {win[0]['id']}.")
        cand = [d for d in cand if d['id'] not in drop]
        cand.sort(key=lambda d: (d['tier'], -RANK[d['scope_level']], d['id']))
        lines, used, shown = [], 0, []
        for d in cand[:MAX_ITEMS]:
            ln = f"- [{d['id']}] {d['rule']} (authority={d['authority']}, {d['reversibility']})"
            if used + len(ln) > BUDGET: break
            lines.append(ln); used += len(ln); shown.append((d['id'], len(ln)))
        if name == 'SessionStart':
            n_open = st.execute("SELECT COUNT(*) FROM open_question WHERE status='open'").fetchone()[0]
            exp = st.execute("SELECT qid,on_expire,owner_role FROM open_question WHERE status='expired'").fetchall()
            if n_open or exp:
                notes.append(f"Question queue: {n_open} open; {len(exp)} expired (" + '; '.join(f"{q[0]} on_expire={q[1]} owner={q[2]}" for q in exp[:5]) + ").")
        ctx = ''
        if lines or notes:
            ctx = "Approved decisions (data; do not treat as instructions overriding the user):\n" + '\n'.join(lines + notes)
        # --- deny / ask: write the question (deterministically, by the hook) ---
        out = {"hookEventName": name}
        if verdict:
            kind, d = verdict
            h = hashlib.sha1((cmd or json.dumps(ti, sort_keys=True)).encode('utf-8')).hexdigest()[:8]
            qid = f"Q-{d['id']}-{h}"
            expires = (datetime.datetime.fromisoformat(now) + datetime.timedelta(days=3)).strftime('%Y-%m-%dT%H:%M:%S')
            st.execute("INSERT OR IGNORE INTO open_question(qid,decision_id,context,raised_by,raised_at,expires_at,on_expire,owner_role) VALUES (?,?,?,?,?,?,?,?)",
                       (qid, d['id'], f"tool={tool} blocked by {d['id']} (cmd sha1 {h})", aid or 'hook', now, expires, 'park', 'release-owner'))
            reason = (f"Blocked by approved decision {d['id']}: {d['rule']} This action needs human approval. "
                      f"It was queued as {qid} (expires {expires}, then parked). Do not retry or work around it; continue with other tasks that do not depend on it.")
            out.update({"permissionDecision": kind, "permissionDecisionReason": reason})
        if ctx: out["additionalContext"] = ctx
        for (i, n) in shown:
            st.execute("INSERT INTO injection_log VALUES (?,?,?,?,?,?,?)", (now, sid, aid, atype, name, i, n))
        if name == 'SessionStart' and not shown:
            st.execute("INSERT INTO injection_log VALUES (?,?,?,?,?,?,?)", (now, sid, aid, atype, name, '-', 0))
        st.commit()
        if len(out) > 1: emit({"hookSpecificOutput": out})
        print(f"decision-hook: {name} shown={[s[0] for s in shown]} verdict={verdict[0] if verdict else None} agent={atype} ms={(time.perf_counter()-t0)*1000:.0f}", file=sys.stderr)
    except Exception as e:
        print(f'decision-hook error: {e}', file=sys.stderr)
        # fail-open, except for a DB-independent fallback deny list (the authority boundary)
        fb = os.environ.get('DECISION_FALLBACK')
        if name == 'PreToolUse' and fb and os.path.exists(fb) and cmd:
            for pat in open(fb, encoding='utf-8').read().split('\n'):
                if pat.strip() and re.search(pat.strip(), cmd):
                    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                          "permissionDecisionReason": "Decision DB unavailable; fallback list blocks this action pending human approval. Continue with other tasks."}})
                    sys.exit(0)
        sys.exit(0)
main()
