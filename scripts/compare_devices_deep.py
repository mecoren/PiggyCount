# -*- coding: utf-8 -*-
"""
深度对比两台设备的 PiggyCount 库:
  A) S3/WebDAV 同步范围数据 —— 按 sync_id 对齐逐行比内容(本地 int id 不比,
     ledger/category/account 引用统一换算成 sync_id 再比)
  B) 非同步范围数据 —— 行数 + 摘要(两侧本就允许不同,只罗列)
  C) 附件物理文件由调用方用 adb 单独比对

运行: python scripts/compare_devices_deep.py <a.sqlite> <b.sqlite>
"""
import sqlite3
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SYNC_TABLES = ["ledgers", "accounts", "categories", "tags", "transactions",
               "budgets", "recurring_transactions", "exchange_rate_overrides"]
NONSYNC_TABLES = ["local_changes", "ledger_members", "shared_ledger_categories",
                  "shared_ledger_accounts", "shared_ledger_tags", "transaction_tag_overrides",
                  "conversations", "exchange_rates", "sync_pull_errors",
                  "entity_change_watermarks", "transaction_attachments", "transaction_tags"]


def cols(cur, t):
    cur.execute(f"PRAGMA table_info({t})")
    return [r[1] for r in cur.fetchall()]


def load_sync_rows(cur, t):
    """返回 {sync_id: {业务列: 值}}, 引用列换算成 sync_id。"""
    c = set(cols(cur, t))
    sel, renames = [], {}

    def ref(col, target_table):
        """把 int 引用列换成对应表 sync_id"""
        if col not in c:
            return
        cur.execute(f"""
            CREATE TEMP VIEW _v AS
            SELECT x.rowid, y.sync_id AS _ref
            FROM {t} x LEFT JOIN {target_table} y ON x.{col}=y.id""")
        cur.execute("DROP VIEW _v")
        renames[col] = f"{col}->{target_table}.sync_id"
        sel.append(f"(SELECT y.sync_id FROM {target_table} y WHERE y.id = x.{col}) AS {col}__ref")

    base_cols = []
    for col in c:
        if col in ("id", "sync_id"):
            continue
        base_cols.append(f"x.{col}")
    ref_sql = ""
    if t == "accounts":
        ref_sql = ", (SELECT y.sync_id FROM ledgers y WHERE y.id=x.ledger_id) AS ledger_id__ref"
        base_cols = [b for b in base_cols if b != "x.ledger_id"]
    elif t == "transactions":
        parts = []
        for col, tt in [("ledger_id", "ledgers"), ("category_id", "categories"),
                        ("account_id", "accounts"), ("to_account_id", "accounts"),
                        ("recurring_id", "recurring_transactions")]:
            if col in c:
                parts.append(f"(SELECT y.sync_id FROM {tt} y WHERE y.id=x.{col}) AS {col}__ref")
        ref_sql = ", " + ", ".join(parts)
        base_cols = [b for b in base_cols if b.split(".")[-1] not in
                     ("ledger_id", "category_id", "account_id", "to_account_id", "recurring_id")]
    elif t == "categories":
        if "parent_id" in c:
            ref_sql = ", (SELECT y.sync_id FROM categories y WHERE y.id=x.parent_id) AS parent_id__ref"
            base_cols = [b for b in base_cols if b != "x.parent_id"]
    elif t == "budgets":
        parts = []
        for col, tt in [("ledger_id", "ledgers"), ("category_id", "categories")]:
            if col in c:
                parts.append(f"(SELECT y.sync_id FROM {tt} y WHERE y.id=x.{col}) AS {col}__ref")
        ref_sql = ", " + ", ".join(parts)
        base_cols = [b for b in base_cols if b.split(".")[-1] not in ("ledger_id", "category_id")]
    elif t == "recurring_transactions":
        parts = []
        for col, tt in [("ledger_id", "ledgers"), ("category_id", "categories"),
                        ("account_id", "accounts"), ("to_account_id", "accounts")]:
            if col in c:
                parts.append(f"(SELECT y.sync_id FROM {tt} y WHERE y.id=x.{col}) AS {col}__ref")
        ref_sql = ", " + ", ".join(parts)
        base_cols = [b for b in base_cols if b.split(".")[-1] not in
                     ("ledger_id", "category_id", "account_id", "to_account_id")]
    cur.execute(f"SELECT x.sync_id, {', '.join(base_cols)}{ref_sql} FROM {t} x")
    names = [d[0] for d in cur.description]
    out = {}
    for row in cur.fetchall():
        d = {}
        for n, v in zip(names, row):
            if n == "sync_id":
                continue
            d[n] = v
        out[row[0]] = d
    return out


def diff_content(ra, rb, label, max_show=5):
    """ra, rb: {sync_id: {col: val}}; 返回不一致的 sync_id 列表并打印样本"""
    bad = []
    for sid in sorted(set(ra) & set(rb)):
        da, db = ra[sid], rb[sid]
        diffs = []
        for k in sorted(set(da) | set(db)):
            va, vb = da.get(k), db.get(k)
            # float 容差
            if isinstance(va, float) or isinstance(vb, float):
                try:
                    if va is not None and vb is not None and abs(float(va) - float(vb)) < 1e-6:
                        continue
                except (TypeError, ValueError):
                    pass
            if va != vb:
                diffs.append((k, va, vb))
        if diffs:
            bad.append((sid, diffs))
    if bad:
        print(f"    [!!] {label}: 内容不一致 {len(bad)} 行, 样本:")
        for sid, diffs in bad[:max_show]:
            for k, va, vb in diffs[:3]:
                sa = str(va)[:40] if va is not None else "NULL"
                sb = str(vb)[:40] if vb is not None else "NULL"
                print(f"      {sid[:8]}.. {k}: A={sa!r} B={sb!r}")
    return len(bad)


def main():
    if len(sys.argv) != 3:
        print("usage: compare_devices_deep.py <a.sqlite> <b.sqlite>")
        sys.exit(1)
    ca = sqlite3.connect(sys.argv[1])
    cb = sqlite3.connect(sys.argv[2])
    cur_a, cur_b = ca.cursor(), cb.cursor()
    print("=" * 72)
    print("A) S3/WebDAV 同步范围数据 (按 sync_id 对齐 + 内容逐列比对)")
    print("=" * 72)
    total_bad = 0
    for t in SYNC_TABLES:
        ra = load_sync_rows(cur_a, t)
        rb = load_sync_rows(cur_b, t)
        only_a = set(ra) - set(rb)
        only_b = set(rb) - set(ra)
        nbad = diff_content(ra, rb, t)
        total_bad += nbad + len(only_a) + len(only_b)
        mark = "OK " if (not only_a and not only_b and not nbad) else "!! "
        print(f"[{mark}] {t:26s} A={len(ra):<5d} B={len(rb):<5d} 仅A={len(only_a)} 仅B={len(only_b)} 内容不一致={nbad}")
        if only_a:
            print(f"       仅A(前5): {sorted(only_a)[:5]}")
        if only_b:
            print(f"       仅B(前5): {sorted(only_b)[:5]}")

    # 交易按账本分布(用账本名)
    print("\n-- transactions 按账本分布 --")
    for label, cur in (("A", cur_a), ("B", cur_b)):
        cur.execute("""SELECT l.name, COUNT(*) FROM transactions t
                       JOIN ledgers l ON t.ledger_id=l.id GROUP BY l.name ORDER BY l.name""")
        print(f"  {label}: {dict(cur.fetchall())}")
    # 金额汇总
    for label, cur in (("A", cur_a), ("B", cur_b)):
        cur.execute("""SELECT l.name, ROUND(SUM(CASE WHEN t.type='expense' THEN t.native_amount ELSE 0 END),2),
                       ROUND(SUM(CASE WHEN t.type='income' THEN t.native_amount ELSE 0 END),2)
                       FROM transactions t JOIN ledgers l ON t.ledger_id=l.id GROUP BY l.name ORDER BY l.name""")
        print(f"  {label} 支出/收入(native): {cur.fetchall()}")

    print()
    print("=" * 72)
    print("B) 非同步范围数据 (行数罗列; 两侧允许不同)")
    print("=" * 72)
    for t in NONSYNC_TABLES:
        ea = t in [r[0] for r in cur_a.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
        eb = t in [r[0] for r in cur_b.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
        na = cur_a.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] if ea else "表不存在"
        nb = cur_b.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] if eb else "表不存在"
        mark = "OK " if na == nb else "-- "
        print(f"[{mark}] {t:28s} A={na} B={nb}")

    # local_changes 摘要
    print("\n-- local_changes 按 entity_type 分布 --")
    for label, cur in (("A", cur_a), ("B", cur_b)):
        try:
            cur.execute("SELECT entity_type, COUNT(*), SUM(CASE WHEN pushed_at IS NULL THEN 1 ELSE 0 END) "
                        "FROM local_changes GROUP BY entity_type ORDER BY entity_type")
            print(f"  {label} (type, 总数, 未推送): {cur.fetchall()}")
        except Exception as e:
            print(f"  {label}: ERR {e}")

    # 附件行(按 sha 对齐)
    print("\n-- transaction_attachments 按 local_sha256 对齐 --")
    cur_a.execute("SELECT a.local_sha256, l.name, a.file_name FROM transaction_attachments a "
                  "JOIN transactions t ON a.transaction_id=t.id JOIN ledgers l ON t.ledger_id=l.id")
    aa = {r[0]: (r[1], r[2]) for r in cur_a.fetchall()}
    cur_b.execute("SELECT a.local_sha256, l.name, a.file_name FROM transaction_attachments a "
                  "JOIN transactions t ON a.transaction_id=t.id JOIN ledgers l ON t.ledger_id=l.id")
    ab = {r[0]: (r[1], r[2]) for r in cur_b.fetchall()}
    print(f"  A: {len(aa)} 行  B: {len(ab)} 行")
    for sha in sorted(set(aa) | set(ab)):
        ma, mb = aa.get(sha), ab.get(sha)
        mark = "OK " if ma and mb and ma[0] == mb[0] else "!! "
        print(f"  [{mark}] {sha[:12]}.. A={ma} B={mb}")

    # 标签链接(按 sync 对齐)
    print("\n-- transaction_tags (tx.sync_id + tag.sync_id 对齐) --")
    def tag_pairs(cur):
        cur.execute("""SELECT x.sync_id, y.sync_id FROM transaction_tags tt
                       JOIN transactions x ON tt.transaction_id=x.id
                       JOIN tags y ON tt.tag_id=y.id""")
        return {(r[0], r[1]) for r in cur.fetchall()}
    pa, pb = tag_pairs(cur_a), tag_pairs(cur_b)
    print(f"  A={len(pa)} B={len(pb)} 仅A={len(pa-pb)} 仅B={len(pb-pa)}")

    print()
    print("=== 同步范围结论:", "一致 ✅" if total_bad == 0 else f"存在 {total_bad} 处不一致 ❌", "===")
    ca.close()
    cb.close()
    sys.exit(0 if total_bad == 0 else 1)


if __name__ == "__main__":
    main()
