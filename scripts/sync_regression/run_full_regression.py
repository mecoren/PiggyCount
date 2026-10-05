#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""双端云同步回归 —— **单命令全流程编排**（2026-10-04 优化项 ⑧）。

## 它解决什么

在 ⑦/⑧ 之前，一轮回归是**几十条手工命令**：清库、切后端、推种子、逐轮
「导航到同步页 → 点上传 → 等完成 → 拉库 → 冷启动 B → 点下载 → 拉库 →
比对 → 收证据」，每一条都要人记住顺序、路径和命名约定。后果：
  * 命名靠人脑维持（`S3R1_A.sqlite` / `WDR1_A.sqlite` / `S3R1_a_16384_...`），
    一旦写错，比对脚本报「缺快照」而人还以为是同步失败；
  * 产物散在 `scripts/live_db/run_<日期>/` 里靠猜；
  * 证据（logcat / app_logs）经常忘抓，或抓晚了被环挤掉（见 evidence.py 的教训）。
本脚本把上述编排**固化成一个命令**，并保证：
  * 产物目录显式、写进 `SYNC_RUN_DIR` 传给所有子进程（rundir.py 统一解析）；
  * 每步都记退出码与耗时，最后出一张总表；
  * 上传/下载结束**立刻**由 round.py 自动冻结证据（⑦）。

## 不做的事（有意为之）

**不自动执行 A 端语义变更**（改金额 / 加一笔 / 软删 / 改账本名）。
那些是**测试场景**，不是机械流程：改哪一笔、改成什么值，取决于本轮想验证
什么（见 S3/WebDAV 两份报告 §5.1 的变更集）。硬编码它们只会让工具只能跑一次。
所以变更通过 `--mutate` 挂**外部脚本**注入，脚本自身放在运行目录里，与报告同源。

## 用法

  # 干跑：只打印将要执行的命令序列（不碰设备）
  python run_full_regression.py --backend s3 --rounds 5 --dry-run

  # S3 完整回归：清库 → 切 S3 → 推种子 → 5 轮 → 汇总
  python run_full_regression.py --backend s3 --rounds 5

  # WebDAV：每轮上传前跑一遍变更脚本（按轮指定）
  python run_full_regression.py --backend webdav --rounds 5 \
      --mutate-at R2=mut/r2_edit_add_del.py \
      --mutate-at R3=mut/r3_account.py \
      --mutate-at R4=mut/r4_rename.py

  # 只跑编排的收尾部分（不重跑同步）
  python run_full_regression.py --backend s3 --rounds 5 --only-post

## 退出码
  0  全部轮次 compare 均无非预期差异
  2  至少一轮 compare 报不一致（= 测试结论为「发现差异」）
  3  至少一轮 compare 报契约漂移（SPEC 与 Dart 实现脱节，需先修工具）
  4  编排流程本身中断（某步失败且未 --keep-going）
  9  --dry-run
"""
import argparse
import datetime
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 只用 repo_root()，不依赖 SYNC_RUN_DIR

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = rundir.repo_root()
PY = sys.executable
LIVE_DB = os.path.join(REPO, "scripts", "live_db")
PREFIX = {"s3": "S3", "webdav": "WD"}
PORT_A, PORT_B = "16384", "16416"


# ------------------------------------------------------------------ 进程与记账
class Step:
    def __init__(self, sid, title, cmd, timeout=3600, optional=False):
        self.sid, self.title, self.cmd = sid, title, cmd
        self.timeout, self.optional = timeout, optional
        self.code, self.secs = None, None
        self.log = None


def sh_quote(cmd):
    return " ".join(f'"{c}"' if (" " in c and not c.startswith('"')) else c for c in cmd)


def run_step(step, run_dir, env, dry=False, quiet=False):
    """执行一步；stdout/stderr 流式转发并同时写日志文件。返回退出码。"""
    log_path = os.path.join(run_dir, f"_{step.sid}.log")
    step.log = log_path
    print(f"\n{'='*78}\n[{time.strftime('%H:%M:%S')}] STEP {step.sid}  {step.title}"
          f"\n  $ {sh_quote(step.cmd)}\n  log: {os.path.basename(log_path)}\n{'='*78}",
          flush=True)
    if dry:
        step.code, step.secs = 0, 0.0
        return 0
    t0 = time.time()
    with open(log_path, "w", encoding="utf-8", errors="replace", newline="") as lf:
        p = subprocess.Popen(step.cmd, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, env=env, cwd=REPO,
                             text=True, encoding="utf-8", errors="replace",
                             bufsize=1)
        try:
            for line in p.stdout:
                lf.write(line)
                lf.flush()
                if not quiet:
                    print("    " + line.rstrip(), flush=True)
            p.wait(timeout=step.timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            print(f"    [TIMEOUT] {step.timeout}s", flush=True)
            step.code, step.secs = 124, time.time() - t0
            return 124
    step.code, step.secs = p.returncode, time.time() - t0
    print(f"  -> exit={step.code}  {step.secs:.0f}s", flush=True)
    return step.code


# ------------------------------------------------------------------ 步骤构造
def build_smoke_plan(a):
    """--smoke：只跑**只读/管道**步骤，验证 harness 与两端联通，不碰云端数据。

    刻意不含 clear_db / push_seed / 上传 / 下载 —— 那些都会改变本地库或云端内容。
    用途：改了 harness 之后先跑一遍它，确认「脚本能跑通、产物落在对的地方、
    子进程确实继承了 SYNC_RUN_DIR」，再去跑真回归。
    """
    rnd = a.prefix
    rt = f"{rnd}R1"
    steps = [
        Step("smoke_01_prefs_keys", "读两端云配置键值（只读）",
             [PY, os.path.join(HERE, "prefs_keys.py"), "prefs_keys.txt"]),
        Step("smoke_02_final_state", "读两端最终状态（只读）",
             [PY, os.path.join(HERE, "final_state.py"), "final_state.txt"]),
        Step("smoke_03_snap_A", "拉 A 端快照（force-stop 后只读拷贝）",
             [PY, os.path.join(HERE, "snapdb.py"), PORT_A, f"{rt}_A.sqlite"]),
        Step("smoke_04_snap_B", "拉 B 端快照",
             [PY, os.path.join(HERE, "snapdb.py"), PORT_B, f"{rt}_B.sqlite"]),
        Step("smoke_05_cmp", "两端一致性比对（只看当前状态）",
             [PY, os.path.join(LIVE_DB, "compare_sync_final.py"),
              os.path.join(a.run_dir, f"{rt}_A.sqlite"),
              os.path.join(a.run_dir, f"{rt}_B.sqlite"),
              "--label", a.backend], optional=True),
        Step("smoke_06_boot_A", "A 端冷启动（观察启动期同步检查）",
             [PY, os.path.join(HERE, "boot_check.py"), PORT_A, f"{rnd}END_a"],
             optional=True),
        Step("smoke_07_boot_B", "B 端冷启动（观察启动期同步检查）",
             [PY, os.path.join(HERE, "boot_check.py"), PORT_B, f"{rnd}END_b"],
             optional=True),
        Step("smoke_08_applog", "汇总冻结的 app_logs 证据",
             [PY, os.path.join(HERE, "applog_evidence.py"),
              "applog_evidence.txt"], optional=True),
    ]
    return [("只读冒烟（不改本地库 / 不碰云端）", steps)]


def build_plan(a):
    """返回 [(阶段名, [Step, ...]), ...]；Step 的 cmd 已就绪。"""
    rnd = a.prefix
    rounds = [f"{rnd}R{i}" for i in range(1, a.rounds + 1)]
    mapfile = (os.path.join(a.mutate_dir, a.mutate_map) if a.mutate_map else None)
    mut = dict(a.mutate_at)
    plan = []

    pre = []
    if not a.skip_clear:
        pre.append(Step("01_clear_db", "清两库（保云配置，含指纹校验）",
                        [PY, os.path.join(HERE, "clear_db.py")]))
    if not a.skip_switch:
        pre.append(Step("02_switch_backend", f"两端切到 {a.backend}（纯 UI）",
                        [PY, os.path.join(HERE, "switch_backend.py"), a.backend]))
    if not a.skip_seed:
        seed = os.path.join(LIVE_DB, "seed_16384.sqlite")
        pre.append(Step(
            "03_push_seed", f"推种子库到 A 端（{os.path.basename(seed)}）",
            [PY, os.path.join(HERE, "push_seed.py")],
            optional=not os.path.exists(seed)))
    plan.append(("准备", pre))

    for i, rt in enumerate(rounds, start=1):
        steps = []
        # A 端语义变更：优先 --mutate-at <轮>，否则 --mutate 每轮跑
        hook = mut.get(f"R{i}") or a.mutate
        if hook:
            if hook.endswith(".py"):
                cmd = [PY, hook]
            elif os.name == "nt":
                cmd = ["cmd", "/c", hook]
            else:
                cmd = ["/bin/sh", "-c", hook]
            steps.append(Step(f"{rt}_00_mutate", f"A 端变更：{hook}", cmd,
                              timeout=1800))
        steps.append(Step(f"{rt}_A1_to_sync", "A 端导航到同步页",
                          [PY, os.path.join(HERE, "to_sync.py"), PORT_A, rt]))
        steps.append(Step(f"{rt}_A2_upload", "A 端全量上传（含 ⑦ 证据落盘）",
                          [PY, os.path.join(HERE, "round.py"), "upload", rt, PORT_A]))
        steps.append(Step(f"{rt}_SNAP_A", "拉 A 端快照（sqlite+wal+shm）",
                          [PY, os.path.join(HERE, "snapdb.py"), PORT_A,
                           f"{rt}_A.sqlite"]))
        if i == 1:
            steps.append(Step(f"{rt}_B1_first_sync",
                              "B 端冷启动 → 发现云端账本 → 下载 → 等导入",
                              [PY, os.path.join(HERE, "b_first_sync.py"), PORT_B, rt]))
        else:
            steps.append(Step(f"{rt}_B1_boot", "B 端冷启动（观察启动期同步检查）",
                              [PY, os.path.join(HERE, "boot_check.py"), PORT_B,
                               f"{rt}B", "skip"]))
            steps.append(Step(f"{rt}_B2_to_sync", "B 端导航到同步页",
                              [PY, os.path.join(HERE, "to_sync.py"), PORT_B, rt]))
            steps.append(Step(f"{rt}_B3_download", "B 端全量下载（含 ⑦ 证据落盘）",
                              [PY, os.path.join(HERE, "round.py"), "download", rt,
                               PORT_B]))
        steps.append(Step(f"{rt}_SNAP_B", "拉 B 端快照",
                          [PY, os.path.join(HERE, "snapdb.py"), PORT_B,
                           f"{rt}_B.sqlite"]))
        # compare 的退出码就是本轮结论：0 一致 / 2 不一致 / 3 契约漂移
        steps.append(Step(
            f"{rt}_CMP", "两端一致性比对（契约内字段）",
            [PY, os.path.join(LIVE_DB, "compare_sync_final.py"),
             os.path.join(a.run_dir, f"{rt}_A.sqlite"),
             os.path.join(a.run_dir, f"{rt}_B.sqlite"),
             "--label", a.backend],
            optional=True))
        plan.append((f"第 {i} 轮（{rt}）", steps))

    post = [Step("90_applog_evidence", "汇总逐轮冻结的 app_logs 证据",
                 [PY, os.path.join(HERE, "applog_evidence.py"),
                  "applog_evidence.txt"])]
    if a.rounds >= 2:
        post.append(Step("91_mutation_check", "跨轮变更核对（改了什么 / 有没有搬到 B）",
                         [PY, os.path.join(HERE, "mutation_check.py"),
                          "mutation_check.txt", "--prefix", rnd,
                          "--rounds", ",".join(f"R{i}" for i in range(1, a.rounds + 1))],
                         optional=True))
    post.append(Step("92_prefs_keys", "两端云配置键值核对",
                     [PY, os.path.join(HERE, "prefs_keys.py"), "prefs_keys.txt"]))
    post.append(Step("93_final_state", "最终状态（云配置指纹 + 同步状态）",
                     [PY, os.path.join(HERE, "final_state.py"), "final_state.txt"]))
    if a.backend == "webdav":
        post.append(Step("94_wd_cloud_snapshot", "WebDAV 服务端数据目录审计",
                         [PY, os.path.join(HERE, "wd_cloud_snapshot.py"),
                          "wd_cloud_snapshot.txt",
                          "--dir", a.serve_dir]))
    post.append(Step("95_stats", "数据样本统计",
                     [PY, os.path.join(HERE, "stats.py"),
                      "--db", f"{rnd}R1_A.sqlite",
                      "--label", f"{a.backend} 轮 R1 基线（A 端）"], optional=True))
    if a.closeout:
        post.append(Step("96_closeout", "收尾：两端冷启动核对",
                         [PY, os.path.join(HERE, "boot_check.py"), PORT_A,
                          f"{rnd}END_a"], optional=True))
    plan.append(("汇总", post))
    return plan


# ------------------------------------------------------------------ 主流程
def main():
    ap = argparse.ArgumentParser(description="双端云同步回归：单命令全流程编排")
    ap.add_argument("--backend", choices=("s3", "webdav"), default="s3")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--tag", default=None,
                    help="产物目录后缀，默认 run_<backend>_<YYYYMMDD>_<HHMM>")
    ap.add_argument("--run-dir", default=None, help="显式指定产物目录")
    ap.add_argument("--skip-clear", action="store_true")
    ap.add_argument("--skip-switch", action="store_true")
    ap.add_argument("--skip-seed", action="store_true")
    ap.add_argument("--mutate", default=None, help="每轮上传前执行的命令/脚本路径")
    ap.add_argument("--mutate-at", action="append", default=[], metavar="R2=脚本",
                    help="仅指定轮执行的变更脚本，可重复")
    ap.add_argument("--mutate-dir", default=None, help="变更脚本所在目录（备查）")
    ap.add_argument("--mutate-map", default=None,
                    help="变更映射文件名（仅记录在摘要里，便于复现）")
    ap.add_argument("--serve-dir", default=os.path.join(
        REPO, "scripts", "webdav_test", "data", "piggycount"))
    ap.add_argument("--closeout", action="store_true", help="结尾加一次冷启动核对")
    ap.add_argument("--keep-going", action="store_true",
                    help="某步失败后继续（默认中断）")
    ap.add_argument("--only-post", action="store_true", help="只跑汇总段")
    ap.add_argument("--smoke", action="store_true",
                    help="只跑只读冒烟（验证 harness 本身，不改任何数据）")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="不回显子进程 stdout")
    a = ap.parse_args()

    # 1) 轮次标签与产物目录（必须在 import 任何依赖 SYNC_RUN_DIR 的模块**之前**确定）
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M")
    tag = a.tag or f"{a.backend}_{stamp}"
    a.run_dir = a.run_dir or os.path.join(LIVE_DB, f"run_{tag}")
    if not a.dry_run:
        os.makedirs(a.run_dir, exist_ok=True)
    a.prefix = PREFIX[a.backend]
    a.mutate_at = [tuple(x.split("=", 1)) for x in a.mutate_at if "=" in x]
    a.mutate_dir = a.mutate_dir or a.run_dir
    a.rounds = max(1, a.rounds)

    if not a.mutate_map and a.mutate_at:
        amap = os.path.join(a.run_dir, "mutate_map.txt")
        if not a.dry_run:
            with open(amap, "w", encoding="utf-8", newline="") as f:
                for r, h in a.mutate_at:
                    f.write(f"{r}\t{h}\n")
        a.mutate_map = os.path.basename(amap)

    env = dict(os.environ)
    env["SYNC_RUN_DIR"] = a.run_dir
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUNBUFFERED"] = "1"
    env["MSYS_NO_PATHCONV"] = "1"

    print("=" * 78)
    print(f"PiggyCount 双端云同步回归  backend={a.backend}  rounds={a.rounds}")
    print(f"  产物目录 : {a.run_dir}")
    print(f"  文件名前缀: {a.prefix}   （快照 = {a.prefix}R1_A.sqlite / {a.prefix}R1_B.sqlite）")
    if a.mutate or a.mutate_at:
        print(f"  变更脚本 : {dict(a.mutate_at) if a.mutate_at else a.mutate}")
    print(f"  python   : {PY}")
    print("=" * 78)

    if not a.dry_run and not os.path.exists(os.path.join(REPO, ".git")):
        print("  [WARN] 未在仓库根目录下运行？请确认 cwd 合理。", flush=True)

    plan = build_smoke_plan(a) if a.smoke else build_plan(a)
    if a.only_post:
        plan = [p for p in plan if p[0] == "汇总"]

    if a.dry_run:
        print("\n---------- DRY RUN：以下是将要执行的命令 ----------")
        for stage, steps in plan:
            print(f"\n### {stage}")
            for s in steps:
                opt = "  [optional]" if s.optional else ""
                print(f"  {s.sid:<16} {s.title}{opt}")
                print(f"      $ {sh_quote(s.cmd)}")
        print("\n（dry-run 未执行任何命令）")
        return 9

    results = []
    t_all = time.time()
    for stage, steps in plan:
        print(f"\n\n########## 阶段：{stage} ##########", flush=True)
        for s in steps:
            code = run_step(s, a.run_dir, env, quiet=a.quiet)
            results.append((stage, s, code))
            bad = (code != 0) and not s.optional
            if code == 3 and is_cmp(s.sid):
                bad = True                      # 契约漂移必须先修工具，不是测试结论
            if bad and not a.keep_going:
                print(f"\n[ABORT] {s.sid} 失败（exit={code}）且非 optional，"
                      f"已中断。加 --keep-going 可继续。", flush=True)
                write_summary(a, results, aborted=True)
                return 4

    return write_summary(a, results)


def is_cmp(sid):
    """比对步骤的识别：真回归用 `<rt>_CMP`，冒烟用 `smoke_05_cmp` —— 大小写都认。"""
    return os.path.basename(sid).upper().endswith("CMP")


def write_summary(a, results, aborted=False):
    cmp_codes = [c for (_, s, c) in results if is_cmp(s.sid)]
    lines = ["=" * 78,
             f"PiggyCount 双端云同步回归 汇总  backend={a.backend}",
             f"产物目录 : {a.run_dir}",
             f"生成时间 : {datetime.datetime.now():%Y-%m-%d %H:%M:%S}",
             "=" * 78, "",
             f"{'步骤':<18} {'退出码':>6} {'耗时':>8}  说明",
             "-" * 78]
    for stage, s, code in results:
        flag = "" if code == 0 else ("  ⚠️" if s.optional else "  ❌")
        secs = f"{s.secs:.0f}s" if s.secs is not None else "-"
        lines.append(f"{s.sid:<18} {str(code):>6} {secs:>8}  {s.title}{flag}")
    lines.append("-" * 78)
    lines.append("")
    lines.append("比对结论（compare_sync_final.py 退出码：0 一致 / 2 不一致 / 3 契约漂移）:")
    if not cmp_codes:
        lines.append("  （无比对步骤）")
    for (_, s, c) in results:
        if is_cmp(s.sid):
            verdict = {0: "一致（契约内字段无非预期差异）",
                       2: "发现差异（见报告 §差异分析）",
                       3: "契约漂移（SPEC 与 Dart 实现脱节，先修工具）"}.get(c, f"未跑完 exit={c}")
            lines.append(f"  {s.sid:<10} exit={c}  {verdict}")
    # 证据与产物清单
    if os.path.isdir(a.run_dir):
        files = sorted(f for f in os.listdir(a.run_dir) if not f.startswith("_"))
        lines += ["", f"产物 {len(files)} 个（前 40）:"]
        for f in files[:40]:
            lines.append(f"  {f}")
        if len(files) > 40:
            lines.append(f"  … 其余 {len(files)-40} 个见目录")
    text = "\n".join(lines)
    print("\n" + text)
    path = os.path.join(a.run_dir, "_run_summary.txt")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"\n-> {path}")

    if aborted:
        return 4
    if 3 in cmp_codes:
        return 3
    if 2 in cmp_codes:
        return 2
    return 0 if cmp_codes else 4


if __name__ == "__main__":
    sys.exit(main())
