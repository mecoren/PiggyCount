#!/usr/bin/env python3
"""把 Flutter `--coverage` 产出的 lcov.info 汇总成 Markdown（供 CI Job Summary）。

用法:
    python scripts/coverage_summary.py coverage/lcov.info
    python scripts/coverage_summary.py coverage/lcov.info --top 20
    python scripts/coverage_summary.py coverage/lcov.info --fail-under 40

`--fail-under` 是可选硬门禁：行覆盖率低于该百分比时退出码 2。
本期（E1）只建基线，CI 不传该参数，因此不会因覆盖率波动红。
"""
from __future__ import annotations

import argparse
import os
import sys


def _to_int(value: str) -> int:
    try:
        return int(value.strip())
    except ValueError:
        return 0


def _normalize_path(path: str) -> str:
    """把 CI 绝对路径裁成仓库相对路径（`lib/...` / `packages/...`）。"""
    p = path.replace("\\", "/")
    for marker in ("/lib/", "/packages/", "/test/"):
        idx = p.find(marker)
        if idx >= 0:
            return p[idx + 1:]
    if p.startswith(("lib/", "packages/", "test/")):
        return p
    return p


def parse_lcov(path: str) -> dict[str, dict[str, int]]:
    files: dict[str, dict[str, int]] = {}
    current: str | None = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("SF:"):
                current = _normalize_path(line[3:])
                files.setdefault(current, {
                    "lf": 0, "lh": 0,
                    "fnf": 0, "fnh": 0,
                    "brf": 0, "brh": 0,
                })
            elif current is None:
                continue
            elif line.startswith("LF:"):
                files[current]["lf"] = _to_int(line[3:])
            elif line.startswith("LH:"):
                files[current]["lh"] = _to_int(line[3:])
            elif line.startswith("FNF:"):
                files[current]["fnf"] = _to_int(line[4:])
            elif line.startswith("FNH:"):
                files[current]["fnh"] = _to_int(line[4:])
            elif line.startswith("BRF:"):
                files[current]["brf"] = _to_int(line[4:])
            elif line.startswith("BRH:"):
                files[current]["brh"] = _to_int(line[4:])
    return files


def pct(hit: int, found: int) -> str:
    if found <= 0:
        return "—"
    return f"{hit * 100.0 / found:.1f}%"


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize lcov coverage")
    parser.add_argument("lcov", help="path to lcov.info")
    parser.add_argument("--top", type=int, default=20,
                        help="show N files with the lowest line coverage")
    parser.add_argument("--fail-under", type=float, default=None,
                        help="fail (exit 2) when line coverage is below this %%")
    args = parser.parse_args()

    if not os.path.isfile(args.lcov):
        print(f"::error::coverage file not found: {args.lcov}")
        return 1

    files = parse_lcov(args.lcov)
    if not files:
        print("::warning::lcov.info 里没有任何 SF 记录")
        return 0

    # 只统计 lib/（test/ 与生成代码不进入产品覆盖率基线）。
    lib_files = {p: v for p, v in files.items() if p.startswith("lib/")}
    if not lib_files:
        lib_files = files

    totals = {k: sum(v[k] for v in lib_files.values())
              for k in ("lf", "lh", "fnf", "fnh", "brf", "brh")}

    print("## 测试覆盖率（lcov）\n")
    print(f"- 统计文件：`lib/` 下 {len(lib_files)} 个")
    print(f"- 行覆盖率：**{pct(totals['lh'], totals['lf'])}**"
          f"（{totals['lh']}/{totals['lf']}）")
    print(f"- 函数覆盖率：**{pct(totals['fnh'], totals['fnf'])}**"
          f"（{totals['fnh']}/{totals['fnf']}）")
    print(f"- 分支覆盖率：**{pct(totals['brh'], totals['brf'])}**"
          f"（{totals['brh']}/{totals['brf']}）\n")

    ranked = sorted(
        (v for v in lib_files.values() if v["lf"] > 0),
        key=lambda v: (v["lh"] * 100.0 / v["lf"]) if v["lf"] else 100.0,
    )
    if args.top > 0 and ranked:
        print(f"### 行覆盖率最低的 {min(args.top, len(ranked))} 个文件\n")
        print("| 文件 | 行覆盖 | 命中/总数 |")
        print("|---|---|---|")
        path_by_id = {id(v): p for p, v in lib_files.items()}
        for v in ranked[: args.top]:
            print(f"| `{path_by_id[id(v)]}` | {pct(v['lh'], v['lf'])} "
                  f"| {v['lh']}/{v['lf']} |")
        print()

    if args.fail_under is not None:
        actual = 100.0 if totals["lf"] == 0 else totals["lh"] * 100.0 / totals["lf"]
        if actual < args.fail_under:
            print(f"::error::行覆盖率 {actual:.1f}% 低于阈值 {args.fail_under:.1f}%")
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
