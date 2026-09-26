# -*- coding: utf-8 -*-
"""S3/WebDAV 同步测试——两端 DB 一致性对比（v3，SPEC 驱动）。

用法:
  python compare_sync_final.py <A.sqlite> <B.sqlite> [--label S3|WebDAV]
  python compare_sync_final.py --spec        # 只打印比对字段清单（由 SPEC 自动生成）

【单一事实来源】本文件末尾的 `SPEC`。运行时打印的「比对字段清单」与 `--spec`
输出**都由 SPEC 生成**，不依赖 docstring 手写 —— v2 曾出现「docstring 声称比对
transactions.created_by、生效实现却漏比该列（另有一份 SELECT 了该列但未被调用的
死函数）」的漂移缺陷，v3 从结构上消除该可能。

【字段分三类】
  key    对齐键 —— 一律解析成 syncId。两端 local 自增 id 不同，绝不直接比。
  synced 契约内字段 —— 云快照会搬运的数据。严格逐字段比对，差异计入 issues。
  local  契约外字段 —— 单列 `[OK*]` 统计差异行数，**不计入 issues、不影响退出码**。

【契约外字段的判定依据（代码级）】
  * `ledgers.is_shared / member_count / owner_user_id`、表 `ledger_members`：
    `lib/cloud/**` 零引用；`lib/data/db.dart:515` 注明 ledger_members 是
    「server 端 LedgerMember 表的本地副本」，不参与文件式（S3/WebDAV）云同步。
  * `transactions.created_by_user_id / last_edited_by_user_id`：
    `lib/cloud/**` 零引用；且全库既无写入方（`markTxAuthor` 只有定义、无调用方）
    也无读取方，属共享账本场景的预留字段。
  * 各表 `created_at / updated_at`：由 v40 的 `trg_*_touch_updated_at`
    触发器按**本机写入时刻**维护（本机写时钟），天然跨设备不同。
  * `transaction_attachments.cloud_sha256 / cloud_file_id`：文件式后端不落该列。

【刻意不比 / 不比但已归一化的项】
  * `recurring_transactions.last_generated_date`：本机「生成进度」，两端天然不同
    （同 `lib/cloud/sync_fingerprint.dart` 的指纹排除口径）。
  * `exchange_rate_overrides.rate` 存 TEXT，两端可能 '9.0' vs '9'；
    `sync_fingerprint.dart:363-367` 按 `toDouble()` 归一，故这里也按**数值**比对。
  * `custom_values_json` / `tag_sync_ids_override` 为 JSON 文本，按**键序归一**后比对。

输出: 每维度 OK/FAIL + 差异样本（前 5 条），末尾一行结论。
退出码: 0 = 无非预期差异（可能含契约外差异行），2 = 存在不一致。
"""
import json
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


# ============================== SPEC 定义 ==============================
class Spec:
    """一张对表。field = (显示名, SQL 表达式, 归一化器)。"""

    def __init__(self, table, from_sql, keys, fields=(), local_fields=(),
                 noun="项", line_tpl=None):
        self.table = table
        self.from_sql = from_sql
        self.keys = keys                 # [(名, 表达式, norm)]
        self.fields = list(fields)       # 契约内
        self.local_fields = list(local_fields)   # 契约外
        self.noun = noun
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
                 ("type", "type", None), ("month_start_day", "month_start_day", None),
                 ("my_role", "my_role", None)],
         local_fields=[("is_shared", "is_shared", None),
                       ("member_count", "member_count", None),
                       ("owner_user_id", "owner_user_id", None),
                       ("created_at", "created_at", None),
                       ("updated_at", "updated_at", None)],
         noun="个账本",
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
         noun="个账户",
         line_tpl="accounts 字段 一致（{n}个账户）"),

    Spec("categories", "categories",
         keys=[("sync_id", "sync_id", None)],
         fields=[("name", "name", None), ("kind", "kind", None),
                 ("level", "level", None),
                 ("parent", "parent_id", _fk("categories")),
                 ("sort_order", "sort_order", None), ("icon", "icon", None)],
         local_fields=[("updated_at", "updated_at", None)],   # 该表无 created_at 列
         noun="个分类",
         line_tpl="categories 字段 一致（{n}个分类, 父分类按syncId归一）"),

    Spec("tags", "tags",
         keys=[("sync_id", "sync_id", None)],
         fields=[("name", "name", None), ("color", "color", None),
                 ("sort_order", "sort_order", None)],
         local_fields=[("created_at", "created_at", None),
                       ("updated_at", "updated_at", None)],
         noun="个标签",
         line_tpl="tags 字段 一致（{n}个标签）"),

    Spec("transactions", "transactions t JOIN ledgers l ON t.ledger_id = l.id",
         keys=[("ledger", "l.sync_id", None), ("sync_id", "t.sync_id", None)],
         fields=[("type", "t.type", None), ("amount", "t.amount", "round2"),
                 ("category", "t.category_id", _fk("categories")),
                 ("account", "t.account_id", _fk("accounts")),
                 ("to_account", "t.to_account_id", _fk("accounts")),
                 ("happened_at", "t.happened_at", None), ("note", "t.note", None),
                 ("exclude_from_stats", "t.exclude_from_stats", None),
                 ("exclude_from_budget", "t.exclude_from_budget", None),
                 ("currency_code", "t.currency_code", None),
                 ("native_amount", "t.native_amount", "round2"),
                 # v45/v46：两者都在云快照与指纹白名单内，必须比
                 ("original_amount", "t.original_amount", "round2"),
                 ("custom_values_json", "t.custom_values_json", "json"),
                 # 共享账本 override：JSON 显式携带时参与 diff/合并
                 ("category_sync_id_override", "t.category_sync_id_override", None),
                 ("account_sync_id_override", "t.account_sync_id_override", None),
                 ("to_account_sync_id_override", "t.to_account_sync_id_override", None),
                 ("tag_sync_ids_override", "t.tag_sync_ids_override", "json")],
         local_fields=[("created_by_user_id", "t.created_by_user_id", None),
                       ("last_edited_by_user_id", "t.last_edited_by_user_id", None),
                       ("updated_at", "t.updated_at", None)],
         noun="笔",
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
         noun="条",
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


def main():
    argv = sys.argv[1:]
    if "--spec" in argv:
        print("===== 比对字段清单（由 SPEC 自动生成）=====")
        for s in SPEC:
            keys = ", ".join(n for n, _, _ in s.keys)
            print(f"  {s.table}  [键: {keys}]")
            print(f"        契约内: {s.field_labels or '（无，仅比对键集合）'}")
            if s.local_labels:
                print(f"        契约外: {s.local_labels}")
        return

    a_path, b_path = argv[0], argv[1]
    label = "S3"
    if "--label" in argv:
        label = argv[argv.index("--label") + 1]

    ca, cb = sqlite3.connect(a_path), sqlite3.connect(b_path)
    qa, qb = ca.cursor(), cb.cursor()
    validate_spec(qa)              # SPEC 必须与真实 schema 一致，否则显式退出 3
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

    if not issues and not local_rows:
        verdict = "完全一致"
    elif not issues:
        verdict = (f"无非预期差异（另有 {sum(local_rows.values())} 行契约外字段差异，"
                   f"涉及 {len(local_rows)} 张表，属预期）")
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
