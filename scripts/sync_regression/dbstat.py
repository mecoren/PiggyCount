# -*- coding: utf-8 -*-
"""对一个拉回来的 piggycount.sqlite 做结构概览（账本/交易/各类实体分布）。"""
import sqlite3
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

path = sys.argv[1]
con = sqlite3.connect(path)
cur = con.cursor()

print("=" * 70)
print("库:", path)
print("=" * 70)
tabs = [r[0] for r in cur.execute(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
print(f"表数={len(tabs)}")
for t in tabs:
    try:
        n = cur.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
    except Exception as e:
        n = f"ERR {e}"
    print(f"  {t:34s} {n}")

print("\n-- 账本 / 交易分布 --")
try:
    rows = cur.execute("""
        SELECT l.id, l.name, COUNT(t.id) AS n,
               MIN(datetime(t.happened_at,'unixepoch','localtime')),
               MAX(datetime(t.happened_at,'unixepoch','localtime'))
        FROM ledgers l LEFT JOIN transactions t ON t.ledger_id=l.id
        GROUP BY l.id, l.name ORDER BY l.id""").fetchall()
    tot = 0
    for lid, name, n, lo, hi in rows:
        tot += n
        print(f"  [{lid}] {name:22s} tx={n:<7d} {lo} ~ {hi}")
    print(f"  合计 tx={tot}")
except Exception as e:
    print("  ERR", e)
con.close()
