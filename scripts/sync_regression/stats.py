# -*- coding: utf-8 -*-
"""从快照库提取报告用的数据样本统计（只读）。"""
import os
import sqlite3
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()


def run(db, label):
    c = sqlite3.connect(db)
    out = [f"===== {label} （{os.path.basename(db)}）====="]

    out.append("\n[每账本规格]")
    out.append(f"{'id':<3} {'名称':<16} {'sync_id':<38} {'交易数':>6} {'最早日期':<12} {'最晚日期':<12}")
    for lid, name, sid, n, mn, mx in c.execute("""
            SELECT l.id, l.name, l.sync_id, COUNT(t.id),
                   MIN(date(t.happened_at,'unixepoch','localtime')),
                   MAX(date(t.happened_at,'unixepoch','localtime'))
            FROM ledgers l LEFT JOIN transactions t ON t.ledger_id=l.id
            GROUP BY l.id ORDER BY l.id"""):
        out.append(f"{lid:<3} {name:<16} {sid:<38} {n:>6} {str(mn):<12} {str(mx):<12}")

    out.append("\n[全库按年分布]")
    for y, n in c.execute("""SELECT strftime('%Y', happened_at,'unixepoch','localtime') y,
                                    COUNT(*) FROM transactions GROUP BY y ORDER BY y"""):
        out.append(f"  {y}: {n}")

    out.append("\n[交易类型分布]")
    tot = c.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    for t, n in c.execute("SELECT type, COUNT(*) FROM transactions GROUP BY type ORDER BY 2 DESC"):
        out.append(f"  {t:<12} {n:>6}  ({n*100.0/tot:.1f}%)")

    out.append("\n[微信/支付宝 笔数（口径②=账户维度全部交易含 transfer/adjustment）]")
    for atype in ("wechat", "alipay"):
        n = c.execute("""SELECT COUNT(*) FROM transactions t JOIN accounts a ON t.account_id=a.id
                         WHERE a.type=?""", (atype,)).fetchone()[0]
        n3 = c.execute("""SELECT COUNT(*) FROM transactions t JOIN accounts a ON t.account_id=a.id
                          WHERE a.type=? AND t.type IN ('expense','income')""", (atype,)).fetchone()[0]
        out.append(f"  {atype:<8} ②={n:>6}   ③(仅 expense/income)={n3:>6}")

    out.append("\n[附件]")
    rows = c.execute("""SELECT t.ledger_id, a.file_name, a.original_name, a.file_size,
                               a.local_sha256
                        FROM transaction_attachments a
                        JOIN transactions t ON a.transaction_id = t.id
                        ORDER BY t.ledger_id, a.file_name""").fetchall()
    out.append(f"  行数={len(rows)}  distinct file_name={len({r[1] for r in rows})}"
               f"  distinct sha={len({r[4] for r in rows})}")
    for r in rows:
        out.append(f"    ledger={r[0]} {r[1]}  {r[2]}  {r[3]}B  sha={str(r[4])[:16]}…")

    out.append("\n[其它实体计数]")
    for tbl in ("accounts", "categories", "tags", "transaction_tags", "budgets",
                "recurring_transactions", "exchange_rate_overrides", "local_changes"):
        n = c.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
        out.append(f"  {tbl:<26} {n}")
    c.close()
    return "\n".join(out)


if __name__ == "__main__":
    argv = sys.argv[1:]
    pairs = []
    if "--db" in argv:
        # 支持多组: --db a.sqlite --label 标签 --db b.sqlite --label 标签2
        cur_db = cur_label = None
        for i, a in enumerate(argv):
            if a == "--db":
                if cur_db:
                    pairs.append((cur_db, cur_label or cur_db))
                cur_db = argv[i + 1]
                cur_label = None
            elif a == "--label":
                cur_label = argv[i + 1]
        if cur_db:
            pairs.append((cur_db, cur_label or cur_db))
    else:
        # 无参兜底：扫运行目录里所有 *R1_A.sqlite 作为基线
        import glob as _glob
        for p in sorted(_glob.glob(os.path.join(RD, "*R1_A.sqlite"))):
            pairs.append((os.path.basename(p), os.path.basename(p)))
    txt = []
    for f, lab in pairs:
        p = f if os.path.isabs(f) else os.path.join(RD, f)
        if os.path.exists(p):
            txt.append(run(p, lab))
            txt.append("")
        else:
            print(f"  [跳过] 缺快照 {p}")
    s = "\n".join(txt)
    with open(os.path.join(RD, "data_sample.txt"), "w", encoding="utf-8", newline="") as fh:
        fh.write(s)
    print(s)
