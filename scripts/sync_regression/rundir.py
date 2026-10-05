# -*- coding: utf-8 -*-
"""统一的「产物输出目录」解析 —— harness 里所有脚本共用。

为什么需要它：harness 代码是**入库**的（`scripts/sync_regression/`），
而证据产物（sqlite 快照、UI dump、日志切片）**绝不能落在入库目录里**
——否则跑一次测试就把几十 MB 的账本 dump 写进版本库。
（这正是 `scripts/live_db/` 被整目录忽略的原因："roundtrip test fixtures
contain real-looking ledger dumps"。）

解析优先级：
  1. 环境变量 `SYNC_RUN_DIR`（`run_full_regression.py` 会设成 `run_<tag>/`，
     让一次完整回归的产物集中在一个目录里）
  2. `<repo>/scripts/live_db/run_<YYYYMMDD>`（同日多次运行共用）

目录不存在会自动创建。用法：

    import rundir
    RD = rundir.run_dir()
"""
import datetime
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(os.path.dirname(_HERE))          # scripts/sync_regression -> repo


def run_dir() -> str:
    """返回（并确保存在）本轮产物目录。"""
    d = os.environ.get("SYNC_RUN_DIR") or os.path.join(
        _REPO, "scripts", "live_db",
        "run_" + datetime.date.today().strftime("%Y%m%d"))
    os.makedirs(d, exist_ok=True)
    return d


def repo_root() -> str:
    """仓库根。

    ★ 为什么必须走这里而不是自己数 `dirname()`：本 harness 的脚本是从
    `scripts/live_db/run_*/`（4 层深）整体搬到 `scripts/sync_regression/`（2 层深）的。
    `push_seed.py` 里写死的 `dirname×4` 搬完就指到了 `DevTools/project`，静默指错
    种子库路径 —— 这是搬迁最容易留下的暗伤。统一走 repo_root() 就不会再犯。
    """
    return _REPO


def is_inside_repo_tracked(path: str) -> bool:
    """守卫：产物路径若落在 harness 目录内，说明调用方忘了用 run_dir()。"""
    return os.path.abspath(path).startswith(_HERE + os.sep)


if __name__ == "__main__":
    print(run_dir())
