#!/usr/bin/env python3
"""对比两个 PiggyCount live sqlite 的云同步表数据是否一致。

检查 8 张参与云同步的表：
  transactions, accounts, categories, ledgers,
  budgets, tags, recurring_transactions, exchange_rate_overrides

对每个表输出：
  - 行数
  - distinct sync_id 数量
  - 两张库 sync_id 集合的差异（仅在一侧出现的）
并对 transactions / accounts 做按 ledger 的分布统计。
"""
import sqlite3
import sys

SYNCED_TABLES = [
    "transactions", "accounts", "categories", "ledgers",
    "budgets", "tags", "recurring_transactions", "exchange_rate_overrides",
]


def table_exists(cur, name):
    cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (name,))
    return cur.fetchone() is not None


def sync_id_set(cur, table):
    # 兼容无 sync_id 列的表
    cur.execute(f"PRAGMA table_info({table})")
    cols = {r[1] for r in cur.fetchall()}
    if "sync_id" not in cols:
        return None
    cur.execute(f"SELECT sync_id FROM {table}")
    return {r[0] for r in cur.fetchall() if r[0] is not None}


def main():
    if len(sys.argv) != 3:
        print("usage: compare_two_dbs.py <dbA.sqlite> <dbB.sqlite>")
        sys.exit(1)
    a, b = sys.argv[1], sys.argv[2]
    ca = sqlite3.connect(a)
    cb = sqlite3.connect(b)
    cur_a = ca.cursor()
    cur_b = cb.cursor()

    print(f"A = {a}")
    print(f"B = {b}\n")

    all_ok = True
    for t in SYNCED_TABLES:
        if not table_exists(cur_a, t) or not table_exists(cur_b, t):
            print(f"[MISSING] 表 {t} 在某侧不存在")
            all_ok = False
            continue
        cur_a.execute(f"SELECT COUNT(*) FROM {t}")
        na = cur_a.fetchone()[0]
        cur_b.execute(f"SELECT COUNT(*) FROM {t}")
        nb = cur_b.fetchone()[0]

        sa = sync_id_set(cur_a, t)
        sb = sync_id_set(cur_b, t)
        if sa is None:
            only_a = only_b = set()
            ndiff = "n/a (无 sync_id)"
        else:
            only_a = sa - sb
            only_b = sb - sa
            ndiff = f"仅A={len(only_a)} 仅B={len(only_b)}"

        mark = "OK " if (na == nb and (sa is None or (not only_a and not only_b))) else "!! "
        if mark == "!! ":
            all_ok = False
        print(f"[{mark}] {t:24s} A={na:<6d} B={nb:<6d} {ndiff}")
        if only_a:
            print(f"       仅A的 sync_id (前10): {sorted(str(x) for x in only_a)[:10]}")
        if only_b:
            print(f"       仅B的 sync_id (前10): {sorted(str(x) for x in only_b)[:10]}")

    # 按 ledger 分布
    print("\n--- transactions 按 ledger_id 分布 ---")
    cur_a.execute("SELECT ledger_id, COUNT(*) FROM transactions GROUP BY ledger_id ORDER BY ledger_id")
    da = dict(cur_a.fetchall())
    cur_b.execute("SELECT ledger_id, COUNT(*) FROM transactions GROUP BY ledger_id ORDER BY ledger_id")
    db = dict(cur_b.fetchall())
    all_lids = sorted(set(da) | set(db))
    for lid in all_lids:
        na = da.get(lid, 0)
        nb = db.get(lid, 0)
        mark = "OK " if na == nb else "!! "
        if mark == "!! ":
            all_ok = False
        print(f"[{mark}] ledger_id={lid:<3d} A={na:<6d} B={nb:<6d}")

    print("\n--- accounts 行数 & 是否全球化(ledger_id=0) ---")
    cur_a.execute("SELECT COUNT(*), SUM(CASE WHEN ledger_id=0 THEN 1 ELSE 0 END) FROM accounts")
    ra = cur_a.fetchone()
    cur_b.execute("SELECT COUNT(*), SUM(CASE WHEN ledger_id=0 THEN 1 ELSE 0 END) FROM accounts")
    rb = cur_b.fetchone()
    print(f"  A: total={ra[0]} globalized={ra[1]}")
    print(f"  B: total={rb[0]} globalized={rb[1]}")

    print("\n--- ledgers 列表 ---")
    cur_a.execute("SELECT id, name, sync_id FROM ledgers ORDER BY id")
    la = cur_a.fetchall()
    cur_b.execute("SELECT id, name, sync_id FROM ledgers ORDER BY id")
    lb = cur_b.fetchall()
    for r in la:
        print(f"  A: id={r[0]} name={r[1]!r} sync_id={r[2]}")
    for r in lb:
        print(f"  B: id={r[0]} name={r[1]!r} sync_id={r[2]}")

    print("\n=== 结论:", "两侧完全一致 ✅" if all_ok else "存在不一致 ❌", "===")
    ca.close()
    cb.close()
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
