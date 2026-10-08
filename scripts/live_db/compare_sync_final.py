# -*- coding: utf-8 -*-
"""S3/WebDAV 同步测试——两端 DB 一致性对比（v4，SPEC 声明 + 实现派生双向校验）。

用法:
  python compare_sync_final.py <A.sqlite> <B.sqlite> [--label S3|WebDAV]
  python compare_sync_final.py --spec        # 只打印比对字段清单（由 SPEC 生成）

【防漂设计：声明 + 派生，双向校验】
  v2 曾出现「docstring 声称比对某列、生效实现却漏比该列（另有一份 SELECT 了该列
  但从未被调用的死函数）」的漂移缺陷。v3 把「运行时清单」与 `--spec` 都改为由
  `SPEC` 生成，消除了 docstring 手写漂移；但**SPEC 自身**仍可能与 `lib/cloud`
  实现脱节（实测：SPEC 把 `tag_sync_ids_override` 列为契约内，而 `lib/cloud/**`
  对它零引用 —— 造数必然假失败）。

  v4 因此再加一层：`_derive_cloud_contract()` 直接从 Dart 实现**派生**「真的会被
  跨设备搬运」的快照键集合：
    * 导出端 `lib/cloud/transactions_json.dart` 的事务 item 字面量（大括号配平截取）
      ＋ 其后按分支赋值的 `item['k'] = …`（账户名/标签只在特定分支写）
    * 指纹白名单 `lib/cloud/sync_fingerprint.dart` 的事务段 return map（配平截取）
    * 解析端 `lib/cloud/transactions_json.dart` 的 `_readXxx(m, 'key')` / `m['key']`
      （注意不是 `data_import_service.dart` —— 它只消费已解析的 ImportTransaction）
  三处取**交集**即「导出 + 能判差异 + 能读回」的充要字段集。随后对 SPEC 做三向校验，
  任一不满足即以退出码 3 中止（见 `crosscheck_contract`）：
    1. 契约内列 → 必须真被实现搬运（否则「声明会同步、其实不会」）；
    2. 契约外列 → 必须**不**被实现搬运（否则口径失效，应改列契约内）；
    3. 实现新搬运的键 → 必须已被 SPEC 覆盖（否则比对清单已漂移）。
  含义：今后任一侧（SPEC 或 Dart 实现）单独改动都会立刻报错，清单不可能再静默漂移。

【字段分三类】
  key    对齐键 —— 账本/分类/账户/标签等一律解析成 syncId 后比对
         （两端 local 自增 id 不同，绝不直接比）。
         注意**并非全部**对齐键都是 syncId：`transaction_tags` 的第三键是
         `tag_id`（归一成 tag syncId），`transaction_attachments` 的第三键是
         文件名 `file_name`（附件是内容寻址的集合，没有稳定 syncId）。
  synced 契约内字段 —— 云快照会搬运的数据。严格逐字段比对，差异计入 issues。
  local  契约外字段 —— 单列 `[OK*]` 统计差异行数，**不计入 issues、不影响退出码**。

【契约外字段的判定依据（代码级）】
  * `ledgers` 的共享账本四列与三张 `shared_ledger_*` 镜像表、`transaction_tag_overrides`：
    **已于 v51 DROP**（2026-10-08），v51 及以后的库中不存在，SPEC 不再列出；
    对旧 schema 库运行本脚本时会走「库中无此表/列」的跳过分支。
  * `transactions.created_by_user_id / last_edited_by_user_id`：`lib/cloud/**`
    零引用；本地专有列（不进快照），历史上由共享账本的「谁记的」UI 写入
    （`markTxAuthor`，现已无调用方），恢复路径只做同库搬运
    （`data_import_service` 的本地专有列回填）。
  * 各表 `created_at / updated_at`：由 v40 的 `trg_*_touch_updated_at`
    触发器按**本机写入时刻**维护（本机写时钟），天然跨设备不同。
  * `transaction_attachments.cloud_sha256 / cloud_file_id`：文件式后端不落该列。

【刻意不比 / 不比但已归一化的项】
  * `recurring_transactions.last_generated_date`：本机「生成进度」，两端天然不同
    （同 `lib/cloud/sync_fingerprint.dart` 的指纹排除口径）。
  * `exchange_rate_overrides.rate` 存 TEXT，两端可能 '9.0' vs '9'；
    `sync_fingerprint.dart` 按 `toDouble()` 归一，故这里也按**数值**比对。
  * `custom_values_json` / `tag_sync_ids_override` 为 JSON 文本，按**键序归一**后比对
    （`_json_canon`；注意 `tag_sync_ids_override` 当前实现未搬运，故列**契约外**）。

【已知覆盖面缺口（本脚本不覆盖的表）】
  * `custom_field_definitions`（v46 字段定义，属快照 `customFields` 段的数据本体、
    参与指纹与方向仲裁证据源）：本脚本 SPEC 未含该表。请以
    `scripts/live_db/run_20260927/extra_tables_check.py` 单独校验。
  * `deleted_transactions`（回收站，v44/F1）：**刻意不进快照**，属设备本地态
    （见 `lib/pages/maintenance/recycle_bin_page.dart` 顶部说明）。本脚本不把它
    当差异比对，但会**单列打印双端行数**（`[OK*]`，不计 issues、不影响退出码），
    让「exit=0」的适用范围显式可读 —— 否则极易被误读为「两端全表一致」。
    （20261004 S3/WebDAV 双后端回归即踩过这个误读，见 docs/test/ 两份报告 6.1。）

输出: 每维度 OK/FAIL + 差异样本（前 5 条），末尾一行结论。
退出码: 0 = 同步契约内字段无非预期差异（可能含契约外/设备本地差异行）；
        2 = 存在不一致；3 = SPEC/实现漂移。
        **0 只说明「同步契约内」一致**，不含回收站等设备本地表（已单列打印）。
"""
import json
import os
import re
import sqlite3
import sys
from collections import Counter

# Windows 控制台/管道下中文与 `| head` 的健壮性：统一 UTF-8 输出，
# 并在下游提前关闭管道（BrokenPipe）时安静退出，避免 OSError 22 噪声。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# ============================== 归一化器 ==============================
def _round2(x):
    return None if x is None else round(float(x), 2)


def _float(x):
    if x is None:
        return None
    try:
        return float(x)
    except (TypeError, ValueError):
        return x


def _json_canon(x):
    """JSON 文本按键序/数值表示归一（语义等价即视为一致）。"""
    if x is None or x == "":
        return None
    try:
        return json.dumps(json.loads(x), sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError):
        return x


def _fk(kind):
    """本地自增 FK -> 对端可比的 syncId（缺失则标记）。"""
    def norm(maps, v):
        if v is None:
            return None
        return maps[kind].get(v, f"<missing:{kind}:{v}>")
    return norm


NORMS = {
    None: lambda maps, v: v,
    "round2": lambda maps, v: _round2(v),
    "float": lambda maps, v: _float(v),
    "json": lambda maps, v: _json_canon(v),
}

FK_MAP_TABLES = ("accounts", "categories", "tags", "recurring_transactions")


# ====================== 契约清单：实现派生与双向校验 ======================
_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# 派生来源：三处实现（导出 / 指纹白名单 / 解析）。
# 注意「解析」与「导出」同属 transactions_json.dart（exportTransactionsJson 与
# parseJsonToImportData），而落地落到 DB 的 data_import_service.dart 只消费已解析
# 好的 ImportTransaction —— 故键集合从解析侧取。落地环节不在本自动校验范围内，
# 但「解析了却没落库」会直接表现为双端 DB 字段差异，由比对本身兜底。
CLOUD_SOURCES = {
    "export": os.path.join(_ROOT, "lib", "cloud", "transactions_json.dart"),
    "fingerprint": os.path.join(_ROOT, "lib", "cloud", "sync_fingerprint.dart"),
    "parse": os.path.join(_ROOT, "lib", "cloud", "transactions_json.dart"),
}

# transactions 列名 -> 快照键（camelCase）。
# 关系列（分类/账户/标签/周期）在快照里以「名称 + kind」或「syncId」形态传播。
# 新增云字段时必须同步本表 —— 否则 crosscheck_contract 的第 3 条会报漂移。
COL_KEYS = {
    "type": ("type",),
    "amount": ("amount",),
    "category_id": ("categoryName", "categoryKind"),
    "account_id": ("accountName", "fromAccountName"),
    "to_account_id": ("toAccountName",),
    "happened_at": ("happenedAt",),
    "note": ("note",),
    "exclude_from_stats": ("excludeFromStats",),
    "exclude_from_budget": ("excludeFromBudget",),
    "currency_code": ("currencyCode",),
    "native_amount": ("nativeAmount",),
    "original_amount": ("originalAmount",),
    "custom_values_json": ("customValues",),
    "recurring_id": ("recurringSyncId",),
    # 以下为契约外列，保留映射以便校验「实现是否偷偷开始搬运」
    "created_by_user_id": ("createdByUserId",),
    "last_edited_by_user_id": ("lastEditedByUserId",),
    "updated_at": ("updatedAt",),
}

# 快照里非「列」的派生/关系键，不要求 SPEC 逐列覆盖。
NON_COLUMN_KEYS = {
    "syncId", "id", "attachments",
    "categoryName", "categoryKind",
    "tags", "tagNames", "tagSyncIds",
    "accountName", "fromAccountName", "toAccountName",
    "recurringSyncId",
}


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def _balanced(src, anchor):
    """从 anchor 所在位置起，截取一个大括号配平块（含花括号）。"""
    i = src.index(anchor)
    j = src.index("{", i)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[j:k + 1]
    raise ValueError(f"大括号不配平: {anchor!r}")


def _map_keys(block):
    return set(re.findall(r"'([A-Za-z_][A-Za-z0-9_]*)'\s*:", block))


def _derive_cloud_contract():
    """从 Dart 实现派生「真的被跨设备搬运」的快照键（三环节各一份）。"""
    src = {k: _read(p) for k, p in CLOUD_SOURCES.items()}

    exp_src = src["export"]
    # 事务 item 的键有两个来源：① `<String, dynamic>{...}` 字面量里的 `'k':`；
    # ② 字面量之后的条件赋值 `item['k'] = ...`（账户名/标签等，仅特定分支写入）。
    # 两者都要收集，否则会把"只在转账分支写的 fromAccountName"误判为未搬运。
    export = _map_keys(_balanced(exp_src, "final item = <String, dynamic>{"))
    export |= set(re.findall(r"item\['([A-Za-z_][A-Za-z0-9_]*)'\]", exp_src))

    fp = src["fingerprint"]
    i = fp.index("'happenedAt': it[")          # 事务段的锚点
    fp_block = _balanced(fp[fp.rindex("return {", 0, i):], "return {")
    fingerprint = _map_keys(fp_block)

    # 解析侧：parseJsonToImportData 里的 `_readXxx(m, 'k')` 与 `m['k']`。
    # 该文件同时解析账户/分类/标签/预算/周期等实体，交集会把非交易项滤掉。
    parse_src = src["parse"]
    parse = set(re.findall(
        r"_read\w*\(\s*m\s*,\s*'([A-Za-z_][A-Za-z0-9_]*)'", parse_src))
    parse |= set(re.findall(r"m\['([A-Za-z_][A-Za-z0-9_]*)'\]", parse_src))

    return {"export": export, "fingerprint": fingerprint, "parse": parse}


def crosscheck_contract():
    """SPEC 声明 vs lib/cloud 实现：双向校验，漂移即退出 3。"""
    missing = [p for p in CLOUD_SOURCES.values() if not os.path.exists(p)]
    if missing:
        print("[DRIFT-SKIP] 未找到实现源码，跳过契约派生校验（建议在仓库内运行）：")
        for p in missing:
            print("   -", p)
        return

    derived = _derive_cloud_contract()
    # 三环节取交集：导出 + 能判差异（指纹）+ 能读回（解析）
    transported = derived["export"] & derived["fingerprint"] & derived["parse"]

    spec = next(s for s in SPEC if s.table == "transactions")
    synced = {e.split(".")[-1]: lab for lab, e, _ in spec.fields}
    local = {e.split(".")[-1]: lab for lab, e, _ in spec.local_fields}

    problems = []
    # 1) 契约内列必须真被实现搬运
    for col, lab in synced.items():
        keys = COL_KEYS.get(col)
        if not keys:
            problems.append(f"契约内 {lab}({col}) 在 COL_KEYS 别名表里无映射 "
                            f"—— 新增云字段时必须同步别名表")
            continue
        miss = [k for k in keys if k not in transported]
        if miss:
            problems.append(
                f"契约内 {lab}({col}) 声明会被同步，但实现未搬运 {miss}"
                f"（export ∩ fingerprint ∩ import）")
    # 2) 契约外列不应被实现搬运
    for col, lab in local.items():
        keys = COL_KEYS.get(col)
        if keys and all(k in transported for k in keys):
            problems.append(
                f"契约外 {lab}({col}) 其实已被实现搬运 —— 契约外口径失效，"
                f"应改列契约内（否则该列差异被静默豁免）")
    # 3) 实现搬运的键必须已被 SPEC 覆盖
    covered = set()
    for col in list(synced) + list(local):
        covered.update(COL_KEYS.get(col, ()))
    for k in sorted(transported):
        if k in NON_COLUMN_KEYS or k in covered:
            continue
        problems.append(f"实现搬运了快照键 {k!r}，但 SPEC 既未列契约内也未列契约外 "
                        f"—— 比对清单已漂移")

    if problems:
        print("[DRIFT] 比对契约清单与 lib/cloud 实现不一致（请修正 SPEC/别名表）：")
        for p in problems:
            print("   -", p)
        sys.exit(3)
    print(f"[契约派生校验] OK —— 实现搬运 {len(transported)} 个快照键，"
          f"与 SPEC 声明一致（export={len(derived['export'])} "
          f"fingerprint={len(derived['fingerprint'])} parse={len(derived['parse'])}）")
    return derived


# ============================== SPEC 定义 ==============================
class Spec:
    """一张对表。field = (显示名, SQL 表达式, 归一化器)。"""

    def __init__(self, table, from_sql, keys, fields=(), local_fields=(),
                 line_tpl=None):
        self.table = table
        self.from_sql = from_sql
        self.keys = keys                 # [(名, 表达式, norm)]
        self.fields = list(fields)       # 契约内
        self.local_fields = list(local_fields)   # 契约外
        self.line_tpl = line_tpl

    @property
    def field_labels(self):
        return ", ".join(n for n, _, _ in self.fields)

    @property
    def local_labels(self):
        return ", ".join(n for n, _, _ in self.local_fields)


SPEC = [
    Spec("ledgers", "ledgers",
         keys=[("sync_id", "sync_id", None)],
         fields=[("name", "name", None), ("currency", "currency", None),
                 ("type", "type", None), ("month_start_day", "month_start_day", None)],
         local_fields=[("created_at", "created_at", None),
                       ("updated_at", "updated_at", None)],
         line_tpl="ledgers 同步字段({fields}) 一致（{n}个账本）"),

    Spec("accounts", "accounts",
         keys=[("sync_id", "sync_id", None)],
         fields=[("name", "name", None), ("type", "type", None),
                 ("currency", "currency", None),
                 ("initial_balance", "initial_balance", "round2"),
                 ("sort_order", "sort_order", None),
                 ("credit_limit", "credit_limit", "round2"),
                 ("billing_day", "billing_day", None),
                 ("payment_due_day", "payment_due_day", None),
                 ("bank_name", "bank_name", None),
                 ("card_last_four", "card_last_four", None),
                 ("note", "note", None), ("hidden", "hidden", None)],
         local_fields=[("created_at", "created_at", None),
                       ("updated_at", "updated_at", None)],
         line_tpl="accounts 字段 一致（{n}个账户）"),

    Spec("categories", "categories",
         keys=[("sync_id", "sync_id", None)],
         fields=[("name", "name", None), ("kind", "kind", None),
                 ("level", "level", None),
                 ("parent", "parent_id", _fk("categories")),
                 ("sort_order", "sort_order", None), ("icon", "icon", None)],
         local_fields=[("updated_at", "updated_at", None)],   # 该表无 created_at 列
         line_tpl="categories 字段 一致（{n}个分类, 父分类按syncId归一）"),

    Spec("tags", "tags",
         keys=[("sync_id", "sync_id", None)],
         fields=[("name", "name", None), ("color", "color", None),
                 ("sort_order", "sort_order", None)],
         local_fields=[("created_at", "created_at", None),
                       ("updated_at", "updated_at", None)],
         line_tpl="tags 字段 一致（{n}个标签）"),

    Spec("transactions", "transactions t JOIN ledgers l ON t.ledger_id = l.id",
         keys=[("ledger", "l.sync_id", None), ("sync_id", "t.sync_id", None)],
         fields=[("type", "t.type", None), ("amount", "t.amount", "round2"),
                 # 关系列：快照以 (categoryKind, categoryName) / 账户名 / tag syncId
                 # 形态搬运，这里按同样的可跨设备口径归一后比对
                 ("category", "t.category_id", _fk("categories")),
                 ("account", "t.account_id", _fk("accounts")),
                 ("to_account", "t.to_account_id", _fk("accounts")),
                 ("happened_at", "t.happened_at", None), ("note", "t.note", None),
                 ("exclude_from_stats", "t.exclude_from_stats", None),
                 ("exclude_from_budget", "t.exclude_from_budget", None),
                 ("currency_code", "t.currency_code", None),
                 ("native_amount", "t.native_amount", "round2"),
                 # v45/v46：均在云快照与指纹白名单内，必须比
                 ("original_amount", "t.original_amount", "round2"),
                 ("custom_values_json", "t.custom_values_json", "json"),
                 # 共享账本 override：JSON 显式携带时参与 diff/合并
                 ("category_sync_id_override", "t.category_sync_id_override", None),
                 ("account_sync_id_override", "t.account_sync_id_override", None),
                 ("to_account_sync_id_override", "t.to_account_sync_id_override", None),
                 # v8 G2：周期规则锚点在快照里以 recurringSyncId 传播，且已进指纹
                 ("recurring", "t.recurring_id", _fk("recurring_transactions"))],
         local_fields=[("created_by_user_id", "t.created_by_user_id", None),
                       ("last_edited_by_user_id", "t.last_edited_by_user_id", None),
                       ("updated_at", "t.updated_at", None),
                       # lib/cloud/** 零引用：导出/指纹/导入三处都没有它
                       # （比对脚本 v3 曾误列契约内，造数必然假失败）
                       ("tag_sync_ids_override", "t.tag_sync_ids_override", "json")],
         line_tpl="transactions 逐字段 比对（{n}笔共同行） 仅A={only_a} 仅B={only_b} 字段差异={fdiff}"),

    Spec("budgets", "budgets b JOIN ledgers l ON b.ledger_id = l.id",
         keys=[("ledger", "l.sync_id", None), ("sync_id", "b.sync_id", None)],
         fields=[("type", "b.type", None),
                 ("category", "b.category_id", _fk("categories")),
                 ("amount", "b.amount", "round2"), ("period", "b.period", None),
                 ("start_day", "b.start_day", None), ("enabled", "b.enabled", None)],
         local_fields=[("created_at", "b.created_at", None),
                       ("updated_at", "b.updated_at", None)],
         line_tpl="budgets 一致（A={na} B={nb}）"),

    Spec("recurring_transactions",
         "recurring_transactions rc JOIN ledgers l ON rc.ledger_id = l.id",
         keys=[("ledger", "l.sync_id", None), ("sync_id", "rc.sync_id", None)],
         fields=[("type", "rc.type", None), ("amount", "rc.amount", "round2"),
                 ("category", "rc.category_id", _fk("categories")),
                 ("account", "rc.account_id", _fk("accounts")),
                 ("to_account", "rc.to_account_id", _fk("accounts")),
                 ("note", "rc.note", None), ("frequency", "rc.frequency", None),
                 ("interval", "rc.interval", None),
                 ("day_of_month", "rc.day_of_month", None),
                 ("day_of_week", "rc.day_of_week", None),
                 ("month_of_year", "rc.month_of_year", None),
                 ("start_date", "rc.start_date", None),
                 ("end_date", "rc.end_date", None),
                 ("enabled", "rc.enabled", None),
                 ("currency_code", "rc.currency_code", None),
                 ("template_field_values", "rc.template_field_values", "json"),
                 # last_generated_date 刻意不比：本机生成进度（见文件头）
                 ],
         local_fields=[("created_at", "rc.created_at", None),
                       ("updated_at", "rc.updated_at", None)],
         line_tpl="recurring_transactions 一致（A={na} B={nb}）"),

    Spec("exchange_rate_overrides", "exchange_rate_overrides",
         keys=[("sync_id", "sync_id", None)],
         fields=[("base", "base_currency", None), ("quote", "quote_currency", None),
                 ("rate", "rate", "float")],
         local_fields=[("updated_at", "updated_at", None)],
         line_tpl="exchange_rate_overrides 一致（{n}条）"),

    Spec("transaction_tags",
         "transaction_tags tt JOIN transactions t ON tt.transaction_id = t.id",
         keys=[("tx", "t.sync_id", None), ("tag", "tt.tag_id", _fk("tags"))],
         fields=[],
         line_tpl="transaction_tags 一致（A={na} B={nb}）"),

    Spec("transaction_attachments",
         "transaction_attachments a JOIN transactions t ON a.transaction_id = t.id "
         "JOIN ledgers l ON t.ledger_id = l.id",
         keys=[("ledger", "l.sync_id", None), ("tx", "t.sync_id", None),
               ("file_name", "a.file_name", None)],
         fields=[("original_name", "a.original_name", None),
                 ("file_size", "a.file_size", None),
                 ("width", "a.width", None), ("height", "a.height", None),
                 ("sort_order", "a.sort_order", None),
                 ("local_sha256", "a.local_sha256", None)],
         local_fields=[("cloud_file_id", "a.cloud_file_id", None),
                       ("cloud_sha256", "a.cloud_sha256", None),
                       ("created_at", "a.created_at", None)],
         line_tpl="transaction_attachments 一致（A={na} B={nb}）"),
]


# ============ 设计内不同步的表（单列统计，不计 issues、不影响退出码） ============
# 「exit=0」的正确含义是【同步契约内字段无差异】，**不等于**「两端数据完全相同」。
# 下面这些表刻意不进快照（设备本地态），双端天然可以不同。把它们单列出来，
# 是为了让那句结论的适用范围显式可读，而不是让用户把 exit=0 误读成全表一致
# —— 20261004 S3/WebDAV 双后端回归正是栽在这个误读上（docs/test/ 报告 6.1）。
DEVICE_LOCAL_TABLES = {
    "deleted_transactions": (
        "回收站（v44/F1）只在本机：归档行进的是本地 deleted_transactions 表、"
        "不进快照，所以它既不上云也不进备份。A 端删的记录不会出现在 B 端回收站，"
        "属设计行为（见 lib/pages/maintenance/recycle_bin_page.dart 顶部说明）。"),
}


# ============================== 引擎 ==============================
def parse_tables(from_sql):
    """'transactions t JOIN ledgers l ON ...' -> {'t': 'transactions', 'l': 'ledgers'}"""
    out = {}
    for chunk in from_sql.split(" JOIN "):
        head = chunk.split(" ON ")[0].strip().split()
        if len(head) == 1:
            out[""] = head[0]
        elif len(head) >= 2:
            out[head[1]] = head[0]
    return out


def validate_spec(cur):
    """把 SPEC 的每个列名对着真实 schema 校验 —— 表结构变了会立刻显式报错，
    而不是产出一份「看起来比了、其实漏比」的结果。"""
    bad = []
    for s in SPEC:
        tables = parse_tables(s.from_sql)
        cols = {t: {r[1] for r in cur.execute(f"PRAGMA table_info({t})")}
                for t in set(tables.values())}
        for label, expr, _ in list(s.keys) + list(s.fields) + list(s.local_fields):
            alias = expr.split(".")[0] if "." in expr else ""
            col = expr.split(".")[-1]
            table = tables.get(alias)
            if table is None or col not in cols.get(table, set()):
                bad.append(f"{s.table}.{label} -> {expr}（{table} 无此列）")
    if bad:
        print("[SPEC-ERROR] SPEC 与数据库 schema 不一致（请修正 SPEC，勿让比对静默漏列）:")
        for b in bad:
            print("   -", b)
        sys.exit(3)


def fk_maps(cur):
    maps = {}
    for t in FK_MAP_TABLES:
        maps[t] = {r[0]: r[1] for r in cur.execute(f"SELECT id, sync_id FROM {t}")}
    return maps


def norm_value(maps, kind, v):
    fn = NORMS[kind] if kind in NORMS else kind
    return fn(maps, v) if callable(fn) else v


def build(cur, spec):
    """-> {key_tuple: (synced_tuple, local_tuple)}"""
    exprs = [e for _, e, _ in spec.keys] + [e for _, e, _ in spec.fields] \
        + [e for _, e, _ in spec.local_fields]
    sql = "SELECT " + ", ".join(exprs) + " FROM " + spec.from_sql
    maps = fk_maps(cur)
    nk = len(spec.keys)
    out = {}
    for row in cur.execute(sql):
        key = tuple(row[:nk])
        i = nk
        vals = []
        for _, _, kind in spec.fields:
            vals.append(norm_value(maps, kind, row[i])); i += 1
        lvals = []
        for _, _, kind in spec.local_fields:
            lvals.append(norm_value(maps, kind, row[i])); i += 1
        out[key] = (tuple(vals), tuple(lvals))
    return out


def fmt_key(key):
    return " / ".join(str(k)[:8] for k in key)


def report_device_local(qa, qb):
    """打印「设计内不参与同步」的表在双端的行数（单列 `[OK*]`）。

    只做可见性统计：**不计入 issues、不影响退出码**。表不存在（旧 schema）
    时安静跳过，不视为错误 —— 这是可读性补充，不是门禁。
    """
    for tbl, note in DEVICE_LOCAL_TABLES.items():
        counts = {}
        for tag, cur in (("A", qa), ("B", qb)):
            try:
                counts[tag] = cur.execute(
                    f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
            except sqlite3.OperationalError:
                counts[tag] = None            # 旧库无此表
        a, b = counts["A"], counts["B"]
        if a is None or b is None:
            print(f"  [OK*] {tbl:26s} 库中无此表（旧 schema？），跳过")
        else:
            print(f"  [OK*] {tbl:26s} A={a:<6} B={b:<6} "
                  f"—— 设备本地态，设计内不同步，两端不同属预期")
        print(f"       {note}")


def print_spec(with_evidence=None):
    print("===== 比对字段清单（由 SPEC 生成）=====")
    for s in SPEC:
        keys = ", ".join(n for n, _, _ in s.keys)
        print(f"  {s.table}  [键: {keys}]")
        print(f"        契约内: {s.field_labels or '（无，仅比对键集合）'}")
        if s.local_labels:
            print(f"        契约外: {s.local_labels}")
    print("\n--- 设计内不参与同步（设备本地表，不计入 issues、不影响退出码）---")
    for tbl in DEVICE_LOCAL_TABLES:
        print(f"  [OK*] {tbl}")
    if with_evidence:
        transported = with_evidence["export"] & with_evidence["fingerprint"] \
            & with_evidence["parse"]
        print("\n--- transactions 契约内字段的实现证据（派生自 lib/cloud）---")
        spec = next(s for s in SPEC if s.table == "transactions")
        for lab, expr, _ in spec.fields:
            ks = COL_KEYS.get(expr.split(".")[-1], ())
            mark = "OK" if all(k in transported for k in ks) else "!!"
            print(f"  [{mark}] {lab:28s} 快照键={list(ks)}")


def main():
    argv = sys.argv[1:]
    if "--spec" in argv:
        try:
            print_spec(with_evidence=_derive_cloud_contract())
        except Exception as e:                                   # noqa: BLE001
            print(f"[DRIFT-SKIP] 无法派生实现证据：{e}")
            print_spec()
        return

    a_path, b_path = argv[0], argv[1]
    label = "S3"
    if "--label" in argv:
        label = argv[argv.index("--label") + 1]

    ca, cb = sqlite3.connect(a_path), sqlite3.connect(b_path)
    qa, qb = ca.cursor(), cb.cursor()
    # 两道校验：① SPEC 与真实 schema 一致；② SPEC 与 lib/cloud 实现一致。
    # 任一不过都以退出码 3 中止 —— 绝不产出一份「看起来比了、其实漏比」的结果。
    validate_spec(qa)
    crosscheck_contract()

    issues = []
    local_rows = Counter()          # table -> 契约外差异行数

    print(f"===== {label} 同步一致性对比 =====")
    print(f"A = {a_path}")
    print(f"B = {b_path}\n")
    print("--- 比对字段清单（由 SPEC 自动生成，--spec 可单独查看）---")
    for s in SPEC:
        keys = ", ".join(n for n, _, _ in s.keys)
        print(f"  {s.table:26s} [键: {keys}]")
        print(f"      契约内: {s.field_labels or '（无，仅比对键集合）'}")
        if s.local_labels:
            print(f"      契约外: {s.local_labels}")
    print()

    for s in SPEC:
        ra, rb = build(qa, s), build(qb, s)
        only_a, only_b = set(ra) - set(rb), set(rb) - set(ra)
        na, nb = len(ra), len(rb)   # 键唯一（sync_id 有唯一索引），dict 大小即行数
        fdiff = [k for k in ra if k in rb and ra[k][0] != rb[k][0]]
        ldiff = Counter()
        for k in ra:
            if k not in rb:
                continue
            for i, (lab, _, _) in enumerate(s.local_fields):
                if ra[k][1][i] != rb[k][1][i]:
                    ldiff[lab] += 1

        ok = not only_a and not only_b and not fdiff
        print(f"  [{'OK' if ok else '!!'}] {s.table:26s} A={na:<6} B={nb:<6} "
              f"仅A={len(only_a)} 仅B={len(only_b)}")

        n = len(set(ra) & set(rb))
        tpl = s.line_tpl or "{table} 一致（A={na} B={nb}）"
        line = tpl.format(table=s.table, n=n, na=na, nb=nb,
                          only_a=len(only_a), only_b=len(only_b),
                          fdiff=len(fdiff), fields=s.field_labels)
        print(f"  [{'OK' if ok else '!!'}] {line}")
        if not ok:
            issues.append(f"{s.table}: 行数或键集合不一致 "
                          f"(A={na}, B={nb}, 仅A={len(only_a)}, 仅B={len(only_b)})"
                          if (only_a or only_b) else
                          f"{s.table} 字段不一致: {len(fdiff)} 项")
            for k in fdiff[:5]:
                print(f"       {fmt_key(k)}: A={ra[k][0]}\n{' ' * 20}B={rb[k][0]}")
            for k in list(only_a)[:5]:
                print(f"       仅A: {fmt_key(k)}")
            for k in list(only_b)[:5]:
                print(f"       仅B: {fmt_key(k)}")

        rows_diff = [k for k in ra if k in rb and ra[k][1] != rb[k][1]]
        if ldiff:
            local_rows[s.table] = len(rows_diff)
            det = ", ".join(f"{lab}={cnt}" for lab, cnt in ldiff.most_common())
            if s.table == "ledgers":
                print(f"  [OK*] ledgers 设备本地字段({s.local_labels}) 差异 "
                      f"{len(rows_diff)} 个 —— 契约外字段，预期差异，不计入不一致")
                print(f"       （按列统计：{det}）")
                for k in rows_diff[:5]:
                    print(f"       {k[0][:8]} A={ra[k][1]} vs B={rb[k][1]}")
            else:
                print(f"  [OK*] {s.table} 契约外字段差异 {len(rows_diff)} 行 "
                      f"—— 预期差异，不计入不一致")
                print(f"       （按列统计：{det}）")

    # 设备本地表：不在 SPEC 内（比不出差异也不该比），单列行数让「一致」的范围可见。
    print("\n--- 设计内不参与同步（设备本地态；不计入不一致）---")
    report_device_local(qa, qb)

    if not issues and not local_rows:
        verdict = "完全一致（限同步契约内字段）"
    elif not issues:
        verdict = (f"无非预期差异（另有 {sum(local_rows.values())} 行契约外字段差异，"
                   f"涉及 {len(local_rows)} 张表，属预期；结论限同步契约内字段）")
    else:
        verdict = f"存在 {len(issues)} 类不一致"
    print(f"\n===== 结论: {verdict} =====")
    for i in issues:
        print("  -", i)
    ca.close(); cb.close()
    sys.exit(0 if not issues else 2)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:            # 下游 `| head` 提前退出
        try:
            sys.stdout.close()
        finally:
            sys.exit(0)
