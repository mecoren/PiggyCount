# -*- coding: utf-8 -*-
"""
PiggyCount —— 向 16384 设备拉取的库注入 S3/WebDAV 同步测试数据
================================================================
目标(对 scripts/live_db/seed_16384.sqlite 就地注入):
  * 默认账本(id=1) + 5 个新账本,每个 ~1000 条交易
  * 「历史回忆账本」= 2013-2015 历史数据;其余账本 = 最近 2~3 年
  * 每个账本都有 微信/支付宝 账户,大额占比的真实商户备注(扫码/外卖/打车等)
  * 层级分类(L1+L2, 快照导出 parentName 链路)/ 15 标签 / 预算 / 周期交易 /
    汇率覆盖 / 真实 JPEG 附件(内容寻址 attachments/<sha256>.bin 上传链路)
  * 全部实体写 local_changes,启动后 fullPush / 增量 push 都能推上云
  * 海外账本 month_start_day=25,验证快照 monthStartDay 字段

运行: python scripts/inject_16384_sync_test.py
"""

import hashlib
import io
import os
import random
import sqlite3
import sys
import time
import uuid
from datetime import datetime

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "scripts", "live_db", "seed_16384.sqlite")
ATT_DIR = os.path.join(ROOT, "scripts", "live_db", "seed_attachments")
NOW = int(time.time())
OWNER = "dev-owner-16384"

# 与 app seed_service.dart 完全一致的确定性 syncId 体系(uuid v5):
# 本轮库是清库后的全新 schema(ledgers 为空、无 seed),必须先复刻应用的
# ensureSeed 成果(默认账本/虚拟转账分类/默认账户),否则注入脚本的
# "默认账本 id=1" 前提不成立,且 16416 恢复后两端的默认实体身份不同源。
SEED_NS = uuid.UUID("b3e7c0de-0000-4000-8000-beec00000001")

def seed_sync_id(name: str) -> str:
    return str(uuid.uuid5(SEED_NS, name))

FX_RATE = {"CNY": 1.0, "USD": 7.10, "JPY": 0.048, "EUR": 7.70, "HKD": 0.91,
           "GBP": 9.00, "SGD": 5.30, "AUD": 4.70, "KRW": 0.0052, "THB": 0.20}
FX_QUOTES = {k: v for k, v in FX_RATE.items() if k != "CNY"}

TX_PER_LEDGER = 1000
TYPE_WEIGHTS = [("expense", 0.62), ("income", 0.22), ("transfer", 0.11), ("adjustment", 0.05)]

# 各账本定义: 时间窗 / 月起始日 / 共享 / 账户规格 (type, currency, hidden)
def recent_years(n):
    return NOW - int(n * 365.25 * 86400), NOW

HIST_START = int(datetime(2013, 1, 1).timestamp())
HIST_END = int(datetime(2016, 1, 1).timestamp())

LEDGERS = [
    {"name": "历史回忆账本", "start": HIST_START, "end": HIST_END, "msd": 1,
     "accs": [
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("alipay", "CNY", 0),
        ("wechat", "CNY", 0), ("cash", "CNY", 0), ("bank_card", "CNY", 0)]},
    {"name": "日常消费账本", "start": recent_years(3)[0], "end": NOW, "msd": 1,
     "accs": [
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("credit_card", "CNY", 0),
        ("alipay", "CNY", 0), ("wechat", "CNY", 0), ("cash", "USD", 0),
        ("bank_card", "CNY", 0), ("other", "CNY", 0), ("social_fund", "CNY", 0),
        ("cash", "CNY", 1)]},
    {"name": "海外旅行账本", "start": recent_years(2)[0], "end": NOW, "msd": 25,
     "accs": [
        ("cash", "USD", 0), ("cash", "EUR", 0), ("cash", "JPY", 0),
        ("wechat", "HKD", 0), ("alipay", "USD", 0), ("bank_card", "SGD", 0),
        ("credit_card", "EUR", 0), ("cash", "THB", 0), ("other", "CNY", 0)]},
    {"name": "创业公司账本", "start": recent_years(2)[0], "end": NOW, "msd": 1,
     "accs": [
        ("bank_card", "CNY", 0), ("credit_card", "CNY", 0), ("loan", "CNY", 0),
        ("alipay", "CNY", 0), ("wechat", "CNY", 0), ("investment", "CNY", 0),
        ("cash", "CNY", 0), ("bank_card", "USD", 0)]},
    {"name": "家庭共用账本", "start": recent_years(3)[0], "end": NOW, "msd": 10,
     "accs": [
        ("cash", "CNY", 0), ("bank_card", "CNY", 0), ("alipay", "CNY", 0),
        ("wechat", "CNY", 0), ("credit_card", "CNY", 0), ("social_fund", "CNY", 0),
        ("other", "CNY", 0), ("cash", "USD", 0)]},
]

TYPE_LABEL = {"cash": "现金", "bank_card": "储蓄卡", "credit_card": "信用卡",
              "alipay": "支付宝", "wechat": "微信零钱", "other": "其他",
              "investment": "投资账户", "social_fund": "社保", "loan": "贷款"}

# 微信/支付宝真实场景商户池 (备注, 基准金额区间CNY, 权重)
WECHAT_MERCHANTS = [
    ("瑞幸咖啡-扫码购", (9.9, 35), 3.0), ("美团外卖-午餐", (18, 55), 3.0),
    ("滴滴出行-快车", (12, 60), 2.0), ("地铁乘车码", (3, 8), 2.5),
    ("永辉超市-日常采购", (30, 260), 1.5), ("拼多多-日用品", (10, 80), 1.2),
    ("饿了么-晚餐", (20, 60), 1.5), ("电影票-淘票票", (35, 90), 0.8),
    ("共享单车月卡", (15, 25), 0.6), ("微信转账-红包", (20, 200), 0.8),
]
ALIPAY_MERCHANTS = [
    ("淘宝-服饰", (60, 600), 2.0), ("京东-数码家电", (100, 3000), 1.0),
    ("话费充值", (50, 100), 1.0), ("电费-生活缴费", (80, 350), 0.8),
    ("水费-生活缴费", (20, 80), 0.6), ("盒马-生鲜", (40, 300), 1.2),
    ("支付宝-信用卡还款", (500, 5000), 0.6), ("饿了么-外卖", (18, 60), 1.5),
    ("滴滴出行-加油", (200, 450), 0.5), ("机票-飞猪", (400, 2500), 0.4),
]
# 历史账本(2013-2015)专属备注
HIST_EXPENSE_NOTES = [
    ("校园食堂-午餐", (6, 15), 3.0), ("网吧-上网", (10, 30), 1.5),
    ("火车票-12306", (50, 300), 1.0), ("书店-教辅", (20, 80), 1.0),
    ("公交卡充值", (20, 50), 1.5), ("话费充值-移动", (30, 100), 1.2),
    ("超市-周末采购", (40, 200), 1.2), ("KTV-同学聚会", (50, 200), 0.6),
    ("服装-班尼路", (80, 300), 0.8), ("电影票-万达", (30, 70), 0.8),
]
HIST_INCOME_NOTES = [("实习工资", (1500, 3000), 2.0), ("奖学金", (500, 3000), 0.8),
                     ("家教兼职", (300, 1200), 1.2), ("压岁钱", (500, 2000), 0.6),
                     ("生活费结余", (200, 800), 1.0)]
RECENT_INCOME_NOTES = [("月薪-工资卡", (8000, 25000), 3.0), ("年终奖", (10000, 50000), 0.5),
                       ("理财赎回-收益", (100, 3000), 1.0), ("兼职-咨询费", (500, 4000), 0.8),
                       ("退款-淘宝", (30, 500), 1.0), ("红包收入", (20, 500), 0.8)]

# 层级自定义分类: (名称, kind, [子分类...])  L2 走 parent_id+level=2
CUSTOM_CATS = [
    ("测-餐饮", "expense", ["早餐", "午餐", "晚餐", "外卖"]),
    ("测-交通", "expense", ["打车", "公交地铁", "加油"]),
    ("测-购物", "expense", ["服饰", "数码", "日用品"]),
    ("测-娱乐", "expense", ["电影", "游戏"]),
    ("测-居住", "expense", ["水电煤", "房租"]),
    ("测-旅行", "expense", ["机票", "酒店"]),
    ("测-工资", "income", ["月薪", "年终奖"]),
    ("测-理财", "income", ["基金收益"]),
    ("测-转账", "transfer", []),
]


def gen_amount(base_cny, currency):
    rate = FX_RATE.get(currency, 1.0)
    val = base_cny / rate if rate else base_cny
    if currency in ("JPY", "KRW"):
        return float(round(val))
    return round(val, 2)


def pick_weighted(pool, rnd):
    total = sum(w for _, _, w in pool)
    r = rnd.random() * total
    cum = 0.0
    for item in pool:
        cum += item[2]
        if r <= cum:
            return item
    return pool[-1]


def make_acc_name(tag, atype, cur_code, hidden, used):
    label = TYPE_LABEL.get(atype, atype)
    base = f"{tag}-{label}{cur_code}"
    cand = base + ("-隐藏" if hidden else "")
    n = 1
    while cand in used:
        cand = f"{base}-{n}"
        n += 1
    used.add(cand)
    return cand


def add_changes_bulk(cur, rows):
    cur.executemany(
        "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, ledger_id, action, created_at, pushed_at) "
        "VALUES (?,?,?,?,?,?,NULL)", (r + (NOW,) for r in rows))


def make_jpegs():
    """PIL 生成 8 张不同内容的小 JPEG → (sha256, bytes, w, h);其中两张内容一致验证去重。"""
    from PIL import Image, ImageDraw
    os.makedirs(ATT_DIR, exist_ok=True)
    specs = []
    palettes = [(220, 60, 60), (60, 140, 220), (70, 180, 90), (240, 180, 40),
                (150, 80, 200), (240, 120, 30), (40, 190, 180), (90, 90, 100)]
    for i, rgb in enumerate(palettes):
        w, h = 320 + i * 40, 240
        img = Image.new("RGB", (w, h), rgb)
        d = ImageDraw.Draw(img)
        for y in range(0, h, 24):
            d.line([(0, y), (w, y)], fill=tuple(min(255, c + 50) for c in rgb), width=3)
        d.rectangle([10, 10, w - 10, h - 10], outline=(255, 255, 255), width=4)
        d.text((16, 16), f"PiggyCount sync-test attachment #{i+1}", fill=(255, 255, 255))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=82)
        specs.append((buf.getvalue(), w, h))
    # 第 8 张与第 1 张内容一致 → 同 sha,测试内容寻址去重
    specs[7] = specs[0]
    out = []
    for data, w, h in specs:
        sha = hashlib.sha256(data).hexdigest()
        with open(os.path.join(ATT_DIR, f"sha_{sha}.jpg"), "wb") as f:
            f.write(data)
        out.append({"sha": sha, "size": len(data), "w": w, "h": h})
    return out


def main():
    if not os.path.exists(DB):
        print("[FAIL] 未找到", DB, "—— 请先从 16384 拉取数据库")
        sys.exit(1)
    con = sqlite3.connect(DB)
    con.execute("PRAGMA busy_timeout = 30000")
    cur = con.cursor()

    tx_existing = cur.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]
    lg_existing = cur.execute("SELECT COUNT(*) FROM ledgers").fetchone()[0]
    if tx_existing > 0 or lg_existing > 1:
        print(f"[ABORT] 库非空(ledgers={lg_existing}, tx={tx_existing}), 防止重复注入")
        sys.exit(1)

    changes = []  # (entity_type, entity_id, entity_sync_id, ledger_id, action)

    # ---------- 0) 复刻应用 seed(全新空库时) ----------
    # 等价于 welcome 页 ensureSeed 的产物:默认账本(确定性 syncId)+
    # 虚拟转账分类 + 3 个默认账户。均写 local_changes 走正常推送。
    n_seed = 0
    if cur.execute("SELECT COUNT(*) FROM ledgers").fetchone()[0] == 0:
        print("=== 复刻应用 seed(空库) ===")
        cur.execute(
            "INSERT INTO ledgers (name, currency, type, created_at, sync_id, month_start_day) "
            "VALUES ('默认账本','CNY','personal',?,?,1)",
            (NOW, seed_sync_id("ledger:default")))
        assert cur.lastrowid == 1, f"默认账本应拿 id=1, 实际 {cur.lastrowid}"
        changes.append(("ledger", 1, seed_sync_id("ledger:default"), 1, "upsert"))
        # 虚拟转账分类:sort_order=-1, kind='transfer'
        cur.execute(
            "INSERT INTO categories (name, kind, icon, sort_order, level, icon_type, sync_id) "
            "VALUES ('转账','transfer','swap_horiz',-1,1,'material',?)",
            (seed_sync_id("cat:transfer:1:transfer"),))
        changes.append(("category", cur.lastrowid, seed_sync_id("cat:transfer:1:transfer"), 0, "upsert"))
        # 3 个默认账户(与 createDefaultAccounts 同名同 syncId)
        for atype, aname in (("cash", "现金"), ("bank_card", "储蓄卡"), ("credit_card", "信用卡")):
            cur.execute(
                "INSERT INTO accounts (ledger_id, name, type, currency, initial_balance, "
                "created_at, updated_at, sort_order, sync_id) VALUES (1,?,?, 'CNY',0.0,?,?,0,?)",
                (aname, atype, NOW, NOW, seed_sync_id(f"acc:{atype}")))
            changes.append(("account", cur.lastrowid, seed_sync_id(f"acc:{atype}"), 0, "upsert"))
        n_seed = 5
        print(f"  默认账本/转账分类/3默认账户 (确定性 syncId, {n_seed} 条 local_changes)")

    # ---------- 1) 账本 ----------
    print("=== 账本 ===")
    all_ledgers = []  # (id, name, tag, cfg, created_by)
    # 默认账本:seed 复刻路径已用确定性 syncId 建好 id=1;若来自旧库
    # (id=1 已存在但无 sync_id)则补随机 UUID。两种路径都收进 local_changes。
    def_row = cur.execute("SELECT id, sync_id FROM ledgers WHERE id=1").fetchone()
    if def_row is None:
        raise SystemExit("[FAIL] 默认账本 id=1 不存在(seed 复刻未生效)")
    if not def_row[1]:
        def_sync = str(uuid.uuid4())
        cur.execute("UPDATE ledgers SET sync_id=? WHERE id=1", (def_sync,))
        changes.append(("ledger", 1, def_sync, 1, "upsert"))
        # 旧库补 sync_id 路径:seed 复刻未跑过,这里首次入列;新库路径
        # seed 复刻段已入列,上面 if 不触发,不会重复 append。
    else:
        def_sync = def_row[1]
    # 默认账本账户规格:seed 已建 现金/储蓄卡/信用卡(CNY,确定性 syncId),
    # 这里只补差异账户,避免同名同类型重复。
    all_ledgers.append((1, "默认账本", "默认", {
        "start": recent_years(3)[0], "end": NOW, "msd": 1, "accs": [
            ("alipay", "CNY", 0), ("wechat", "CNY", 0), ("cash", "USD", 0),
            ("other", "CNY", 0)]}, OWNER))

    for cfg in LEDGERS:
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO ledgers (name, currency, type, created_at, sync_id, month_start_day) "
            "VALUES (?,?,?,?,?,?)",
            (cfg["name"], "CNY", "personal", NOW, sid, cfg["msd"]))
        lid = cur.lastrowid
        changes.append(("ledger", lid, sid, lid, "upsert"))
        tag = cfg["name"][:2]
        all_ledgers.append((lid, cfg["name"], tag, cfg, OWNER))
        print(f"  [+{lid}] {cfg['name']} msd={cfg['msd']} "
              f"区间={datetime.fromtimestamp(cfg['start']):%Y-%m-%d}~{datetime.fromtimestamp(cfg['end']):%Y-%m-%d}")

    # ---------- 2) 层级分类 ----------
    print("=== 层级分类 ===")
    cat_pool = {"expense": [], "income": [], "transfer": []}
    for i, (name, kind, children) in enumerate(CUSTOM_CATS):
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO categories (name, kind, icon, sort_order, level, icon_type, sync_id) "
            "VALUES (?,?,?,?,?,?,?)", (name, kind, "restaurant", 100 + i, 1, "material", sid))
        cid = cur.lastrowid
        cat_pool[kind].append(cid)
        changes.append(("category", cid, sid, 0, "upsert"))
        for j, ch in enumerate(children):
            csid = str(uuid.uuid4())
            cur.execute(
                "INSERT INTO categories (name, kind, icon, sort_order, parent_id, level, icon_type, sync_id) "
                "VALUES (?,?,?,?,?,?,?,?)", (f"{name}-{ch}", kind, "label", 200 + j, cid, 2, "material", csid))
            chid = cur.lastrowid
            cat_pool[kind].append(chid)
            changes.append(("category", chid, csid, 0, "upsert"))
    print(f"  L1={len(CUSTOM_CATS)} L2={sum(len(c) for _,_,c in CUSTOM_CATS)}")

    # ---------- 3) 标签 ----------
    print("=== 标签 ===")
    tag_ids = []
    for i in range(1, 16):
        sid = str(uuid.uuid4())
        cur.execute("INSERT INTO tags (name, color, sort_order, created_at, sync_id) VALUES (?,?,?,?,?)",
                    (f"测-标签{i}", "#1976d2", i, NOW, sid))
        tid = cur.lastrowid
        tag_ids.append(tid)
        changes.append(("tag", tid, sid, 0, "upsert"))
    print(f"  {len(tag_ids)} 个")

    # ---------- 4) 账户 ----------
    print("=== 账户 ===")
    random.seed(16384)
    ledger_accounts = {}  # lid -> [(acc_id, currency, is_wx_alipay)]
    for lid, lname, tag, cfg, owner in all_ledgers:
        accs = []
        used = set()
        for idx, (atype, cur_code, hidden) in enumerate(cfg["accs"]):
            name = make_acc_name(tag, atype, cur_code, hidden, used)
            if atype in ("investment",):
                balance = round(random.uniform(10000, 500000), 2)
            elif atype == "loan":
                balance = -round(random.uniform(10000, 300000), 2)
            elif atype == "social_fund":
                balance = round(random.uniform(0, 150000), 2)
            elif atype == "credit_card":
                balance = 0.0
            else:
                balance = round(random.uniform(100, 80000), 2)
            sid = str(uuid.uuid4())
            credit_limit = billing = due = bank = last4 = None
            if atype == "credit_card":
                credit_limit, billing, due = 50000.0, 5, 25
                bank, last4 = "招商银行", str(random.randint(1000, 9999))
            elif atype == "bank_card":
                bank = "招商银行" if cur_code == "CNY" else "Citibank"
                last4 = str(random.randint(1000, 9999))
            note = f"{lname}·{TYPE_LABEL.get(atype, atype)}"
            cur.execute(
                "INSERT INTO accounts (ledger_id, name, type, currency, initial_balance, created_at, "
                "updated_at, sort_order, credit_limit, billing_day, payment_due_day, bank_name, "
                "card_last_four, note, sync_id, hidden) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (lid, name, atype, cur_code, balance, NOW, NOW, idx, credit_limit, billing,
                 due, bank, last4, note, sid, hidden))
            aid = cur.lastrowid
            accs.append((aid, cur_code, atype in ("wechat", "alipay")))
            changes.append(("account", aid, sid, 0, "upsert"))
        ledger_accounts[lid] = accs
        print(f"  [{lid} {lname}] {len(accs)} 个 (微信/支付宝: {sum(1 for a in accs if a[2])})")

    # 默认账本:并入 seed 建的 3 个默认账户(现金/储蓄卡/信用卡)参与交易,
    # 否则这三个账户零流水,与真实设备形态不符。
    seeded = cur.execute(
        "SELECT id, currency FROM accounts WHERE ledger_id=1 AND sync_id IN (?,?,?)",
        (seed_sync_id("acc:cash"), seed_sync_id("acc:bank_card"),
         seed_sync_id("acc:credit_card"))).fetchall()
    if seeded:
        ledger_accounts[1] = [(r[0], r[1], False) for r in seeded] + ledger_accounts[1]
        print(f"  [1 默认账本] 并入 seed 默认账户 {len(seeded)} 个参与交易")

    # ---------- 5) 交易 ----------
    print("=== 交易 ===")
    random.seed(20260824)
    total_tx = 0
    for lid, lname, tag, cfg, owner in all_ledgers:
        accs = ledger_accounts[lid]
        wx_accs = [a for a in accs if a[2]]
        normal_accs = [a for a in accs if not a[2]] or accs
        acc_cur = {a[0]: a[1] for a in accs}
        ex = cat_pool["expense"]
        inc = cat_pool["income"]
        tr = cat_pool["transfer"]
        is_hist = lname == "历史回忆账本"
        exp_pool = HIST_EXPENSE_NOTES if is_hist else WECHAT_MERCHANTS + ALIPAY_MERCHANTS
        inc_pool = HIST_INCOME_NOTES if is_hist else RECENT_INCOME_NOTES
        rows, tx_tags = [], []
        for k in range(TX_PER_LEDGER):
            r = random.random()
            cum = 0.0
            ttype = "expense"
            for t, w in TYPE_WEIGHTS:
                cum += w
                if r <= cum:
                    ttype = t
                    break
            if ttype == "expense":
                # ~55% 走微信/支付宝(历史账本走 现金/银行卡)
                if not is_hist and wx_accs and random.random() < 0.55:
                    account_id = random.choice(wx_accs)[0]
                else:
                    account_id = random.choice(normal_accs)[0]
                note, (lo, hi), _ = pick_weighted(exp_pool, random)
                base = random.uniform(lo, hi)
                category_id = random.choice(ex) if ex else None
                to_account_id = None
            elif ttype == "income":
                account_id = random.choice(normal_accs)[0]
                note, (lo, hi), _ = pick_weighted(inc_pool, random)
                base = random.uniform(lo, hi)
                category_id = random.choice(inc) if inc else None
                to_account_id = None
            elif ttype == "transfer":
                account_id = random.choice(accs)[0]
                others = [a for a in accs if a[0] != account_id]
                to_account_id = random.choice(others)[0] if others else None
                note = "转账-还信用卡" if random.random() < 0.5 else "转账-归集"
                base = random.uniform(100, 20000) if not is_hist else random.uniform(50, 2000)
                # 应用正常路径不给 transfer 交易挂分类(导入端也会置 null,
                # data_import_service.dart:1461),造数对齐避免形态差异
                category_id = None
            else:  # adjustment
                account_id = random.choice(accs)[0]
                note = "余额校准"
                base = random.uniform(-500, 500)
                category_id = None
                to_account_id = None
            currency = acc_cur[account_id]
            amount = gen_amount(base, currency)
            native = round(amount * FX_RATE.get(currency, 1.0), 2)
            happened_at = random.randint(cfg["start"], cfg["end"] - 1)
            exclude_stats = 1 if random.random() < 0.04 else 0
            exclude_budget = 1 if random.random() < 0.04 else 0
            created_by = owner
            sid = str(uuid.uuid4())
            rows.append((lid, ttype, amount, category_id, account_id, to_account_id,
                         happened_at, f"{note}", sid, created_by, created_by,
                         exclude_stats, exclude_budget, currency, native))
            if random.random() < 0.3:
                tx_tags.append((len(rows) - 1, random.choice(tag_ids)))
        cur.executemany(
            "INSERT INTO transactions (ledger_id, type, amount, category_id, account_id, "
            "to_account_id, happened_at, note, sync_id, created_by_user_id, last_edited_by_user_id, "
            "exclude_from_stats, exclude_from_budget, currency_code, native_amount) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
        # executemany 后 lastrowid 不可靠,AUTOINCREMENT 续号也不可控:
        # 按 ledger_id + sync_id 顺序取回本批真实 id 列表
        tx_ids = [r[0] for r in cur.execute(
            "SELECT id FROM transactions WHERE ledger_id=? ORDER BY id", (lid,)).fetchall()]
        assert len(tx_ids) == len(rows), f"tx_ids={len(tx_ids)} rows={len(rows)} 取回失败"
        for i, tid in enumerate(tx_ids):
            changes.append(("transaction", tid, rows[i][8], lid, "upsert"))
        cur.executemany("INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (?,?)",
                        [(tx_ids[i], t) for i, t in tx_tags])
        total_tx += len(rows)
        span = (datetime.fromtimestamp(min(r[6] for r in rows)),
                datetime.fromtimestamp(max(r[6] for r in rows)))
        wx_n = sum(1 for r in rows if any(r[4] == a[0] for a in wx_accs)) if not is_hist else 0
        print(f"  [{lid} {lname}] tx={len(rows)} 挂标签={len(tx_tags)} "
              f"微信/支付宝笔数={wx_n} 区间={span[0]:%Y-%m-%d}~{span[1]:%Y-%m-%d}")
    print(f"  合计 {total_tx} 条")

    # ---------- 6) 附件(真实 JPEG, 内容寻址) ----------
    print("=== 附件 ===")
    jpegs = make_jpegs()
    att_rows, att_files = [], []
    # G-ATT: 按账本**名**显式定位（不按 att_targets 下标推算）。
    # 本轮实测教训：账本 id 由 AUTOINCREMENT 续号,旧库残留行会把下标
    # 空间推扁/错位,跨账本去重附件落点随 id 漂移 —— 第 7 条附件挂到了
    # 同账本同交易上,「跨账本去重」验证语义失效。名字在 all_ledgers
    # 里稳定可寻,不受 id 断号影响。
    def tx_of_ledger(lname):
        lid = next(l[0] for l in all_ledgers if l[1] == lname)
        row = cur.execute(
            "SELECT id, sync_id FROM transactions WHERE ledger_id=? ORDER BY id LIMIT 1 OFFSET ?",
            (lid, TX_PER_LEDGER // 2)).fetchone()
        return lid, row[0], row[1]
    for i, (lid, lname, *_rest) in enumerate(all_ledgers):
        tid = tx_of_ledger(lname)[1]
        meta = jpegs[i % len(jpegs)]
        fname = f"sha_{meta['sha']}.jpg"
        cur.execute("SELECT id FROM transaction_attachments WHERE transaction_id=? AND local_sha256=?",
                    (tid, meta["sha"]))
        if cur.fetchone():
            continue
        cur.execute(
            "INSERT INTO transaction_attachments (transaction_id, file_name, original_name, file_size, "
            "width, height, sort_order, local_sha256, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (tid, fname, f"sync-test-{i+1}.jpg", meta["size"], meta["w"], meta["h"], 0,
             meta["sha"], NOW))
        att_files.append(fname)
    # 第 8 张与第 1 张同 sha:显式挂到「海外旅行账本」(与第 1 张所在的
    # 「默认账本」不同账本),验证跨账本去重 —— 落点不再随 id 推算漂移
    dup_meta = jpegs[0]
    _, tid2, _ = tx_of_ledger("海外旅行账本")
    cur.execute(
        "INSERT INTO transaction_attachments (transaction_id, file_name, original_name, file_size, "
        "width, height, sort_order, local_sha256, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
        (tid2, f"sha_{dup_meta['sha']}.jpg", "sync-test-dedup.jpg", dup_meta["size"],
         dup_meta["w"], dup_meta["h"], 0, dup_meta["sha"], NOW))
    att_files.append(f"sha_{dup_meta['sha']}.jpg")
    print(f"  {len(att_files)} 行附件, 物理文件 {len(jpegs)} 个 (含 1 个跨账本同内容去重)")
    print(f"  文件目录: {ATT_DIR}")

    # ---------- 7) 预算 ----------
    print("=== 预算 ===")
    random.seed(777)
    n_budget = 0
    for lid, lname, tag, cfg, owner in all_ledgers:
        ex = cat_pool["expense"]
        for j in range(3):
            sid = str(uuid.uuid4())
            btype = "total" if j == 0 else "category"
            cat_id = None if j == 0 else random.choice(ex)
            amount = round(random.uniform(2000, 30000), 2)
            cur.execute(
                "INSERT INTO budgets (sync_id, ledger_id, type, category_id, amount, period, "
                "start_day, enabled, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                (sid, lid, btype, cat_id, amount, "monthly", 1, 1, NOW, NOW))
            changes.append(("budget", cur.lastrowid, sid, lid, "upsert"))
            n_budget += 1
    print(f"  {n_budget} 条")

    # ---------- 8) 周期交易 ----------
    print("=== 周期交易 ===")
    random.seed(999)
    n_rec = 0
    for lid, lname, tag, cfg, owner in all_ledgers:
        accs = ledger_accounts[lid]
        ex, inc = cat_pool["expense"], cat_pool["income"]
        for j in range(3):
            sid = str(uuid.uuid4())
            rtype = "expense" if j < 2 else "income"
            amount = gen_amount(random.uniform(100, 5000), "CNY")
            cat_id = random.choice(ex if rtype == "expense" else inc)
            acc_id = random.choice(accs)[0]
            freq = "monthly" if j < 2 else "weekly"
            dom = random.randint(1, 28) if freq == "monthly" else None
            dow = random.randint(0, 6) if freq == "weekly" else None
            note = ("房租" if j == 0 else "会员订阅" if j == 1 else "理财定投") + f"-{lname}"
            cur.execute(
                "INSERT INTO recurring_transactions (ledger_id, sync_id, type, amount, category_id, "
                "account_id, to_account_id, note, frequency, interval, day_of_month, day_of_week, "
                "month_of_year, start_date, end_date, last_generated_date, enabled, created_at, updated_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (lid, sid, rtype, amount, cat_id, acc_id, None, note, freq, 1, dom, dow,
                 None, NOW, None, None, 1, NOW, NOW))
            changes.append(("recurring", cur.lastrowid, sid, lid, "upsert"))
            n_rec += 1
    print(f"  {n_rec} 条")

    # ---------- 9) 汇率覆盖 ----------
    print("=== 汇率覆盖 ===")
    for q, rate in FX_QUOTES.items():
        sid = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO exchange_rate_overrides (sync_id, base_currency, quote_currency, rate, updated_at) "
            "VALUES (?,?,?,?,?)", (sid, "CNY", q, str(rate), NOW))
        changes.append(("exchange_rate_override", cur.lastrowid, sid, 0, "upsert"))
    print(f"  {len(FX_QUOTES)} 条")

    # ---------- 提交 local_changes ----------
    add_changes_bulk(cur, changes)
    con.commit()

    # ---------- 校验 ----------
    print("\n=== 校验 ===")
    checks = {
        "账本": "SELECT COUNT(*) FROM ledgers",
        "账户": "SELECT COUNT(*) FROM accounts",
        "交易": "SELECT COUNT(*) FROM transactions",
        "分类": "SELECT COUNT(*) FROM categories",
        "L2分类": "SELECT COUNT(*) FROM categories WHERE level=2",
        "标签": "SELECT COUNT(*) FROM tags",
        "标签链接": "SELECT COUNT(*) FROM transaction_tags",
        "预算": "SELECT COUNT(*) FROM budgets",
        "周期": "SELECT COUNT(*) FROM recurring_transactions",
        "汇率覆盖": "SELECT COUNT(*) FROM exchange_rate_overrides",
        "附件": "SELECT COUNT(*) FROM transaction_attachments",
        "local_changes": "SELECT COUNT(*) FROM local_changes",
        "孤儿交易": "SELECT COUNT(*) FROM transactions t LEFT JOIN ledgers l ON t.ledger_id=l.id WHERE l.id IS NULL",
        "重复sync(change)": "SELECT COUNT(*) FROM (SELECT entity_sync_id FROM local_changes GROUP BY entity_sync_id HAVING COUNT(*)>1)",
    }
    for label, sql in checks.items():
        print(f"  {label} = {cur.execute(sql).fetchone()[0]}")
    for lid, lname, tag, cfg, owner in all_ledgers:
        n = cur.execute("SELECT COUNT(*) FROM transactions WHERE ledger_id=?", (lid,)).fetchone()[0]
        print(f"  账本[{lid} {lname}] tx={n}")
    con.close()
    print("\n[OK] 注入完成。下一步: 推回 DB + attachments 文件到 16384 并启动应用")


if __name__ == "__main__":
    main()
