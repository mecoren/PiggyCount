# -*- coding: utf-8 -*-
"""契约内字段指纹：把「只比对同步契约内字段」的口径做成可复算的指纹。

为什么单独做：直接 `select *` 求哈希会把**设备本地列**（created_at / updated_at /
created_by_user_id / last_edited_by_user_id …）也算进去，这些列两端本来就不同
（设计如此，见 compare_sync_final.py 的契约外字段块），会让「两端指纹不同」看起来
像不一致。
本脚本复用 compare_sync_final 的 SPEC + build()，只对**契约内字段**取指纹，
于是它能把 compare 的「字段差异 = 0」压缩成一个可直接比对的短串。

用法: python wd_contract_fp.py <A.sqlite> <B.sqlite> [--label X]
"""
import hashlib
import os
import sqlite3
import sys

# compare_sync_final.py 仍是 scripts/live_db/ 下唯一入库的比对脚本，显式指过去
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "live_db"))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import compare_sync_final as cs  # noqa: E402


def fp(path):
    conn = sqlite3.connect(path)
    cur = conn.cursor()
    per = {}
    for spec in cs.SPEC:
        try:
            data = cs.build(cur, spec)          # {key: (synced, local)}
        except Exception as e:                   # noqa: BLE001
            per[spec.table] = f"ERR:{e}"
            continue
        h = hashlib.sha256()
        for k in sorted(data):
            h.update(repr((k, data[k][0])).encode("utf-8", "replace"))
        per[spec.table] = f"{h.hexdigest()[:16]}(n={len(data)})"
    conn.close()
    return per


def main():
    a, b = sys.argv[1], sys.argv[2]
    label = sys.argv[sys.argv.index("--label") + 1] if "--label" in sys.argv else "?"
    fa, fb = fp(a), fp(b)
    lines = [f"===== {label} 契约内字段指纹（不含设备本地列）====="]
    bad = 0
    for t in fa:
        ok = fa[t] == fb[t]
        bad += 0 if ok else 1
        lines.append(f"  {'[同]' if ok else '[异]'} {t:26s} {fa[t]:26s} {fb[t]:26s}")
    lines.append(f"  结论: 契约内指纹不一致的表 = {bad}")
    text = "\n".join(lines)
    print(text)
    return 0 if bad == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
