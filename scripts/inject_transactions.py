# -*- coding: utf-8 -*-
"""
PiggyCount 交易明细(transaction)注入脚本
=========================================
为本项目新建的 5 个账本/库（ledger id 13-17）各注入 500 条交易明细，
覆盖最近三年，类型按比例混合 支出/收入/转账/调整，并正确关联账户与分类。

- 仅作用于本次新建账本(id>=13)，不动 12 个 seed 账本与其 19490 条既有交易。
- 账户/分类均取自当前库，保证 account_id / category_id 真实有效。
- 金额按账户币种折算(用既有 CNY 基准汇率)，happened_at 均匀分布在最近 3 年。
- 幂等：若某账本交易数已 >=500，自动补齐至 500。

运行: python3 scripts/inject_transactions.py
"""

import os
import random
import sqlite3
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_FILES = {
    16384: os.path.join(ROOT, "db16384.sqlite"),
    16416: os.path.join(ROOT, "db16416.sqlite"),
}

NOW = int(time.time())
THREE_YEARS = int(3 * 365.25 * 86400)
START_TS = NOW - THREE_YEARS

# 币种 -> 1 外币 = rate CNY（与 inject_test_data.py 的 FX_RATES 一致）
FX_RATE = {
    "CNY": 1.0, "USD": 7.10, "JPY": 0.048, "EUR": 7.70, "HKD": 0.91,
    "GBP": 9.00, "SGD": 5.30, "AUD": 4.70, "KRW": 0.0052, "THB": 0.20,
}

# 各类型基准金额区间(CNY)
BASE_RANGE = {
    "expense": (10.0, 5000.0),
    "income": (500.0, 20000.0),
    "transfer": (100.0, 10000.0),
    "adjustment": (0.0, 50000.0),
}

TX_PER_LEDGER = 500
# 类型分布
TYPE_WEIGHTS = [("expense", 0.60), ("income", 0.25), ("transfer", 0.10), ("adjustment", 0.05)]


def fetch_categories(cur):
    cur.execute("SELECT id, kind FROM categories")
    expense, income, transfer = [], [], []
    for cid, kind in cur.fetchall():
        if kind == "expense":
            expense.append(cid)
        elif kind == "income":
            income.append(cid)
        elif kind == "transfer":
            transfer.append(cid)
    return expense, income, transfer


def gen_amount(base_cny, currency):
    rate = FX_RATE.get(currency, 1.0)
    val = base_cny / rate if rate else base_cny
    # 日元/韩元取整，其它保留 2 位
    if currency in ("JPY", "KRW"):
        return float(round(val))
    return round(val, 2)


def inject_device(port, db_path):
    if not os.path.exists(db_path):
        print(f"[SKIP] {db_path} 不存在")
        return
    print(f"\n========== 设备端口 {port}: {db_path} ==========")
    random.seed(port)  # 两库数据可复现且彼此区分
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA busy_timeout = 30000")
    cur = con.cursor()

    expense_cats, income_cats, transfer_cats = fetch_categories(cur)
    transfer_cat = transfer_cats[0] if transfer_cats else None

    cur.execute("SELECT id, owner_user_id FROM ledgers WHERE id>=13 ORDER BY id")
    new_ledgers = cur.fetchall()

    total_added = 0
    for lid, owner_uid in new_ledgers:
        cur.execute("SELECT COUNT(*) FROM transactions WHERE ledger_id=?", (lid,))
        existing = cur.fetchone()[0]
        need = TX_PER_LEDGER - existing
        if need <= 0:
            print(f"  [账本 {lid}] 已有 {existing} 条，跳过")
            continue

        cur.execute("SELECT id, currency FROM accounts WHERE ledger_id=?", (lid,))
        accs = cur.fetchall()
        if not accs:
            print(f"  [账本 {lid}] 无账户，跳过")
            continue
        acc_ids = [a[0] for a in accs]
        acc_cur = {a[0]: a[1] for a in accs}

        rows = []
        for _ in range(need):
            r = random.random()
            cum = 0.0
            ttype = "expense"
            for t, w in TYPE_WEIGHTS:
                cum += w
                if r <= cum:
                    ttype = t
                    break

            base_lo, base_hi = BASE_RANGE[ttype]
            base = random.uniform(base_lo, base_hi)
            account_id = random.choice(acc_ids)
            currency = acc_cur[account_id]
            amount = gen_amount(base, currency)

            category_id = None
            to_account_id = None
            if ttype == "expense":
                category_id = random.choice(expense_cats) if expense_cats else None
            elif ttype == "income":
                category_id = random.choice(income_cats) if income_cats else None
            elif ttype == "transfer":
                category_id = transfer_cat
                # 选一个不同的账户作为入账账户
                others = [a for a in acc_ids if a != account_id]
                to_account_id = random.choice(others) if others else None
            # adjustment: category_id 保持 None

            happened_at = random.randint(START_TS, NOW)
            note = None
            if random.random() < 0.4:
                note = f"测试明细-{ttype}"
            exclude_stats = 1 if random.random() < 0.05 else 0
            exclude_budget = 1 if random.random() < 0.05 else 0
            created_by = owner_uid  # 共享账本记录创建者；个人账本 owner_uid 为 None

            rows.append((
                lid, ttype, amount, category_id, account_id, to_account_id,
                happened_at, note, str(uuid.uuid4()), created_by, created_by,
                exclude_stats, exclude_budget, currency, amount,
            ))

        cur.executemany(
            """
            INSERT INTO transactions
                (ledger_id, type, amount, category_id, account_id, to_account_id,
                 happened_at, note, sync_id, created_by_user_id, last_edited_by_user_id,
                 exclude_from_stats, exclude_from_budget, currency_code, native_amount)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        con.commit()
        total_added += len(rows)
        print(f"  [账本 {lid}] 新增 {len(rows)} 条 (累计 {existing + len(rows)})")

    # 汇总校验
    cur.execute(
        "SELECT l.id, l.name, COUNT(t.id) FROM ledgers l "
        "LEFT JOIN transactions t ON t.ledger_id=l.id WHERE l.id>=13 GROUP BY l.id ORDER BY l.id"
    )
    print("  --- 新账本交易数 ---")
    for lid, name, cnt in cur.fetchall():
        flag = "OK" if cnt >= TX_PER_LEDGER else f"仅 {cnt}"
        print(f"    - {name}: {cnt} [{flag}]")
    con.close()
    print(f"  -> 本库新增交易 {total_added} 条")


def main():
    for port, path in DB_FILES.items():
        inject_device(port, path)


if __name__ == "__main__":
    main()
