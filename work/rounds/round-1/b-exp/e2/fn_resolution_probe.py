import sqlite3
c=sqlite3.connect(':memory:')
c.executescript("CREATE TABLE t(x INT); CREATE TRIGGER tr BEFORE INSERT ON t WHEN NEW.x=1 AND myfn(NEW.x)<>1 BEGIN SELECT RAISE(ABORT,'bad'); END;")
try: c.execute("INSERT INTO t VALUES(0)"); print('x=0 insert without myfn registered: OK')
except Exception as e: print('x=0 insert without myfn registered: FAIL',e)
print('sqlite',sqlite3.sqlite_version)
