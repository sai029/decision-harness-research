# Load work/ddl/unified_schema.sql and check D's required columns/tables/enum values. Read-only on the DDL.
import sqlite3, pathlib, sys
sys.stdout.reconfigure(encoding='utf-8')
ddl = pathlib.Path(__file__).resolve().parents[3] / 'ddl' / 'unified_schema.sql'
con = sqlite3.connect(':memory:')
try:
    con.executescript(ddl.read_text(encoding='utf-8')); print('unified_schema.sql loads: OK')
except Exception as e:
    print('unified_schema.sql load error:', e)   # e.g. needs app-defined functions; still inspect what was created
def cols(t): return {r[1] for r in con.execute(f'PRAGMA table_info({t})')}
need = {  # table: (required columns, why)
 'decision': ({'status','tier','reversibility','scope_project','scope_path','valid_from','valid_until','class_code','agent_mode'}, 'eligibility + tier + scope + expiry'),
 'decision_tag': ({'tag','not_followed_by'}, 'compound-word guard (E4 false fire)'),
 'decision_trigger': ({'kind','pattern','action'}, 'enforcement: inject|ask|deny'),
 'injection_log': ({'session_id','agent_id','agent_type','event','decision_id','chars'}, 'subagent attribution + dedupe'),
 'review_queue': ({'question','raised_by','assignee_role','expires_at','on_expire','state'}, 'single question queue'),
}
miss = 0
for t, (c, why) in need.items():
    have = cols(t)
    m = sorted(c - have)
    print(f"{t:18s} {'OK     ' if not m else 'MISSING'} {m if m else ''}  ({why})")
    miss += len(m)
print('missing columns total:', miss)
