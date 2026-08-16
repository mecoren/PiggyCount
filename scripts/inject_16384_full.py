# -*- coding: utf-8 -*-
"""
PiggyCount —— 向 16384 真实库注入完整测试数据并写入 local_changes 触发云同步
============================================================================
注入目标(DB 文件指向从模拟器拉取的 regen_16384.sqlite):
  * 默认账本(id=1):补 sync_id + 10 账户 + 500 交易(用户要求默认账本也要有数据)
  * 5 个新账本:各 10 账户(按 类型/币种/状态/归属 差异化) + 500 交易
  * 自定义 categories(13,带 TC- 前缀避免与 60 seed 冲突,确保跨设备按 sync_id 解析)
  * tags(15) / budgets(每账本 2~3) / recurring_transactions(每账本 3) /
    exchange_rate_overrides(9 币种)
  * 全部分步实体写入 local_changes(ledger_id: user-global=0 / ledger-scoped=账目 id),
    保证应用启动后无论是 fullPush 还是增量 push 都能把数据推上云(16416 自动收到)。

运行: python3 scripts/inject_16384_full.py
"""

import os
import random
import sqlite3
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "scripts", "live_db", "regen_16384.sqlite")
NOW = int(time.time())
TODAY = time.strftime("%Y-%m-%d")

# 币种 -> 1 外币 = rate CNY
FX_RATE = {"CNY": 1.0, "USD": 7.10, "JPY": 0.048, "EUR": 7.70, "HKD": 0.91,
           "GBP": 9.00, "SGD": 5.30, "AUD": 4.70, "KRW": 0.0052, "THB": 0.20}
FX_QUOTES = {k: v for k, v in FX_RATE.items() if k != "CNY"}

TX_PER_LEDGER = 500
TYPE_WEIGHTS = [("expense", 0.60), ("income", 0.25), ("transfer", 0.10), ("adjustment", 0.05)]
BASE_RANGE = {"expense": (10.0, 5000.0), "income": (500.0, 20000.0),
              "transfer": (100.0, 10000.0), "adjustment": (0.0, 50000.0)}
THREE_YEARS = int(3 * 365.25 * 86400)
START_TS = NOW - THREE_YEARS
OWNER = "dev-owner-16384"

# 各账本账户规格:[ (type, currency, hidden, kind标签) ... ] 10 个,账本内唯一
LEDGER_ACC_SPECS = {
    "日常": [
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("credit_card", "CNY", 0),
        ("alipay", "CNY", 0), ("wechat", "CNY", 0), ("cash", "USD", 0),
        ("bank_card", "USD", 0), ("other", "CNY", 0), ("social_fund", "CNY", 0),
        ("cash", "CNY", 1),
    ],
    "海外": [
        ("cash", "USD", 0), ("cash", "JPY", 0), ("cash", "EUR", 0),
        ("bank_card", "USD", 0), ("credit_card", "EUR", 0), ("alipay", "USD", 0),
        ("wechat", "HKD", 0), ("cash", "GBP", 0), ("bank_card", "SGD", 0),
        ("other", "CNY", 0),
    ],
    "资产": [
        ("real_estate", "CNY", 0), ("vehicle", "CNY", 0), ("investment", "CNY", 0),
        ("insurance", "CNY", 0), ("social_fund", "CNY", 0), ("loan", "CNY", 0),
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("investment", "USD", 0),
        ("real_estate", "USD", 0),
    ],
    "创业": [
        ("bank_card", "CNY", 0), ("credit_card", "CNY", 0), ("loan", "CNY", 0),
        ("cash", "CNY", 0), ("alipay", "CNY", 0), ("wechat", "CNY", 0),
        ("investment", "CNY", 0), ("other", "CNY", 0), ("bank_card", "USD", 0),
        ("cash", "CNY", 1),
    ],
    "家庭": [
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("alipay", "CNY", 0),
        ("wechat", "CNY", 0), ("credit_card", "CNY", 0), ("cash", "USD", 0),
        ("bank_card", "CNY", 0), ("other", "CNY", 0), ("social_fund", "CNY", 0),
        ("cash", "CNY", 1),
    ],
    "默认": [
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("credit_card", "CNY", 0),
        ("alipay", "CNY", 0), ("wechat", "CNY", 0), ("cash", "USD", 0),
        ("bank_card", "USD", 0), ("other", "CNY", 0), ("social_fund", "CNY", 0),
        ("cash", "CNY", 1),
    ],
}

# 类型中文标签(用于生成唯一账户名)
TYPE_LABEL = {"cash": "现金", "bank_card": "储蓄卡", "credit_card": "信用卡",
              "alipay": "支付宝", "wechat": "微信", "other": "其他",
              "real_estate": "不动产", "vehicle": "车辆", "investment": "投资",
              "insurance": "保险", "social_fund": "社保", "loan": "贷款"}

# 5 个新账本(默认账本单独处理)
NEW_LEDGERS = [
    {"name": "日常消费账本", "tag": "日常", "currency": "CNY", "is_shared": 0, "my_role": "owner", "member_count": 1},
    {"name": "海外旅行账本", "tag": "海外", "currency": "CNY", "is_shared": 0, "my_role": "owner", "member_count": 1},
    {"name": "资产配置账本", "tag": "资产", "currency": "CNY", "is_shared": 0, "my_role": "owner", "member_count": 1},
    {"name": "创业公司账本", "tag": "创业", "currency": "CNY", "is_shared": 0, "my_role": "owner", "member_count": 1},
    {"name": "家庭共用账本", "tag": "家庭", "currency": "CNY", "is_shared": 1, "my_role": "owner", "member_count": 2, "owner_user_id": OWNER},
]

# 自定义分类(TC- 前缀,避免与 60 seed 冲突)
CUSTOM_CATS = [
    ("TC-餐饮", "expense"), ("TC-交通", "expense"), ("TC-购物", "expense"),
    ("TC-娱乐", "expense"), ("TC-居家", "expense"), ("TC-医疗", "expense"),
    ("TC-教育", "expense"), ("TC-旅行", "expense"),
    ("TC-工资", "income"), ("TC-奖金", "income"), ("TC-理财", "income"), ("TC-兼职", "income"),
    ("TC-转账", "transfer"),
]


def gen_amount(base_cny, currency):
    rate = FX_RATE.get(currency, 1.0)
    val = base_cny / rate if rate else base_cny
    if currency in ("JPY", "KRW"):
        return float(round(val))
    return round(val, 2)


def add_change(cur, etype, eid, esync, ledger_id, changes, action="upsert"):
    cur.execute(
        "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, ledger_id, action, created_at, pushed_at) "
        "VALUES (?,?,?,?,?,?,NULL)",
        (etype, eid, esync, ledger_id, action, NOW),
    )
    changes.append((etype, eid, esync, ledger_id, action))


def make_acc_name(tag, atype, cur_code, hidden, used):
    """生成账本内唯一账户名;hidden 账户加 -隐藏 后缀,其余碰撞加 -n 兜底。"""
    label = TYPE_LABEL.get(atype, atype)
    base = f"{tag}-{label}{cur_code}"
    cand = base + ("-隐藏" if hidden else "")
    if cand in used:
        n = 1
        while cand in used:
            cand = f"{base}-{n}"
            n += 1
    used.add(cand)
    return cand


def main():
    if not os.path.exists(DB):
        print("[SKIP] 未找到", DB, "请先拉取 16384 真实库到该路径")
        return
    con = sqlite3.connect(DB)
    con.execute("PRAGMA busy_timeout = 30000")
    cur = con.cursor()
    changes = []  # 收集 local_changes 行

    # ---------- 1) 账本 ----------
    print("=== 注入账本 ===")
    all_ledgers = []  # (ledger_id, name, tag, is_shared, owner_uid)
    # 默认账本:补 sync_id
    cur.execute("SELECT id, name FROM ledgers WHERE id=1")
    def_row = cur.fetchone()
    def_sync = str(uuid.uuid4())
    cur.execute("UPDATE ledgers SET sync_id=? WHERE id=1", (def_sync,))
    all_ledgers.append((def_row[0], def_row[1], "默认", 0, None))
    add_change(cur, "ledger", def_row[0], def_sync, def_row[0], changes)
    print(f"  [默认账本] id=1 补 sync_id={def_sync}")

    for lg in NEW_LEDGERS:
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO ledgers (name, currency, type, created_at, sync_id, my_role, "
            "member_count, is_shared, owner_user_id, month_start_day) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (lg["name"], lg["currency"], "personal", NOW, sid, lg["my_role"],
             lg["member_count"], lg["is_shared"], lg.get("owner_user_id"), 1),
        )
        lid = cur.lastrowid
        add_change(cur, "ledger", lid, sid, lid, changes)
        if lg["is_shared"] == 1 and lg.get("owner_user_id"):
            cur.execute(
                "INSERT OR IGNORE INTO ledger_members "
                "(ledger_sync_id, user_id, email, display_name, role, joined_at, updated_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (sid, lg["owner_user_id"], None, "设备16384主人", "owner", NOW, NOW),
            )
        all_ledgers.append((lid, lg["name"], lg["tag"], lg["is_shared"], lg.get("owner_user_id")))
        print(f"  [+账本] id={lid} {lg['name']} (shared={lg['is_shared']}, tag={lg['tag']})")

    # ---------- 2) 自定义分类 ----------
    print("=== 注入自定义分类 ===")
    custom_cat_ids = {}
    for i, (name, kind) in enumerate(CUSTOM_CATS):
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO categories (name, kind, icon, sort_order, level, icon_type, sync_id) "
            "VALUES (?,?,?,?,?,?,?)",
            (name, kind, "restaurant", i, 1, "material", sid),
        )
        cid = cur.lastrowid
        custom_cat_ids[kind] = custom_cat_ids.get(kind, []) + [cid]
        add_change(cur, "category", cid, sid, 0, changes)
    print(f"  自定义分类 {len(CUSTOM_CATS)} 个, 按 kind 分: "
          + ", ".join(f"{k}={len(v)}" for k, v in custom_cat_ids.items()))

    # ---------- 3) 标签 ----------
    print("=== 注入标签 ===")
    tag_ids = []
    for i in range(1, 16):
        name = f"TT-标签{i}"
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO tags (name, color, sort_order, created_at, sync_id) VALUES (?,?,?,?,?)",
            (name, "#1976d2", i, NOW, sid),
        )
        tid = cur.lastrowid
        tag_ids.append(tid)
        add_change(cur, "tag", tid, sid, 0, changes)
    print(f"  标签 {len(tag_ids)} 个")

    # ---------- 4) 账户(每账本 10,差异化) ----------
    print("=== 注入账户 ===")
    random.seed(16384)
    ledger_accounts = {}  # ledger_id -> [(acc_id, currency)]
    for lid, lname, tag, is_shared, owner_uid in all_ledgers:
        specs = LEDGER_ACC_SPECS[tag]
        acc_ids = []
        used_names = set()
        for idx, (atype, cur_code, hidden) in enumerate(specs):
            name = make_acc_name(tag, atype, cur_code, hidden, used_names)
            # 初始余额按类型给合理值
            if atype in ("real_estate", "vehicle", "investment", "insurance"):
                balance = round(random.uniform(100000, 5000000), 2)
            elif atype == "loan":
                balance = -round(random.uniform(10000, 500000), 2)
            elif atype == "social_fund":
                balance = round(random.uniform(0, 200000), 2)
            elif atype == "credit_card":
                balance = 0.0
            else:
                balance = round(random.uniform(100, 50000), 2)
            sid = str(uuid.uuid4())
            credit_limit = None; billing_day = None; payment_due_day = None; bank_name = None; card_last_four = None
            if atype == "credit_card":
                credit_limit = 50000.0 if tag != "创业" else 100000.0
                billing_day = 5; payment_due_day = 25; bank_name = "招商银行"; card_last_four = f"{random.randint(1000,9999)}"
            elif atype == "bank_card":
                bank_name = "招商银行" if cur_code == "CNY" else "Citibank"
                card_last_four = f"{random.randint(1000,9999)}"
            note = f"{lname}下的{Type_LABEL_safe(atype)}账户"
            cur.execute(
                "INSERT INTO accounts (ledger_id, name, type, currency, initial_balance, created_at, "
                "updated_at, sort_order, credit_limit, billing_day, payment_due_day, bank_name, "
                "card_last_four, note, sync_id, hidden) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (lid, name, atype, cur_code, balance, NOW, NOW, idx, credit_limit, billing_day,
                 payment_due_day, bank_name, card_last_four, note, sid, hidden),
            )
            aid = cur.lastrowid
            acc_ids.append((aid, cur_code))
            add_change(cur, "account", aid, sid, 0, changes)
        ledger_accounts[lid] = acc_ids
        print(f"  [账本 {lid} {lname}] 账户 {len(acc_ids)} 个")

    # ---------- 5) 交易(每账本 500,最近三年,多币种) ----------
    print("=== 注入交易 ===")
    random.seed(16384)
    total_tx = 0
    for lid, lname, tag, is_shared, owner_uid in all_ledgers:
        accs = ledger_accounts[lid]
        if not accs:
            continue
        acc_ids = [a[0] for a in accs]
        acc_cur = {a[0]: a[1] for a in accs}
        ex = custom_cat_ids.get("expense", [])
        inc = custom_cat_ids.get("income", [])
        tr = custom_cat_ids.get("transfer", [None])[0]
        rows = []
        tx_tag_links = []  # (tx_index_in_rows, tag_id)
        for k in range(TX_PER_LEDGER):
            r = random.random()
            cum = 0.0; ttype = "expense"
            for t, w in TYPE_WEIGHTS:
                cum += w
                if r <= cum:
                    ttype = t; break
            base_lo, base_hi = BASE_RANGE[ttype]
            base = random.uniform(base_lo, base_hi)
            account_id = random.choice(acc_ids)
            currency = acc_cur[account_id]
            amount = gen_amount(base, currency)
            native = round(amount * FX_RATE.get(currency, 1.0), 2)
            category_id = None; to_account_id = None
            if ttype == "expense":
                category_id = random.choice(ex) if ex else None
            elif ttype == "income":
                category_id = random.choice(inc) if inc else None
            elif ttype == "transfer":
                category_id = tr
                others = [a for a in acc_ids if a != account_id]
                to_account_id = random.choice(others) if others else None
            happened_at = random.randint(START_TS, NOW)
            note = f"测试明细-{ttype}" if random.random() < 0.4 else None
            exclude_stats = 1 if random.random() < 0.05 else 0
            exclude_budget = 1 if random.random() < 0.05 else 0
            created_by = owner_uid  # 共享账本记创建者;个人账本 NULL
            sid = str(uuid.uuid4())
            rows.append((lid, ttype, amount, category_id, account_id, to_account_id,
                         happened_at, note, sid, created_by, created_by,
                         exclude_stats, exclude_budget, currency, native))
            # 约 30% 交易挂一个标签(用于验证标签同步)
            if random.random() < 0.3:
                tx_tag_links.append((len(rows) - 1, random.choice(tag_ids)))
        cur.executemany(
            "INSERT INTO transactions (ledger_id, type, amount, category_id, account_id, "
            "to_account_id, happened_at, note, sync_id, created_by_user_id, last_edited_by_user_id, "
            "exclude_from_stats, exclude_from_budget, currency_code, native_amount) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            rows,
        )
        # 收集刚插入的 tx id(连续段)
        first_tx = cur.execute("SELECT seq FROM sqlite_sequence WHERE name='transactions'").fetchone()
        # 用 lastrowid 推算:executemany 后 lastrowid 为最后一行
        last_tx = cur.lastrowid
        tx_ids = list(range(last_tx - len(rows) + 1, last_tx + 1))
        for i, tid in enumerate(tx_ids):
            add_change(cur, "transaction", tid, rows[i][8], lid, changes)
        for (idx, tid) in tx_tag_links:
            cur.execute("INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (?,?)",
                        (tx_ids[idx], tid))
        total_tx += len(rows)
        print(f"  [账本 {lid} {lname}] 交易 {len(rows)} 条, 挂标签 {len(tx_tag_links)} 条")
    print(f"  交易合计 {total_tx} 条")

    # ---------- 6) 预算(每账本 2~3) ----------
    print("=== 注入预算 ===")
    random.seed(777)
    budget_count = 0
    for lid, lname, tag, is_shared, owner_uid in all_ledgers:
        ex = custom_cat_ids.get("expense", [])
        n = 3 if lid % 2 == 0 else 2
        for j in range(n):
            sid = str(uuid.uuid4())
            if j == 0:
                btype = "total"; cat_id = None
            else:
                btype = "category"; cat_id = random.choice(ex) if ex else None
            amount = round(random.uniform(1000, 20000), 2)
            cur.execute(
                "INSERT INTO budgets (sync_id, ledger_id, type, category_id, amount, period, "
                "start_day, enabled, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (sid, lid, btype, cat_id, amount, "monthly", 1, 1, NOW, NOW),
            )
            bid = cur.lastrowid
            add_change(cur, "budget", bid, sid, lid, changes)
            budget_count += 1
    print(f"  预算 {budget_count} 条")

    # ---------- 7) 周期交易(每账本 3) ----------
    print("=== 注入周期交易 ===")
    random.seed(999)
    rec_count = 0
    for lid, lname, tag, is_shared, owner_uid in all_ledgers:
        accs = ledger_accounts[lid]
        if not accs:
            continue
        acc_ids = [a[0] for a in accs]
        acc_cur = {a[0]: a[1] for a in accs}
        ex = custom_cat_ids.get("expense", [])
        inc = custom_cat_ids.get("income", [])
        for j in range(3):
            sid = str(uuid.uuid4())
            rtype = "expense" if j < 2 else "income"
            amount = gen_amount(random.uniform(100, 5000), "CNY")
            cat_id = (random.choice(ex) if rtype == "expense" else random.choice(inc)) if (ex or inc) else None
            acc_id = random.choice(acc_ids)
            freq = "monthly" if j < 2 else "weekly"
            day_of_month = random.randint(1, 28) if freq == "monthly" else None
            day_of_week = random.randint(0, 6) if freq == "weekly" else None
            cur.execute(
                "INSERT INTO recurring_transactions (ledger_id, sync_id, type, amount, category_id, "
                "account_id, to_account_id, note, frequency, interval, day_of_month, day_of_week, "
                "month_of_year, start_date, end_date, last_generated_date, enabled, created_at, updated_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (lid, sid, rtype, amount, cat_id, acc_id, None, f"{lname}周期{j+1}", freq, 1,
                 day_of_month, day_of_week, None, NOW, None, None, 1, NOW, NOW),
            )
            rid = cur.lastrowid
            add_change(cur, "recurring", rid, sid, lid, changes)
            rec_count += 1
    print(f"  周期交易 {rec_count} 条")

    # ---------- 8) 汇率覆盖(9 币种) ----------
    print("=== 注入汇率覆盖 ===")
    fx_count = 0
    for q, rate in FX_QUOTES.items():
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO exchange_rate_overrides (sync_id, base_currency, quote_currency, rate, updated_at) "
            "VALUES (?,?,?,?,?)",
            (sid, "CNY", q, str(rate), NOW),
        )
        oid = cur.lastrowid
        add_change(cur, "exchange_rate_override", oid, sid, 0, changes)
        fx_count += 1
    print(f"  汇率覆盖 {fx_count} 条")

    # ---------- 提交 + local_changes ----------
    con.commit()
    print(f"\n=== 已写入 local_changes {len(changes)} 条 (user-global ledger_id=0 / ledger-scope=帐本id) ===")
    # 统计 local_changes 分布
    dist = {}
    for et, eid, es, lid, act in changes:
        dist[et] = dist.get(et, 0) + 1
    for k, v in sorted(dist.items()):
        print(f"  {k}: {v}")

    # ---------- 校验 ----------
    print("\n=== 校验 ===")
    L = cur.execute("SELECT COUNT(*) FROM ledgers").fetchone()[0]
    A = cur.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]
    T = cur.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    C = cur.execute("SELECT COUNT(*) FROM categories").fetchone()[0]
    G = cur.execute("SELECT COUNT(*) FROM tags").fetchone()[0]
    B = cur.execute("SELECT COUNT(*) FROM budgets").fetchone()[0]
    R = cur.execute("SELECT COUNT(*) FROM recurring_transactions").fetchone()[0]
    E = cur.execute("SELECT COUNT(*) FROM exchange_rate_overrides").fetchone()[0]
    orphan_acc = cur.execute("SELECT COUNT(*) FROM accounts a LEFT JOIN ledgers l ON a.ledger_id=l.id WHERE l.id IS NULL").fetchone()[0]
    orphan_tx = cur.execute("SELECT COUNT(*) FROM transactions t LEFT JOIN ledgers l ON t.ledger_id=l.id WHERE l.id IS NULL").fetchone()[0]
    dup_name = cur.execute("SELECT name, COUNT(*) c FROM accounts GROUP BY name HAVING c>1").fetchall()
    dup_sync = cur.execute("SELECT entity_sync_id, COUNT(*) c FROM local_changes GROUP BY entity_sync_id HAVING c>1").fetchall()
    print(f"账本={L} 账户={A} 交易={T} 分类={C}(+{len(CUSTOM_CATS)}自定义) 标签={G} 预算={B} 周期={R} 汇率覆盖={E}")
    print(f"孤儿账户={orphan_acc} 孤儿交易={orphan_tx} 重复账户名={len(dup_name)} 重复sync_id(change)={len(dup_sync)}")
    con.close()
    print("\n[OK] 注入完成,可将 regen_16384.sqlite 推回 16384 模拟器并启动应用触发云同步")


def Type_LABEL_safe(t):
    return TYPE_LABEL.get(t, t)


if __name__ == "__main__":
    main()
