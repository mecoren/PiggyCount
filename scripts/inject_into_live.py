# -*- coding: utf-8 -*-
"""
PiggyCount —— 把测试数据写入运行中的真实应用数据库
====================================================
本脚本把 inject_test_data.py 里定义好的 DEVICE_A / DEVICE_B 账本与账户，
以及每个账本 500 条最近三年的交易明细，注入到**从模拟器拉取的真实库**
（scripts/live_db/live_16384.sqlite / live_16416.sqlite）。

与旧脚本的区别：
1. DB 路径由参数指定（指向真实库），不再写项目根目录的占位文件。
2. 交易注入按**账本名**定位目标账本（真实库 seed 只有 1 个默认账本，
   id 阈值 id>=13 不适用），幂等可重跑。
3. 多币种交易的 native_amount 正确折算成账本本位币(CNY)快照，
   避免净资产被错算 7 倍。

运行: python3 scripts/inject_into_live.py
"""

import importlib.util
import os
import random
import sqlite3
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE = os.path.join(ROOT, "scripts", "live_db")

# 端口 -> 从模拟器拉取的真实库
DB_FILES = {
    16384: os.path.join(LIVE, "live_16384.sqlite"),
    16416: os.path.join(LIVE, "live_16416.sqlite"),
}

TODAY = time.strftime("%Y-%m-%d", time.localtime())
NOW = int(time.time())

# 币种 -> 1 外币 = rate CNY（与 inject_test_data.FX_RATES 一致）
FX_RATE = {
    "CNY": 1.0, "USD": 7.10, "JPY": 0.048, "EUR": 7.70, "HKD": 0.91,
    "GBP": 9.00, "SGD": 5.30, "AUD": 4.70, "KRW": 0.0052, "THB": 0.20,
}
FX_QUOTES = {k: v for k, v in FX_RATE.items() if k != "CNY"}

TX_PER_LEDGER = 500
TYPE_WEIGHTS = [("expense", 0.60), ("income", 0.25), ("transfer", 0.10), ("adjustment", 0.05)]
BASE_RANGE = {
    "expense": (10.0, 5000.0),
    "income": (500.0, 20000.0),
    "transfer": (100.0, 10000.0),
    "adjustment": (0.0, 50000.0),
}
THREE_YEARS = int(3 * 365.25 * 86400)
START_TS = NOW - THREE_YEARS


def _load_specs():
    spec_path = os.path.join(ROOT, "scripts", "inject_test_data.py")
    mod = importlib.util.spec_from_file_location("itd", spec_path)
    itd = importlib.util.module_from_spec(mod)
    mod.loader.exec_module(itd)
    return itd.DEVICE_A, itd.DEVICE_B, itd.FX_RATES


def inject_ledgers_accounts(spec, db_path):
    port = spec["port"]
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA busy_timeout = 15000")
    cur = con.cursor()
    cur.execute("BEGIN IMMEDIATE")
    try:
        existing_ledger_names = {r[0] for r in cur.execute("SELECT name FROM ledgers").fetchall()}
        existing_account_names = {r[0] for r in cur.execute("SELECT name FROM accounts").fetchall()}

        ledgers_added = accounts_added = 0
        for lg in spec["ledgers"]:
            if lg["name"] in existing_ledger_names:
                ledger_id = cur.execute("SELECT id FROM ledgers WHERE name=?", (lg["name"],)).fetchone()[0]
                ledger_sync_id = cur.execute("SELECT sync_id FROM ledgers WHERE id=?", (ledger_id,)).fetchone()[0]
                print(f"  [复用账本] id={ledger_id} {lg['name']} (补齐缺失账户)")
            else:
                ledger_sync_id = str(uuid.uuid4())
                cur.execute(
                    """INSERT INTO ledgers
                       (name, currency, type, created_at, sync_id, month_start_day)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (lg["name"], lg["currency"], lg["ledger_type"], NOW,
                     ledger_sync_id, lg["month_start_day"]),
                )
                ledger_id = cur.lastrowid
                ledgers_added += 1
                existing_ledger_names.add(lg["name"])
                print(f"  [+账本] id={ledger_id} {lg['name']} "
                      f"(type={lg['ledger_type']}, cur={lg['currency']}, "
                      f"start_day={lg['month_start_day']})")

            for idx, acc in enumerate(lg["accounts"]):
                if acc["name"] in existing_account_names:
                    continue
                cur.execute(
                    """INSERT INTO accounts
                       (ledger_id, name, type, currency, initial_balance,
                        created_at, updated_at, sort_order, credit_limit,
                        billing_day, payment_due_day, bank_name, card_last_four,
                        note, sync_id, hidden)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (ledger_id, acc["name"], acc["type"], acc["currency"], acc["balance"],
                     NOW, NOW, idx, acc.get("credit_limit"), acc.get("billing_day"),
                     acc.get("payment_due_day"), acc.get("bank_name"), acc.get("card_last_four"),
                     acc.get("note"), str(uuid.uuid4()), acc.get("hidden", 0)),
                )
                accounts_added += 1
                existing_account_names.add(acc["name"])

        fx_added = 0
        for quote, rate in FX_QUOTES.items():
            cur.execute(
                """INSERT OR IGNORE INTO exchange_rates
                   (base_currency, quote_currency, rate_date, rate, source, fetched_at)
                   VALUES ('CNY', ?, ?, ?, 'manual', ?)""",
                (quote, TODAY, rate, NOW),
            )
            fx_added += cur.rowcount

        con.commit()
        print(f"  -> 新增账本 {ledgers_added} 个, 账户 {accounts_added} 个, "
              f"汇率 {fx_added} 条")
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def gen_amount(base_cny, currency):
    rate = FX_RATE.get(currency, 1.0)
    val = base_cny / rate if rate else base_cny
    if currency in ("JPY", "KRW"):
        return float(round(val))
    return round(val, 2)


def inject_transactions(spec, db_path):
    port = spec["port"]
    target_names = {lg["name"] for lg in spec["ledgers"]}
    random.seed(port)
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA busy_timeout = 30000")
    cur = con.cursor()

    cur.execute("SELECT id, kind FROM categories")
    expense, income, transfer = [], [], []
    for cid, kind in cur.fetchall():
        if kind == "expense":
            expense.append(cid)
        elif kind == "income":
            income.append(cid)
        elif kind == "transfer":
            transfer.append(cid)
    transfer_cat = transfer[0] if transfer else None

    cur.execute("SELECT id, name FROM ledgers WHERE name IN (%s)"
                % ",".join("?" * len(target_names)), tuple(target_names))
    target_ledgers = cur.fetchall()
    print(f"  目标账本(按名匹配): {[n for _, n in target_ledgers]}")

    total_added = 0
    for lid, lname in target_ledgers:
        cur.execute("SELECT COUNT(*) FROM transactions WHERE ledger_id=?", (lid,))
        existing = cur.fetchone()[0]
        need = TX_PER_LEDGER - existing
        if need <= 0:
            print(f"  [账本 {lid} {lname}] 已有 {existing} 条，跳过")
            continue

        cur.execute("SELECT id, currency FROM accounts WHERE ledger_id=?", (lid,))
        accs = cur.fetchall()
        if not accs:
            print(f"  [账本 {lid} {lname}] 无账户，跳过")
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
            native = round(amount * FX_RATE.get(currency, 1.0), 2)

            category_id = None
            to_account_id = None
            if ttype == "expense":
                category_id = random.choice(expense) if expense else None
            elif ttype == "income":
                category_id = random.choice(income) if income else None
            elif ttype == "transfer":
                category_id = transfer_cat
                others = [a for a in acc_ids if a != account_id]
                to_account_id = random.choice(others) if others else None
            # adjustment: category_id 保持 None

            happened_at = random.randint(START_TS, NOW)
            note = f"测试明细-{ttype}" if random.random() < 0.4 else None
            exclude_stats = 1 if random.random() < 0.05 else 0
            exclude_budget = 1 if random.random() < 0.05 else 0
            # 记录人:本地固定标识（共享账本已下线）
            created_by = 'dev-local-owner'

            rows.append((
                lid, ttype, amount, category_id, account_id, to_account_id,
                happened_at, note, str(uuid.uuid4()), created_by, created_by,
                exclude_stats, exclude_budget, currency, native,
            ))

        cur.executemany(
            """INSERT INTO transactions
               (ledger_id, type, amount, category_id, account_id, to_account_id,
                happened_at, note, sync_id, created_by_user_id, last_edited_by_user_id,
                exclude_from_stats, exclude_from_budget, currency_code, native_amount)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            rows,
        )
        con.commit()
        total_added += len(rows)
        print(f"  [账本 {lid} {lname}] 新增 {len(rows)} 条 (累计 {existing + len(rows)})")

    con.close()
    print(f"  -> 本库新增交易 {total_added} 条")


def verify(db_path):
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    L = cur.execute("SELECT COUNT(*) FROM ledgers").fetchone()[0]
    A = cur.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]
    T = cur.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    orphan = cur.execute(
        "SELECT COUNT(*) FROM accounts a LEFT JOIN ledgers l ON a.ledger_id=l.id WHERE l.id IS NULL"
    ).fetchone()[0]
    cur.execute(
        "SELECT l.name, COUNT(a.id), COUNT(t.id) FROM ledgers l "
        "LEFT JOIN accounts a ON a.ledger_id=l.id "
        "LEFT JOIN transactions t ON t.ledger_id=l.id GROUP BY l.id ORDER BY l.id"
    )
    rows = cur.fetchall()
    con.close()
    return L, A, T, orphan, rows


def main():
    DEVICE_A, DEVICE_B, _FX = _load_specs()
    specs = {16384: DEVICE_A, 16416: DEVICE_B}
    for port, spec in specs.items():
        db_path = DB_FILES[port]
        if not os.path.exists(db_path):
            print(f"[SKIP] {db_path} 不存在，请先拉取真实库")
            continue
        print(f"\n========== 端口 {port}: {db_path} ==========")
        inject_ledgers_accounts(spec, db_path)
        inject_transactions(spec, db_path)

    print("\n========== 校验 ==========")
    for port, path in DB_FILES.items():
        if os.path.exists(path):
            L, A, T, orphan, rows = verify(path)
            print(f"\n[端口 {port}] 账本={L}, 账户={A}, 交易={T}, 孤儿账户={orphan}")
            print("  各账本 -> 账户数 / 交易数:")
            for name, ac, tx in rows:
                print(f"    - {name}: 账户 {ac}, 交易 {tx}")


if __name__ == "__main__":
    main()
