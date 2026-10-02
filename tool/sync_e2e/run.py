# -*- coding: utf-8 -*-
"""PiggyCount 同步 E2E —— 宿主端**唯一入口**（取数 / 判据 / 委派）。

配套设备端驱动：`tool/sync_e2e/main.dart`（在真机上跑，复用 App 自身 Repository
与快照导出）。两者合起来是本项目的同步回归工具；**新增判据只加在本文件**，
不要再往某次 run 的临时脚本里写（历史上 `field_coverage.py` 写在 gitignore 的
`run_*/` 里随目录丢失，判据实现因此不可复现 —— 本文件即为修复该问题而建）。

用法:
  python tool/sync_e2e/run.py pull <serial> <outdir>
  python tool/sync_e2e/run.py compare <dirA> <dirB>
  python tool/sync_e2e/run.py coverage <dirA> [<dirB>] [--require PROFILE|a,b,c]
  python tool/sync_e2e/run.py all <dirA> <dirB> [--require PROFILE|a,b,c]
  python tool/sync_e2e/run.py db <A.sqlite> <B.sqlite> [--label S3|WebDAV]

三层判据（互补，缺一层就可能漏一类缺陷）:
  1. compare —— **载荷字节级对称性**：两端各自导出的 `ledger_*.json` 除 `exportedAt`
     外必须逐字节相同。专抓「指纹相同、字节不同」的静默不对称（2026-10-02 用它抓到
     转账分类归空、导出排序兜底键、预算启用态三处缺陷 —— 这三处指纹都判不出差异）。
  2. coverage —— **字段覆盖度门禁**：声明「本次必须真被覆盖」的字段，双端都得有非空/
     非默认值实测证据，否则判失败。防的是「差异=0 其实因为该字段两端都是空」的平凡通过。
  3. db —— **DB 级契约比对**：委派 `scripts/live_db/compare_sync_final.py`（v4：从 Dart
     实现派生契约字段集并三向校验）。它比载荷更细（逐列、按 syncId 对齐、契约内外分列），
     但看不到「快照序列化口径」这一层，故必须与 1 一起用。

退出码: 0 = 全部判据通过；1 = 有判据不成立；2 = 用法/环境错误。
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

PKG = "com.wait.piggycount.dev.debug"
APP_DIR = f"/data/data/{PKG}/app_flutter"

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DB_COMPARATOR = os.path.join(REPO_ROOT, "scripts", "live_db", "compare_sync_final.py")

# 覆盖度门禁字段目录：名字 -> (说明, 判定函数(items, 账本本币) -> 命中条数)
# 判定一律基于**快照 payload 的 items**（导出侧口径），不看 DB —— 因为本门禁要守的
# 就是「快照里到底有没有把该字段搬出来」。
COVERAGE_CATALOG = {
    "transfer": ("转账交易（含双边账户名）",
                 lambda it, base: it.get("type") == "transfer"
                 and it.get("fromAccountName") and it.get("toAccountName")),
    "income": ("收入交易", lambda it, base: it.get("type") == "income"),
    "adjustment": ("估值调整（adjustment）",
                   lambda it, base: it.get("type") == "adjustment"),
    "original_amount": ("原始金额非空",
                        lambda it, base: it.get("originalAmount") is not None),
    "original_amount_zero": ("原始金额显式为 0（0 值可落库）",
                             lambda it, base: it.get("originalAmount") == 0),
    "custom_values": ("自定义字段值非空",
                      lambda it, base: bool(it.get("customValues"))),
    "multi_currency": ("非账本本币（多币种 / 折算）",
                       lambda it, base: bool(it.get("currencyCode"))
                       and it.get("currencyCode") != base),
    "exclude_flags": ("账单标记（不计入统计 / 预算）",
                      lambda it, base: bool(it.get("excludeFromStats"))
                      or bool(it.get("excludeFromBudget"))),
    "tags": ("标签关联（tags / tagSyncIds）",
             lambda it, base: bool(it.get("tags")) or bool(it.get("tagSyncIds"))),
    "recurring_anchor": ("周期锚点 recurringSyncId",
                         lambda it, base: bool(it.get("recurringSyncId"))),
    "attachments": ("附件清单（sha256/fileName）",
                    lambda it, base: bool(it.get("attachments"))),
}

# 预置档位：standard = 现成夹具（seed）就能满足的面；full = 需夹具额外造数（附件/周期锚点）
COVERAGE_PROFILES = {
    "standard": ["transfer", "income", "adjustment", "original_amount",
                 "original_amount_zero", "custom_values", "multi_currency",
                 "exclude_flags", "tags"],
    "full": list(COVERAGE_CATALOG.keys()),
}


def adb(serial, *args):
    out = subprocess.run(["adb", "-s", serial] + list(args), capture_output=True)
    return out.stdout


def pull(serial, outdir):
    """从设备取回命令产物（结果 JSON + 快照 payload）。"""
    os.makedirs(outdir, exist_ok=True)
    for name in ("dump", "probe", "seed", "mutate", "wipe", "checks", "rename"):
        raw = adb(serial, "exec-out", "run-as", PKG, "cat",
                  f"{APP_DIR}/e2e-result/{name}-latest.json")
        if raw.startswith(b"{"):
            with open(os.path.join(outdir, f"{name}.json"), "wb") as f:
                f.write(raw)
            print(f"ok  {name}.json ({len(raw)} bytes)")

    listing = adb(serial, "shell", "run-as", PKG, "ls",
                  f"{APP_DIR}/e2e-dump").decode("utf-8", "replace")
    files = [x.strip() for x in listing.split() if x.strip().startswith("ledger_")]
    if files:
        payload_dir = os.path.join(outdir, "payloads")
        os.makedirs(payload_dir, exist_ok=True)
        for name in files:
            raw = adb(serial, "exec-out", "run-as", PKG, "cat",
                      f"{APP_DIR}/e2e-dump/{name}")
            with open(os.path.join(payload_dir, name), "wb") as f:
                f.write(raw)
        print(f"ok  payloads/ {len(files)} 个账本快照")


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def _payloads(d):
    p = os.path.join(d, "payloads")
    if not os.path.isdir(p):
        return {}
    out = {}
    for n in sorted(os.listdir(p)):
        if n.startswith("ledger_") and n.endswith(".json"):
            out[n] = load(os.path.join(p, n))
    return out


def compare(dir_a, dir_b):
    """判据 1：载荷字节级对称性 + 账本/表计数一致性。返回 (通过, 问题列表)。"""
    problems = []
    a = load(os.path.join(dir_a, "dump.json"))
    b = load(os.path.join(dir_b, "dump.json"))
    print("=" * 78)
    print(f"A = {dir_a}")
    print(f"B = {dir_b}")
    print("=" * 78)
    print(f"A 账本数={a['ledgerCount']}  聚合指纹={a['aggregateSha256']}")
    print(f"B 账本数={b['ledgerCount']}  聚合指纹={b['aggregateSha256']}")
    if a["aggregateSha256"] != b["aggregateSha256"]:
        problems.append("聚合指纹不同")
    print(f"聚合指纹一致: {a['aggregateSha256'] == b['aggregateSha256']}")

    print("\n-- 表行数对比 --")
    for k in sorted(set(a["tables"]) | set(b["tables"])):
        va, vb = a["tables"].get(k), b["tables"].get(k)
        if va != vb:
            problems.append(f"表 {k} 行数不同: A={va} B={vb}")
        print(f"{'OK ' if va == vb else '差异'} {k:<28} A={va!s:<8} B={vb!s:<8}")

    print("\n-- 逐账本对比（按 syncId 配对）--")
    ma = {x["syncId"]: x for x in a["ledgers"]}
    mb = {x["syncId"]: x for x in b["ledgers"]}
    only_a, only_b = sorted(set(ma) - set(mb)), sorted(set(mb) - set(ma))
    if only_a or only_b:
        problems.append(f"账本集合不同：仅A={only_a} 仅B={only_b}")
    print(f"仅 A 有: {only_a}\n仅 B 有: {only_b}")
    same = 0
    fields = ["name", "currency", "monthStartDay", "txCount", "balance",
              "fingerprint", "payloadSha256"]
    for sid in sorted(set(ma) & set(mb)):
        x, y = ma[sid], mb[sid]
        diffs = [f for f in fields if x.get(f) != y.get(f)]
        if diffs:
            print(f"差异 {sid}")
            for f in diffs:
                problems.append(f"{sid}.{f}: A={x.get(f)!r} B={y.get(f)!r}")
                print(f"     {f}: A={x.get(f)!r}  B={y.get(f)!r}")
        else:
            same += 1
            print(f"一致 {sid[:8]} {x['name']} tx={x['txCount']} "
                  f"fp={str(x['fingerprint'])[:12]} sum={x['balance']}")
    total = len(set(ma) & set(mb))
    print(f"\n完全一致账本数: {same}/{total}")

    print("\n-- 快照 payload 逐字节比对（忽略 exportedAt）--")
    pa, pb = _payloads(dir_a), _payloads(dir_b)
    names = sorted(set(pa) | set(pb))
    byte_same = 0
    for n in names:
        if n not in pa or n not in pb:
            problems.append(f"payload 缺失: {n}")
            print(f"缺失 {n}")
            continue
        ja, jb = dict(pa[n]), dict(pb[n])
        ja.pop("exportedAt", None)
        jb.pop("exportedAt", None)
        if ja == jb:
            byte_same += 1
            print(f"一致 {n} ({len(ja['items'])} 笔)")
            continue
        print(f"差异 {n}")
        for k in sorted(set(ja) | set(jb)):
            if ja.get(k) == jb.get(k):
                continue
            va, vb = ja.get(k), jb.get(k)
            sa = f"{len(va)} 项" if isinstance(va, (list, dict)) else repr(va)[:60]
            sb = f"{len(vb)} 项" if isinstance(vb, (list, dict)) else repr(vb)[:60]
            problems.append(f"{n} 顶层键 {k}: A={sa} B={sb}")
            print(f"     顶层键 {k}: A={sa} B={sb}")
        # items 逐字段定位（指纹相同但字节不同时，差异就在 items 里）
        ia, ib = ja.get("items", []), jb.get("items", [])
        for i in range(min(len(ia), len(ib))):
            for k in sorted(set(ia[i]) | set(ib[i])):
                if ia[i].get(k) != ib[i].get(k):
                    problems.append(
                        f"{n} items[{i}]({ia[i].get('syncId')}).{k}: "
                        f"A={ia[i].get(k)!r} B={ib[i].get(k)!r}")
        if len(ia) != len(ib):
            problems.append(f"{n} items 数量: A={len(ia)} B={len(ib)}")
    print(f"payload 完全一致: {byte_same}/{len(names)}")
    return (not problems, problems)


def coverage(dirs, required):
    """判据 2：字段覆盖度门禁。**每一端**都必须对每个要求有实测证据。"""
    problems = []
    for d in dirs:
        pa = _payloads(d)
        if not pa:
            problems.append(f"{d} 无 payload（先跑 dump + pull）")
            continue
        # 每端分别统计：该端的快照里各要求命中多少条
        hits = {k: 0 for k in required}
        for payload in pa.values():
            base = payload.get("currency") or "CNY"
            for it in payload.get("items", []):
                for k in required:
                    if COVERAGE_CATALOG[k][1](it, base):
                        hits[k] += 1
        print(f"\n== {d} ==")
        for k in required:
            ok = hits[k] > 0
            if not ok:
                problems.append(f"{d} 未覆盖字段: {k}（{COVERAGE_CATALOG[k][0]}）")
            print(f"{'OK  ' if ok else 'FAIL'} {k:<22} 命中={hits[k]:<6} "
                  f"{COVERAGE_CATALOG[k][0]}")
    return (not problems, problems)


def delegate_db(path_a, path_b, label):
    """判据 3：委派 DB 级契约比对（单一事实源，不重实现）。"""
    if not os.path.isfile(DB_COMPARATOR):
        print(f"[db] 找不到 {DB_COMPARATOR}", file=sys.stderr)
        return (False, ["db 比对器缺失"])
    cmd = [sys.executable, DB_COMPARATOR, path_a, path_b]
    if label:
        cmd += ["--label", label]
    print("[db] " + " ".join(cmd))
    rc = subprocess.call(cmd)
    # compare_sync_final.py 的退出码语义：0 通过 / 1 有差异 / 3 契约校验不通过
    return (rc == 0, [] if rc == 0 else [f"db 比对退出码 {rc}"])


def _resolve_required(arg):
    if not arg:
        return list(COVERAGE_PROFILES["standard"])
    if arg in COVERAGE_PROFILES:
        return list(COVERAGE_PROFILES[arg])
    names = [x.strip() for x in arg.split(",") if x.strip()]
    bad = [n for n in names if n not in COVERAGE_CATALOG]
    if bad:
        raise SystemExit(f"未知覆盖要求: {bad}；可选: "
                         f"{sorted(COVERAGE_CATALOG)}，档位: {sorted(COVERAGE_PROFILES)}")
    return names


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--require", default=None)
    ap.add_argument("--label", default=None)
    ns = ap.parse_args(argv)

    if ns.cmd == "pull":
        pull(ns.args[0], ns.args[1])
        return 0
    if ns.cmd == "compare":
        ok, probs = compare(ns.args[0], ns.args[1])
        print("\n判据 1（载荷字节级对称性）: " + ("PASS" if ok else "FAIL"))
        for p in probs[:40]:
            print("  - " + p)
        return 0 if ok else 1
    if ns.cmd == "coverage":
        required = _resolve_required(ns.require)
        ok, probs = coverage(ns.args, required)
        print("\n判据 2（字段覆盖度）: " + ("PASS" if ok else "FAIL"))
        for p in probs:
            print("  - " + p)
        return 0 if ok else 1
    if ns.cmd == "all":
        if len(ns.args) < 2:
            raise SystemExit("用法: all <dirA> <dirB> [--require PROFILE]")
        required = _resolve_required(ns.require)
        ok1, p1 = compare(ns.args[0], ns.args[1])
        ok2, p2 = coverage(ns.args, required)
        print("\n" + "=" * 78)
        print(f"判据 1（载荷字节级对称性）: {'PASS' if ok1 else 'FAIL'}")
        print(f"判据 2（字段覆盖度 {required}）: {'PASS' if ok2 else 'FAIL'}")
        for p in (p1 + p2)[:40]:
            print("  - " + p)
        print("=" * 78)
        print("总判定: " + ("PASS" if (ok1 and ok2) else "FAIL"))
        return 0 if (ok1 and ok2) else 1
    if ns.cmd == "db":
        ok, probs = delegate_db(ns.args[0], ns.args[1], ns.label)
        print("\n判据 3（DB 级契约比对）: " + ("PASS" if ok else "FAIL"))
        return 0 if ok else 1
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
