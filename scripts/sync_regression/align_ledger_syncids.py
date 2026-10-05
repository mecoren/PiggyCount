# -*- coding: utf-8 -*-
"""把「云端现有账本的 syncId 集合」与「注入后本地账本的 syncId」对齐。

背景：S3/WebDAV 是**文件式**后端，一个账本 = 一个 `ledger_<syncId>.json` 对象，
「全量上传」只覆盖同名对象、**不会删除云端独有账本**。若云端留着上一轮的 8 个
账本，而本轮又注入 8 个新账本（syncId 不同），云端就会变成 16 个账本，
B 端全量下载会把 16 个全导进来，一致性对比必然失败——而这不是同步 bug。

对策（不删除任何云端数据）：把本轮注入的 8 个账本的 sync_id 改写成云端现有的
那 8 个 syncId，上传即原地覆盖，云端账本数恒为 8。账本内容由「全量上传」整体
覆盖，所以名字/条数变化不影响覆盖语义。

用法:
  python align_ledger_syncids.py <seed.sqlite> --list          # 打印本地账本 syncId
  python align_ledger_syncids.py <seed.sqlite> --from <A.sqlite>  # 用 A 库的 syncId 改写
  python align_ledger_syncids.py <seed.sqlite> --syncids <file>  # 每行一个 syncId（云端对象名）
"""
import sqlite3
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def ledgers(path):
    con = sqlite3.connect(path)
    rows = con.execute(
        "SELECT id, name, sync_id FROM ledgers ORDER BY id").fetchall()
    con.close()
    return rows


def main():
    seed = sys.argv[1]
    rows = ledgers(seed)
    if "--list" in sys.argv:
        for lid, name, sid in rows:
            print(f"  id={lid:<3d} {name:24s} {sid}")
        return 0
    # --syncids：直接给云端对象名里的 syncId（S3/WebDAV 都适用，不必先造一个源库）
    if "--syncids" in sys.argv:
        path = sys.argv[sys.argv.index("--syncids") + 1]
        want = []
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            # 兼容 "ledger_<uuid>.json" 或裸 uuid
            want.append(line.split("ledger_")[-1].replace(".json", ""))
        if len(want) != len(rows):
            print(f"[FAIL] 云端账本数 {len(want)} != 本地账本数 {len(rows)}")
            return 1
        con = sqlite3.connect(seed)
        cur = con.cursor()
        print("  改写 ledger sync_id（按 id 顺序一一对应）:")
        for (lid, name, _), sid in zip(rows, want):
            cur.execute("UPDATE ledgers SET sync_id=? WHERE id=?", (sid, lid))
            cur.execute("UPDATE local_changes SET entity_sync_id=? "
                        "WHERE entity_type='ledger' AND entity_id=?", (sid, lid))
            print(f"    id={lid:<3d} {name:24s} <- {sid}")
        con.commit()
        n = con.execute("SELECT COUNT(DISTINCT sync_id) FROM ledgers").fetchone()[0]
        print(f"  改写完成，账本数={len(rows)}，distinct sync_id={n}")
        con.close()
        return 0 if n == len(rows) else 1
    if "--from" not in sys.argv:
        print(__doc__)
        return 1
    src = sys.argv[sys.argv.index("--from") + 1]
    src_rows = ledgers(src)
    if len(src_rows) != len(rows):
        print(f"[FAIL] 账本数不一致: seed={len(rows)} src={len(src_rows)}")
        return 1
    con = sqlite3.connect(seed)
    cur = con.cursor()
    print("  改写 ledger sync_id（按 id 顺序一一对应）:")
    for (lid, name, _sid), (slid, sname, ssid) in zip(rows, src_rows):
        cur.execute("UPDATE ledgers SET sync_id=? WHERE id=?", (ssid, lid))
        print(f"    id={lid:<3d} {name:24s} <- {ssid}")
    # local_changes 里登记的账本 syncId 也要跟着改，否则推送的是旧标识
    for lid, name, _sid, ssid in [(r[0], r[1], r[2], s[2])
                                  for r, s in zip(rows, src_rows)]:
        cur.execute("UPDATE local_changes SET entity_sync_id=? "
                    "WHERE entity_type='ledger' AND entity_id=?", (ssid, lid))
    con.commit()
    n = con.execute("SELECT COUNT(DISTINCT sync_id) FROM ledgers").fetchone()[0]
    print(f"  改写完成，账本数={len(rows)}，distinct sync_id={n}")
    con.close()
    return 0 if n == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
