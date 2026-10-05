# -*- coding: utf-8 -*-
"""跨轮变更核对：R(n-1)→R(n) 在 A 端究竟改了什么，并确认 B 端同值。

compare_sync_final.py 证明的是「同一轮 A 与 B 一致」；本脚本补上另一半——
「这一轮到底改没改到东西、改的东西有没有真被云端搬运到 B 端」。
两件事合起来才能排除「样本压根没变」的假通过。

归一化**直接复用 compare_sync_final.py 的 SPEC / build()**，不另写一套：
  * 关系列（分类/账户/周期）一律本地自增 id → syncId 后再比；
    否则 A 的 category_id=21 与 B 的 category_id=7 会被当成差异（**假告警**，
    本轮第一次写本脚本时就踩了这个坑）；
  * amount/native_amount/original_amount 走 round2，custom_values_json 走 JSON 键序归一。

★ 另一个坑：列名写错时 sqlite3 抛异常，若被 `except` 静默成占位值，
两边会长得一模一样 → 打印「新增 0 / 消失 0 / 字段变化 0」，看上去像
「本轮没改动」，实际是**探针坏了**。所以本脚本对错误一律抛出，绝不吞。

★ 参数化（2026-10-04 改造）：本脚本原先把 `rounds=("R1".."R4")`、文件名前缀 `S3`、
以及一批**该轮专属**的 sync_id 探针全部写死 —— 那是 S3 那一轮的报告生成器，
不是可复用工具。现改为：
  * `--rounds` / `--prefix` 由命令行给（WebDAV 轮用 `--prefix WD`）；
  * 轮次专属的「单点核对」段走 `--probe <probe.json>`，不再内置任何 sync_id
    （S3 轮的探针配方保留在 `scripts/live_db/run_20261004b/` 那份里，可作模板）。

用法:
  python mutation_check.py <out.txt> [--rounds R1,R2,R3] [--prefix S3|WD|""]
                          [--probe probe.json]

probe.json 结构::

  {"points": [
     {"title": "R2/R3/R4 新增交易 374f603a",
      "rounds": ["R2", "R3", "R4"],
      "side": "A",
      "sql": "SELECT sync_id, amount FROM transactions WHERE sync_id LIKE '374f603a%'"}
  ]}
"""
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# compare_sync_final.py 仍是 scripts/live_db/ 下唯一入库的比对脚本，显式指过去
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "live_db"))
import compare_sync_final as cs  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
WATCH = ("ledgers", "accounts", "categories", "transactions")


def _dbpath(prefix, tag, side):
    return os.path.join(RD, f"{prefix}{tag}_{side}.sqlite")


def norm(path):
    if not os.path.exists(path):
        raise FileNotFoundError(f"缺少快照 {path}（snapdb.py 是否跑过？）")
    conn = sqlite3.connect(path)
    cur = conn.cursor()
    out = {}
    for table in WATCH:
        spec = next(s for s in cs.SPEC if s.table == table)
        out[table] = cs.build(cur, spec)      # {key: (synced, local)}
    conn.close()
    return out


def diff_block(table, prev, cur, limit=6):
    add = sorted(set(cur) - set(prev))
    rm = sorted(set(prev) - set(cur))
    chg = [(k, prev[k][0], cur[k][0]) for k in set(prev) & set(cur)
           if prev[k][0] != cur[k][0]]
    labels = [lab for lab, _, _ in
              next(s for s in cs.SPEC if s.table == table).fields]
    out = [f"  {table}: 新增 {len(add)} / 消失 {len(rm)} / 契约内字段变化 {len(chg)}"]
    for k in add[:limit]:
        out.append(f"    + {cs.fmt_key(k)} -> {dict(zip(labels, cur[k][0]))}")
    for k in rm[:limit]:
        old = dict(zip(labels, prev[k][0]))
        out.append(f"    - {cs.fmt_key(k)} (旧值 {old})")
    for k, o, n in chg[:limit]:
        pairs = ", ".join(f"{labels[i]}:{a}→{b}" for i, (a, b) in enumerate(zip(o, n))
                          if a != b)
        out.append(f"    * {cs.fmt_key(k)}  {pairs}")
    return out


def probe_section(points, prefix, rounds):
    lines = ["\n===== 按 probe.json 逐项核对（A 端值 / B 端值）====="]
    for pt in points:
        lines.append(f"  {pt.get('title', '(未命名)')}")
        for tag in pt.get("rounds", rounds):
            for side in pt.get("sides", ["A", "B"]):
                path = _dbpath(prefix, tag, side)
                if not os.path.exists(path):
                    lines.append(f"    {tag}/{side}: 缺快照")
                    continue
                conn = sqlite3.connect(path)
                try:
                    rows = conn.execute(pt["sql"]).fetchall()
                finally:
                    conn.close()
                lines.append(f"    {tag}/{side}: {rows}")
    return lines


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_name = args[0] if args else "mutation_check.txt"
    prefix = "S3"
    if "--prefix" in sys.argv:
        prefix = sys.argv[sys.argv.index("--prefix") + 1]
    rounds = ("R1", "R2", "R3", "R4")
    if "--rounds" in sys.argv:
        rounds = tuple(r.strip() for r in
                       sys.argv[sys.argv.index("--rounds") + 1].split(",") if r.strip())
    probe_file = (sys.argv[sys.argv.index("--probe") + 1]
                  if "--probe" in sys.argv else None)

    A = {t: norm(_dbpath(prefix, t, "A")) for t in rounds}
    B = {t: norm(_dbpath(prefix, t, "B")) for t in rounds}

    lines = [f"===== 各轮 A 端「相对上一轮」的真实改动（契约内字段口径）=====",
             f"前缀={prefix}  轮次={','.join(rounds)}"]
    for i in range(1, len(rounds)):
        prev, cur = rounds[i - 1], rounds[i]
        lines.append(f"\n--- {prev} -> {cur} ---")
        for table in WATCH:
            lines += diff_block(table, A[prev][table], A[cur][table])
        lines.append(f"  → 该轮变更实体在 B({cur}) 端落地：")
        for table in WATCH:
            p, c, b = A[prev][table], A[cur][table], B[cur][table]
            keys = ((set(c) - set(p))
                    | {k for k in set(p) & set(c) if p[k][0] != c[k][0]})
            missing = sorted(k for k in keys if k not in b)
            differ = sorted(k for k in keys if k in b and b[k][0] != c[k][0])
            verdict = "同值 ✅" if not missing and not differ else "有出入 ❌"
            lines.append(f"     {table:14s} 变更 {len(keys):3d} 项 → "
                         f"B 缺失 {len(missing)} / 取值不同 {len(differ)}  {verdict}")
            for k in missing[:4]:
                lines.append(f"        [B 缺失] {cs.fmt_key(k)}")
            for k in differ[:4]:
                lines.append(f"        [B 不同] {cs.fmt_key(k)}"
                             f"  A={c[k][0]}  B={b[k][0]}")

    # 每轮两端的行数总览（一眼看出「哪轮动了、动的是我没碰的表吗」）
    lines.append("\n===== 每轮两端行数总览 =====")
    for tag in rounds:
        row = [f"  {tag}:"]
        for side in ("A", "B"):
            path = _dbpath(prefix, tag, side)
            if not os.path.exists(path):
                row.append(f"{side}(缺快照)")
                continue
            conn = sqlite3.connect(path)
            try:
                vals = [conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                        for t in ("transactions", "deleted_transactions",
                                  "categories", "accounts")]
            finally:
                conn.close()
            row.append(f"{side}(tx={vals[0]} 回收站={vals[1]} "
                       f"分类={vals[2]} 账户={vals[3]})")
        lines.append("  ".join(row))

    if probe_file:
        with open(probe_file, encoding="utf-8") as f:
            lines += probe_section(json.load(f).get("points", []), prefix, rounds)
    else:
        lines.append("\n（未提供 --probe，跳过轮次专属单点核对；"
                     "S3 轮的探针配方见 scripts/live_db/run_20261004b/ 的同名脚本）")

    text = "\n".join(lines)
    print(text)
    with open(os.path.join(RD, out_name), "w", encoding="utf-8",
              newline="") as f:
        f.write(text)
    print(f"\n-> {out_name}")


if __name__ == "__main__":
    main()
