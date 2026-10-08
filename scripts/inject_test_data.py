# -*- coding: utf-8 -*-
"""
PiggyCount 测试数据注入脚本
============================
向两个 dev 环境的 SQLite 数据库注入账本(ledger)与账户(account)测试数据：
  - db16384.sqlite  (VM service 端口 16384)
  - db16416.sqlite  (VM service 端口 16416)

设计目标
--------
1. 每个库新建 5 个账本，每账本下 10 个账户。
2. 账户按「类型 / 币种 / 隐藏状态 / 归属(账本)」多维度差异化。
3. 命名不与现有数据冲突（现有 12 个账本 + 10 个 ledger_id=0 孤儿账户）。
4. 遵循项目数据模型与约束：
   - ledger: name/currency/type/created_at/sync_id/month_start_day 必填或带默认值。
   - account: ledger_id/name/type/currency/initial_balance/sort_order/hidden 必填；
     credit 类补充 credit_limit/billing_day/payment_due_day；银行卡补充 bank_name/card_last_four。
   - sync_id 一律使用真实 UUID(v4)，保证跨设备唯一。
5. 幂等：已存在的同名账本/账户自动跳过，可安全重复运行。

运行: python3 scripts/inject_test_data.py
"""

import os
import sqlite3
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_FILES = {
    16384: os.path.join(ROOT, "db16384.sqlite"),
    16416: os.path.join(ROOT, "db16416.sqlite"),
}

# 今天（用于汇率 rateDate）
TODAY = time.strftime("%Y-%m-%d", time.localtime())
NOW = int(time.time())

# 多币种折算汇率（base=CNY, 方向: 1 quote = rate CNY）
# 仅用于让多币种账户的净资产折算在 dev 环境可计算。
FX_RATES = {
    "USD": "7.10",
    "JPY": "0.048",
    "EUR": "7.70",
    "HKD": "0.91",
    "GBP": "9.00",
    "SGD": "5.30",
    "AUD": "4.70",
    "KRW": "0.0052",
    "THB": "0.20",
}

# ---------------------------------------------------------------------------
# 设备 A (端口 16384) —— 个人主力机场景
# ---------------------------------------------------------------------------
DEVICE_A = {
    "port": 16384,
    "ledgers": [
        {
            "name": "日常消费账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 1,
            "accounts": [
                {"name": "日常现金", "type": "cash", "currency": "CNY", "balance": 2000.0, "hidden": 0,
                 "note": "随手零钱"},
                {"name": "招行储蓄卡", "type": "bank_card", "currency": "CNY", "balance": 50000.0, "hidden": 0,
                 "bank_name": "招商银行", "card_last_four": "8821"},
                {"name": "主力支付宝", "type": "alipay", "currency": "CNY", "balance": 8500.0, "hidden": 0},
                {"name": "主力微信钱包", "type": "wechat", "currency": "CNY", "balance": 3200.0, "hidden": 0},
                {"name": "招行信用卡", "type": "credit_card", "currency": "CNY", "balance": -12000.0, "hidden": 0,
                 "credit_limit": 50000.0, "billing_day": 5, "payment_due_day": 23,
                 "bank_name": "招商银行", "card_last_four": "6633"},
                {"name": "美团钱包", "type": "other", "currency": "CNY", "balance": 600.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "数字人民币", "type": "other", "currency": "CNY", "balance": 1500.0, "hidden": 0},
                {"name": "证券保证金", "type": "investment", "currency": "CNY", "balance": 30000.0, "hidden": 0},
                {"name": "公积金账户", "type": "social_fund", "currency": "CNY", "balance": 45000.0, "hidden": 0},
                {"name": "消费贷", "type": "loan", "currency": "CNY", "balance": -80000.0, "hidden": 1,
                 "note": "已归档负债"},
            ],
        },
        {
            "name": "海外旅行账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 5,
            "accounts": [
                {"name": "美元现金", "type": "cash", "currency": "USD", "balance": 500.0, "hidden": 0},
                {"name": "美元银行卡", "type": "bank_card", "currency": "USD", "balance": 3000.0, "hidden": 0,
                 "bank_name": "Bank of America", "card_last_four": "1029"},
                {"name": "日元现金", "type": "cash", "currency": "JPY", "balance": 30000.0, "hidden": 0},
                {"name": "欧元银行卡", "type": "bank_card", "currency": "EUR", "balance": 1500.0, "hidden": 0,
                 "bank_name": "Deutsche Bank", "card_last_four": "5521"},
                {"name": "港币现金", "type": "cash", "currency": "HKD", "balance": 2000.0, "hidden": 0},
                {"name": "双币信用卡(美元)", "type": "credit_card", "currency": "USD", "balance": -800.0, "hidden": 0,
                 "credit_limit": 10000.0, "billing_day": 10, "payment_due_day": 28,
                 "bank_name": "Visa", "card_last_four": "7788"},
                {"name": "支付宝(国际)", "type": "alipay", "currency": "CNY", "balance": 2000.0, "hidden": 0},
                {"name": "境外微信钱包", "type": "wechat", "currency": "CNY", "balance": 1000.0, "hidden": 0},
                {"name": "旅行备用金", "type": "other", "currency": "EUR", "balance": 800.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "外币理财", "type": "investment", "currency": "USD", "balance": 5000.0, "hidden": 0},
            ],
        },
        {
            "name": "资产配置账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 1,
            "accounts": [
                {"name": "配置现金", "type": "cash", "currency": "CNY", "balance": 10000.0, "hidden": 0},
                {"name": "活期存款", "type": "bank_card", "currency": "CNY", "balance": 120000.0, "hidden": 0,
                 "bank_name": "工商银行", "card_last_four": "4471"},
                {"name": "自住房产", "type": "real_estate", "currency": "CNY", "balance": 3500000.0, "hidden": 0},
                {"name": "家用汽车", "type": "vehicle", "currency": "CNY", "balance": 180000.0, "hidden": 0},
                {"name": "股票账户", "type": "investment", "currency": "CNY", "balance": 250000.0, "hidden": 0},
                {"name": "基金定投", "type": "investment", "currency": "CNY", "balance": 90000.0, "hidden": 0},
                {"name": "商业保险", "type": "insurance", "currency": "CNY", "balance": 200000.0, "hidden": 0},
                {"name": "社保账户", "type": "social_fund", "currency": "CNY", "balance": 60000.0, "hidden": 0},
                {"name": "黄金积存", "type": "investment", "currency": "CNY", "balance": 40000.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "车贷", "type": "loan", "currency": "CNY", "balance": -95000.0, "hidden": 0},
            ],
        },
        {
            "name": "创业公司账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 10,
            "accounts": [
                {"name": "公司现金", "type": "cash", "currency": "CNY", "balance": 8000.0, "hidden": 0},
                {"name": "对公基本户", "type": "bank_card", "currency": "CNY", "balance": 280000.0, "hidden": 0,
                 "bank_name": "建设银行", "card_last_four": "3390"},
                {"name": "企业支付宝", "type": "alipay", "currency": "CNY", "balance": 45000.0, "hidden": 0},
                {"name": "企业微信支付", "type": "wechat", "currency": "CNY", "balance": 12000.0, "hidden": 0},
                {"name": "公司信用卡", "type": "credit_card", "currency": "CNY", "balance": -35000.0, "hidden": 0,
                 "credit_limit": 200000.0, "billing_day": 15, "payment_due_day": 3,
                 "bank_name": "招商银行", "card_last_four": "9012"},
                {"name": "创始人借款", "type": "loan", "currency": "CNY", "balance": -150000.0, "hidden": 0,
                 "note": "欠创始人的负债"},
                {"name": "银行经营贷", "type": "loan", "currency": "CNY", "balance": -500000.0, "hidden": 1,
                 "note": "已归档负债"},
                {"name": "投资款(VC)", "type": "investment", "currency": "CNY", "balance": 1000000.0, "hidden": 0},
                {"name": "办公设备", "type": "other", "currency": "CNY", "balance": 60000.0, "hidden": 0},
                {"name": "备用金账户", "type": "other", "currency": "CNY", "balance": 30000.0, "hidden": 1,
                 "note": "已归档"},
            ],
        },
        {
            "name": "家庭共用账本", "currency": "CNY", "ledger_type": "personal",
            "month_start_day": 15,
            "accounts": [
                {"name": "家庭公用金", "type": "cash", "currency": "CNY", "balance": 5000.0, "hidden": 0},
                {"name": "家庭联名卡", "type": "bank_card", "currency": "CNY", "balance": 80000.0, "hidden": 0,
                 "bank_name": "中国银行", "card_last_four": "2256"},
                {"name": "家庭支付宝", "type": "alipay", "currency": "CNY", "balance": 15000.0, "hidden": 0},
                {"name": "家庭微信", "type": "wechat", "currency": "CNY", "balance": 6000.0, "hidden": 0},
                {"name": "家庭信用卡", "type": "credit_card", "currency": "CNY", "balance": -9000.0, "hidden": 0,
                 "credit_limit": 80000.0, "billing_day": 8, "payment_due_day": 26,
                 "bank_name": "中信银行", "card_last_four": "7741"},
                {"name": "房贷", "type": "loan", "currency": "CNY", "balance": -1200000.0, "hidden": 0},
                {"name": "子女教育金", "type": "investment", "currency": "CNY", "balance": 120000.0, "hidden": 0},
                {"name": "家庭保险", "type": "insurance", "currency": "CNY", "balance": 88000.0, "hidden": 0},
                {"name": "车位价值", "type": "real_estate", "currency": "CNY", "balance": 200000.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "人情往来", "type": "other", "currency": "CNY", "balance": 4000.0, "hidden": 1,
                 "note": "已归档"},
            ],
        },
    ],
}

# ---------------------------------------------------------------------------
# 设备 B (端口 16416) —— 备用机/平板场景（与前机命名与主题完全区分）
# ---------------------------------------------------------------------------
DEVICE_B = {
    "port": 16416,
    "ledgers": [
        {
            "name": "学生生活账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 1,
            "accounts": [
                {"name": "校园一卡通", "type": "other", "currency": "CNY", "balance": 300.0, "hidden": 0},
                {"name": "饭卡", "type": "other", "currency": "CNY", "balance": 500.0, "hidden": 0},
                {"name": "生活费储蓄卡", "type": "bank_card", "currency": "CNY", "balance": 8000.0, "hidden": 0,
                 "bank_name": "农业银行", "card_last_four": "6610"},
                {"name": "微信零钱", "type": "wechat", "currency": "CNY", "balance": 1200.0, "hidden": 0},
                {"name": "学生支付宝", "type": "alipay", "currency": "CNY", "balance": 2400.0, "hidden": 0},
                {"name": "随身现金", "type": "cash", "currency": "CNY", "balance": 600.0, "hidden": 0},
                {"name": "助学贷款", "type": "loan", "currency": "CNY", "balance": -32000.0, "hidden": 0},
                {"name": "奖学金储蓄", "type": "investment", "currency": "CNY", "balance": 5000.0, "hidden": 0},
                {"name": "实习工资卡", "type": "bank_card", "currency": "CNY", "balance": 15000.0, "hidden": 0,
                 "bank_name": "招商银行", "card_last_four": "3314"},
                {"name": "旧机折现", "type": "other", "currency": "CNY", "balance": 800.0, "hidden": 1,
                 "note": "已归档"},
            ],
        },
        {
            "name": "自由职业账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 5,
            "accounts": [
                {"name": "业务收入卡", "type": "bank_card", "currency": "CNY", "balance": 60000.0, "hidden": 0,
                 "bank_name": "民生银行", "card_last_four": "7742"},
                {"name": "支付宝(经营)", "type": "alipay", "currency": "CNY", "balance": 22000.0, "hidden": 0},
                {"name": "微信收款", "type": "wechat", "currency": "CNY", "balance": 9000.0, "hidden": 0},
                {"name": "业务现金", "type": "cash", "currency": "CNY", "balance": 3000.0, "hidden": 0},
                {"name": "信用卡(报税)", "type": "credit_card", "currency": "CNY", "balance": -6000.0, "hidden": 0,
                 "credit_limit": 30000.0, "billing_day": 12, "payment_due_day": 30,
                 "bank_name": "广发银行", "card_last_four": "5589"},
                {"name": "办公设备", "type": "other", "currency": "CNY", "balance": 20000.0, "hidden": 0},
                {"name": "稿费储蓄", "type": "investment", "currency": "CNY", "balance": 40000.0, "hidden": 0},
                {"name": "待缴税款", "type": "other", "currency": "CNY", "balance": -8000.0, "hidden": 1,
                 "note": "已归档待缴"},
                {"name": "社保(自由职业)", "type": "social_fund", "currency": "CNY", "balance": 18000.0, "hidden": 0},
                {"name": "商业医疗险", "type": "insurance", "currency": "CNY", "balance": 12000.0, "hidden": 0},
            ],
        },
        {
            "name": "跨境海淘账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 10,
            "accounts": [
                {"name": "美元现金", "type": "cash", "currency": "USD", "balance": 800.0, "hidden": 0},
                {"name": "美元信用卡", "type": "credit_card", "currency": "USD", "balance": -400.0, "hidden": 0,
                 "credit_limit": 8000.0, "billing_day": 3, "payment_due_day": 21,
                 "bank_name": "MasterCard", "card_last_four": "4456"},
                {"name": "日元现金", "type": "cash", "currency": "JPY", "balance": 50000.0, "hidden": 0},
                {"name": "英镑银行卡", "type": "bank_card", "currency": "GBP", "balance": 2000.0, "hidden": 0,
                 "bank_name": "Barclays", "card_last_four": "8890"},
                {"name": "欧元现金", "type": "cash", "currency": "EUR", "balance": 1200.0, "hidden": 0},
                {"name": "新加坡元卡", "type": "bank_card", "currency": "SGD", "balance": 3000.0, "hidden": 0,
                 "bank_name": "DBS", "card_last_four": "2231"},
                {"name": "澳元现金", "type": "cash", "currency": "AUD", "balance": 2500.0, "hidden": 0},
                {"name": "韩元现金", "type": "cash", "currency": "KRW", "balance": 300000.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "支付宝(海淘)", "type": "alipay", "currency": "CNY", "balance": 5000.0, "hidden": 0},
                {"name": "海外理财", "type": "investment", "currency": "USD", "balance": 12000.0, "hidden": 0},
            ],
        },
        {
            "name": "房产投资账本", "currency": "CNY", "ledger_type": "personal",
"month_start_day": 15,
            "accounts": [
                {"name": "房产现金", "type": "cash", "currency": "CNY", "balance": 20000.0, "hidden": 0},
                {"name": "租金收款卡", "type": "bank_card", "currency": "CNY", "balance": 95000.0, "hidden": 0,
                 "bank_name": "交通银行", "card_last_four": "5567"},
                {"name": "公寓A", "type": "real_estate", "currency": "CNY", "balance": 2200000.0, "hidden": 0},
                {"name": "公寓B", "type": "real_estate", "currency": "CNY", "balance": 1800000.0, "hidden": 0},
                {"name": "商铺", "type": "real_estate", "currency": "CNY", "balance": 3000000.0, "hidden": 0},
                {"name": "房贷A", "type": "loan", "currency": "CNY", "balance": -1100000.0, "hidden": 0},
                {"name": "房贷B", "type": "loan", "currency": "CNY", "balance": -900000.0, "hidden": 0},
                {"name": "装修储备", "type": "investment", "currency": "CNY", "balance": 150000.0, "hidden": 0},
                {"name": "车位", "type": "real_estate", "currency": "CNY", "balance": 250000.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "物业维修金", "type": "other", "currency": "CNY", "balance": 30000.0, "hidden": 1,
                 "note": "已归档"},
            ],
        },
        {
            "name": "亲友共享账本", "currency": "CNY", "ledger_type": "personal",
            "month_start_day": 20,
            "accounts": [
                {"name": "聚餐公摊金", "type": "cash", "currency": "CNY", "balance": 3000.0, "hidden": 0},
                {"name": "群体联名卡", "type": "bank_card", "currency": "CNY", "balance": 40000.0, "hidden": 0,
                 "bank_name": "平安银行", "card_last_four": "1190"},
                {"name": "群支付宝", "type": "alipay", "currency": "CNY", "balance": 8000.0, "hidden": 0},
                {"name": "群微信", "type": "wechat", "currency": "CNY", "balance": 5000.0, "hidden": 0},
                {"name": "群体信用卡", "type": "credit_card", "currency": "CNY", "balance": -4000.0, "hidden": 0,
                 "credit_limit": 60000.0, "billing_day": 18, "payment_due_day": 6,
                 "bank_name": "光大银行", "card_last_four": "6630"},
                {"name": "旅行基金", "type": "investment", "currency": "CNY", "balance": 60000.0, "hidden": 0},
                {"name": "团体保险", "type": "insurance", "currency": "CNY", "balance": 30000.0, "hidden": 0},
                {"name": "租赁设备", "type": "other", "currency": "CNY", "balance": 12000.0, "hidden": 0},
                {"name": "押金池", "type": "other", "currency": "CNY", "balance": 9000.0, "hidden": 1,
                 "note": "已归档"},
                {"name": "备用金", "type": "cash", "currency": "CNY", "balance": 2000.0, "hidden": 1,
                 "note": "已归档"},
            ],
        },
    ],
}


def inject_device(spec):
    port = spec["port"]
    db_path = DB_FILES[port]
    if not os.path.exists(db_path):
        print(f"[SKIP] {db_path} 不存在")
        return

    print(f"\n========== 设备端口 {port}: {db_path} ==========")
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA busy_timeout = 15000")
    cur = con.cursor()

    # 运行中的 app 可能持有锁；显式开启事务并尽量短事务
    cur.execute("BEGIN IMMEDIATE")
    try:
        # 现有账本名 / 账户名（用于幂等跳过）
        existing_ledger_names = {
            r[0] for r in cur.execute("SELECT name FROM ledgers").fetchall()
        }
        existing_account_names = {
            r[0] for r in cur.execute("SELECT name FROM accounts").fetchall()
        }

        ledgers_added = 0
        accounts_added = 0

        for lg in spec["ledgers"]:
            if lg["name"] in existing_ledger_names:
                # 账本已存在：复用其 id，仅补齐缺失账户（行级幂等）
                cur.execute("SELECT id FROM ledgers WHERE name=?", (lg["name"],))
                row = cur.fetchone()
                if not row:
                    print(f"  [异常] 账本名在集合但无记录: {lg['name']}")
                    continue
                ledger_id = row[0]
                ledger_sync_id = cur.execute(
                    "SELECT sync_id FROM ledgers WHERE id=?", (ledger_id,)
                ).fetchone()[0]
                print(f"  [复用账本] id={ledger_id} {lg['name']} (补齐缺失账户)")
            else:
                ledger_sync_id = str(uuid.uuid4())
                cur.execute(
                    """
                    INSERT INTO ledgers
                        (name, currency, type, created_at, sync_id, month_start_day)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        lg["name"], lg["currency"], lg["ledger_type"], NOW,
                        ledger_sync_id, lg["month_start_day"],
                    ),
                )
                ledger_id = cur.lastrowid
                ledgers_added += 1
                existing_ledger_names.add(lg["name"])
                print(f"  [+账本] id={ledger_id} {lg['name']} "
                      f"(type={lg['ledger_type']}, cur={lg['currency']}, "
                      f"start_day={lg['month_start_day']})")

            for idx, acc in enumerate(lg["accounts"]):
                if acc["name"] in existing_account_names:
                    print(f"      [跳过账户] 已存在: {acc['name']}")
                    continue
                cur.execute(
                    """
                    INSERT INTO accounts
                        (ledger_id, name, type, currency, initial_balance,
                         created_at, updated_at, sort_order, credit_limit,
                         billing_day, payment_due_day, bank_name, card_last_four,
                         note, sync_id, hidden)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        ledger_id, acc["name"], acc["type"], acc["currency"],
                        acc["balance"], NOW, NOW, idx,
                        acc.get("credit_limit"), acc.get("billing_day"),
                        acc.get("payment_due_day"), acc.get("bank_name"),
                        acc.get("card_last_four"), acc.get("note"),
                        str(uuid.uuid4()), acc.get("hidden", 0),
                    ),
                )
                accounts_added += 1
                existing_account_names.add(acc["name"])

        # 多币种汇率（base=CNY），便于净资产折算调试
        fx_added = 0
        for quote, rate in FX_RATES.items():
            cur.execute(
                """
                INSERT OR IGNORE INTO exchange_rates
                    (base_currency, quote_currency, rate_date, rate, source, fetched_at)
                VALUES ('CNY', ?, ?, ?, 'manual', ?)
                """,
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


def verify(db_path):
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    ledger_cnt = cur.execute("SELECT COUNT(*) FROM ledgers").fetchone()[0]
    acct_cnt = cur.execute("SELECT COUNT(*) FROM accounts").fetchone()[0]
    orphan = cur.execute(
        "SELECT COUNT(*) FROM accounts a LEFT JOIN ledgers l ON a.ledger_id=l.id "
        "WHERE l.id IS NULL"
    ).fetchone()[0]
    # 新注入账本各自账户数
    cur.execute(
        "SELECT l.name, COUNT(a.id) FROM ledgers l "
        "LEFT JOIN accounts a ON a.ledger_id=l.id GROUP BY l.id ORDER BY l.id DESC LIMIT 10"
    )
    rows = cur.fetchall()
    con.close()
    return ledger_cnt, acct_cnt, orphan, rows


def main():
    for spec in (DEVICE_A, DEVICE_B):
        inject_device(spec)

    print("\n========== 校验 ==========")
    for port, path in DB_FILES.items():
        if os.path.exists(path):
            lc, ac, orph, rows = verify(path)
            print(f"\n[端口 {port}] 账本总数={lc}, 账户总数={ac}, 孤儿账户(无对应账本)={orph}")
            print("  最近账本 -> 账户数:")
            for name, cnt in rows:
                print(f"    - {name}: {cnt}")


if __name__ == "__main__":
    main()
