#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 2024-2026 年微信支付账单 CSV（用于 PiggyCount 微信账单导入测试）。

输出：
  demo/wechat_bill_2024.csv
  demo/wechat_bill_2025.csv
  demo/wechat_bill_2026.csv

用法：
  python scripts/gen_wechat_bill_2024_2026.py

=== 为什么是这个格式 ===
严格对齐 PiggyCount 的微信账单解析链路：

1. lib/services/import/parsers/wechat_parser.dart
   - validateBillType / findHeaderRow 依赖前 30 行里出现同时含
     「交易时间」和「交易类型」的表头行；文件头部保留微信官方的 17 行说明区。

2. lib/services/import/csv_parser.dart
   - 逗号分隔，字段内含逗号/引号时用双引号包裹（csv 模块自动处理）。

3. lib/services/import/parsers/generic_parser.dart 的 _normalizeToKey 列映射：
     交易时间  -> date
     交易类型  -> category   （'交易类型' 命中分类关键字，先于 '类型'->type）
     交易对方  -> note       （note 只取第一个命中列，故 '商品' 不会覆盖它）
     收/支     -> type
     金额(元)  -> amount
     交易单号/商户单号 -> 显式忽略
     支付方式/当前状态/备注 -> 不映射（微信原样保留，导入时忽略）

4. lib/pages/data/import_confirm_page.dart
   - 收/支 列的值必须是「收入」或「支出」，其它值（如微信的「/」）会被计入
     skipped 跳过，因此本脚本只生成收入/支出两种，不产出「/」行。
   - 金额清洗规则 replaceAll(RegExp(r'[¥$,+-]'), '')，所以写成 "¥123.45" 安全，
     但金额千分位逗号也会被清掉，这里统一不加千分位。
   - 日期由 DateParser 解析，'yyyy-MM-dd HH:mm:ss' 在支持列表内。

=== 数据口径 ===
- 覆盖 2024-01-01 ~ 2026-12-31，每一天都有若干条记录（无空档日）。
- 每年支出总额落在 100 万 ~ 200 万区间；每年收入总额约 500 万。
- 收入以「工资/项目回款/货款」等大额低频条目为主，配合少量红包、退款、
  理财赎回等小额高频条目，使收入总额自然堆到 500 万而不显得离谱。
- 支出按分类给出符合现实的单笔金额区间（餐饮几十元、房租上万元），
  再由月度校准把年度总额收敛到目标值。
- 工作日/周末、节假日（春节/国庆/双 11 等）有消费强度差异。
- 交易对方、商品名与分类语义一致；支付方式/当前状态取微信真实枚举。
"""

from __future__ import annotations

import csv
import random
from calendar import monthrange
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

RANDOM_SEED = 20240101
YEARS = [2024, 2025, 2026]

# 年度目标（元）
EXPENSE_TARGET = {2024: 1_180_000.0, 2025: 1_460_000.0, 2026: 1_820_000.0}
INCOME_TARGET = {2024: 4_950_000.0, 2025: 5_050_000.0, 2026: 5_120_000.0}

OUT_DIR = Path(__file__).resolve().parent.parent / "demo"

HEADER = [
    "交易时间",
    "交易类型",
    "交易对方",
    "商品",
    "收/支",
    "金额(元)",
    "支付方式",
    "当前状态",
    "交易单号",
    "商户单号",
    "备注",
]

PAY_METHODS_EXPENSE = [
    "零钱",
    "招商银行储蓄卡(1234)",
    "工商银行储蓄卡(5678)",
    "建设银行信用卡(4321)",
    "浦发银行信用卡(8765)",
    "零钱通",
]
PAY_METHODS_INCOME = ["零钱", "招商银行储蓄卡(1234)", "工商银行储蓄卡(5678)", "零钱通"]


@dataclass(frozen=True)
class Spec:
    """一类交易的模板。

    category: 微信「交易类型」列取值
    counterparties: 交易对方候选
    goods: 商品候选
    low/high: 单笔金额区间（元）
    weight: 出现权重
    """

    category: str
    counterparties: tuple[str, ...]
    goods: tuple[str, ...]
    low: float
    high: float
    weight: float


# ---------------- 支出模板 ----------------
# 分成三档，便于把年度支出稳定拉到 100-200 万：
# daily（每天必有的小额）/ regular（周中随机）/ big（月度固定大额）

DAILY_EXPENSE: tuple[Spec, ...] = (
    Spec("商户消费", ("瑞幸咖啡", "星巴克", "Manner Coffee", "喜茶", "蜜雪冰城"),
         ("拿铁咖啡", "美式咖啡", "生椰拿铁", "多肉葡萄", "柠檬水"), 9.9, 42.0, 10),
    Spec("商户消费", ("美团", "饿了么", "麦当劳", "肯德基", "沙县小吃", "老乡鸡", "西贝莜面村"),
         ("外卖订单", "午餐套餐", "汉堡套餐", "拌面+馄饨", "招牌鸡汤", "晚餐"), 15.0, 128.0, 14),
    Spec("扫二维码付款", ("楼下便利店", "全家便利店", "罗森便利店", "美宜佳", "小区水果店"),
         ("日用百货", "饮料零食", "面包早餐", "苹果香蕉", "牛奶鸡蛋"), 6.5, 96.0, 10),
    Spec("交通出行", ("滴滴出行", "地铁乘车码", "公交乘车码", "高德打车", "T3出行"),
         ("网约车", "地铁票", "公交车费", "打车费用"), 2.0, 68.0, 9),
    Spec("商户消费", ("盒马鲜生", "永辉超市", "叮咚买菜", "沃尔玛", "山姆会员店"),
         ("生鲜采购", "蔬菜水果", "肉类水产", "日用清洁", "囤货采购"), 45.0, 480.0, 7),
)

REGULAR_EXPENSE: tuple[Spec, ...] = (
    Spec("商户消费", ("海底捞", "小龙坎", "外婆家", "绿茶餐厅", "必胜客", "眉州东坡"),
         ("聚餐", "火锅套餐", "家庭聚会", "双人餐"), 120.0, 860.0, 8),
    Spec("商户消费", ("京东商城", "天猫超市", "拼多多", "唯品会", "小米商城"),
         ("日用百货", "数码配件", "家居用品", "服饰鞋帽", "小家电"), 60.0, 2600.0, 8),
    Spec("商户消费", ("中国石化", "中国石油", "特来电充电", "星星充电"),
         ("加油", "充电服务", "92号汽油", "快充电费"), 80.0, 620.0, 5),
    Spec("商户消费", ("万达影城", "CGV影城", "KTV量贩", "剧本杀工作室", "健身工坊"),
         ("电影票", "娱乐消费", "包厢费用", "私教课程"), 45.0, 780.0, 4),
    Spec("商户消费", ("同仁堂药店", "美团买药", "社区卫生服务中心", "口腔诊所"),
         ("药品", "感冒药", "门诊挂号", "洗牙"), 25.0, 1200.0, 3),
    Spec("转账", ("张伟", "李娜", "王强", "刘洋", "陈静", "赵磊"),
         ("借款", "AA聚餐", "代付", "还钱"), 50.0, 3000.0, 5),
    Spec("微信红包", ("家庭群", "同事群", "同学群", "张伟", "李娜"),
         ("发红包", "节日红包", "生日红包"), 8.8, 888.0, 5),
    Spec("商户消费", ("腾讯视频", "网易云音乐", "Apple Services", "百度网盘", "WPS会员"),
         ("会员续费", "年费会员", "云存储服务", "订阅服务"), 15.0, 348.0, 4),
    Spec("扫二维码付款", ("小区快递驿站", "顺丰速运", "干洗店", "理发店", "宠物医院"),
         ("寄件费", "干洗服务", "剪发", "宠物疫苗", "取件"), 12.0, 680.0, 4),
    Spec("商户消费", ("携程旅行", "去哪儿旅行", "中国铁路12306", "航旅纵横", "亚朵酒店"),
         ("酒店住宿", "机票", "高铁票", "旅行套餐"), 180.0, 4200.0, 4),
    Spec("商户消费", ("新东方在线", "得到App", "极客时间", "中国大学MOOC"),
         ("课程学习", "专栏订阅", "培训报名"), 99.0, 3600.0, 2),
)

# 月度固定大额支出：每月固定发生，金额稳定，撑起年支出的基本盘
MONTHLY_EXPENSE: tuple[tuple[Spec, int], ...] = (
    # (模板, 每月发生在几号)
    (Spec("转账", ("房东王先生",), ("房租",), 6800.0, 7600.0, 1), 5),
    (Spec("生活缴费", ("国家电网",), ("电费",), 180.0, 620.0, 1), 12),
    (Spec("生活缴费", ("自来水公司",), ("水费",), 45.0, 130.0, 1), 12),
    (Spec("生活缴费", ("燃气公司",), ("燃气费",), 40.0, 220.0, 1), 13),
    (Spec("生活缴费", ("中国移动",), ("话费充值",), 59.0, 199.0, 1), 8),
    (Spec("生活缴费", ("长城宽带",), ("宽带续费",), 88.0, 158.0, 1), 8),
    (Spec("生活缴费", ("物业管理处",), ("物业费",), 320.0, 780.0, 1), 15),
    (Spec("商户消费", ("平安人寿", "中国人保"), ("保险费", "车险保费"), 800.0, 2600.0, 1), 18),
    (Spec("信用卡还款", ("建设银行信用卡", "浦发银行信用卡"), ("信用卡还款",), 3000.0, 12000.0, 1), 20),
    (Spec("转账", ("父亲", "母亲"), ("家用", "赡养费"), 2000.0, 5000.0, 1), 25),
)

# ---------------- 收入模板 ----------------

# 月度固定收入：工资 + 大额回款，是 500 万的主体
MONTHLY_INCOME: tuple[tuple[Spec, int], ...] = (
    (Spec("转账", ("云启科技有限公司",), ("工资",), 52000.0, 68000.0, 1), 10),
    (Spec("转账", ("云启科技有限公司",), ("绩效奖金",), 12000.0, 26000.0, 1), 10),
    (Spec("转账", ("星辰数字科技",), ("项目回款",), 120000.0, 210000.0, 1), 16),
    (Spec("转账", ("恒通商贸有限公司",), ("货款结算",), 90000.0, 185000.0, 1), 22),
    (Spec("商户消费", ("微信支付分账",), ("店铺结算",), 45000.0, 96000.0, 1), 28),
)

DAILY_INCOME: tuple[Spec, ...] = (
    Spec("微信红包", ("家庭群", "同事群", "同学群", "张伟", "李娜", "王强"),
         ("收红包", "节日红包", "生日红包"), 5.0, 520.0, 12),
    Spec("转账", ("张伟", "李娜", "王强", "刘洋", "陈静"),
         ("还款", "AA收款", "代付返还"), 30.0, 2600.0, 8),
    Spec("退款", ("京东商城", "天猫超市", "携程旅行", "拼多多", "美团"),
         ("订单退款", "取消订单退款", "退货退款"), 15.0, 1800.0, 5),
    Spec("零钱通收益", ("零钱通",), ("收益发放",), 1.2, 68.0, 8),
    Spec("商户消费", ("微信小店",), ("店铺收款", "顾客付款"), 200.0, 6800.0, 6),
    Spec("转账", ("恒通商贸有限公司", "星辰数字科技", "海联供应链"),
         ("货款", "服务费", "尾款"), 3000.0, 42000.0, 5),
)

# ---------------- 日历系数 ----------------

# 春节（除夕附近）区间：消费高峰
SPRING_FESTIVAL = {
    2024: (date(2024, 2, 9), date(2024, 2, 17)),
    2025: (date(2025, 1, 28), date(2025, 2, 4)),
    2026: (date(2026, 2, 16), date(2026, 2, 23)),
}


def day_factor(d: date) -> float:
    """返回当天的消费强度系数。"""
    f = 1.0
    if d.weekday() >= 5:  # 周末
        f *= 1.35
    start, end = SPRING_FESTIVAL[d.year]
    if start <= d <= end:
        f *= 2.1
    if d.month == 10 and 1 <= d.day <= 7:  # 国庆
        f *= 1.8
    if d.month == 5 and 1 <= d.day <= 5:  # 劳动节
        f *= 1.5
    if (d.month, d.day) in {(11, 11), (11, 12), (6, 18), (12, 12)}:  # 电商大促
        f *= 2.4
    if (d.month, d.day) == (12, 25) or (d.month, d.day) == (12, 31):
        f *= 1.4
    return f


def money(low: float, high: float, rng: random.Random) -> float:
    """在区间内取一个"像真实消费"的金额。

    偏向低值（对数均匀），并按量级做尾数修饰，避免全是 xx.37 这种机器味。
    """
    import math

    v = math.exp(rng.uniform(math.log(low), math.log(high)))
    if v < 100:
        v = round(v, 2)
    elif v < 1000:
        v = round(v, 1) if rng.random() < 0.4 else float(round(v))
    elif v < 20000:
        v = float(round(v))
        if rng.random() < 0.5:
            v = float(round(v / 10) * 10)
    else:
        v = float(round(v / 100) * 100)
    return max(0.01, v)


def pick(specs: tuple[Spec, ...], rng: random.Random) -> Spec:
    return rng.choices(specs, weights=[s.weight for s in specs], k=1)[0]


@dataclass
class Txn:
    dt: datetime
    category: str
    counterparty: str
    goods: str
    direction: str  # 收入 / 支出
    amount: float
    pay_method: str
    status: str
    note: str = "/"

    def to_row(self, idx: int) -> list[str]:
        stamp = self.dt.strftime("%Y%m%d%H%M%S")
        trade_no = f"42000{stamp}{idx % 100000:05d}"
        merchant_no = f"{stamp[:8]}{(idx * 7919) % 10**12:012d}"
        return [
            self.dt.strftime("%Y-%m-%d %H:%M:%S"),
            self.category,
            self.counterparty,
            self.goods,
            self.direction,
            f"¥{self.amount:.2f}",
            self.pay_method,
            self.status,
            f"\t{trade_no}",
            f"\t{merchant_no}",
            self.note,
        ]


def rand_time(d: date, rng: random.Random, *, business: bool = False) -> datetime:
    """给定日期生成一个合理的时刻。"""
    if business:
        hour = rng.randint(9, 18)
    else:
        # 消费时间分布：早餐 / 午餐 / 下午 / 晚间 高峰
        bucket = rng.choices(
            [(7, 9), (11, 13), (14, 17), (18, 22), (22, 23)],
            weights=[18, 28, 20, 30, 4],
            k=1,
        )[0]
        hour = rng.randint(bucket[0], bucket[1])
    return datetime(d.year, d.month, d.day, hour, rng.randint(0, 59), rng.randint(0, 59))


def make_expense(d: date, spec: Spec, rng: random.Random, *, business: bool = False) -> Txn:
    return Txn(
        dt=rand_time(d, rng, business=business),
        category=spec.category,
        counterparty=rng.choice(spec.counterparties),
        goods=rng.choice(spec.goods),
        direction="支出",
        amount=money(spec.low, spec.high, rng),
        pay_method=rng.choice(PAY_METHODS_EXPENSE),
        status="支付成功",
    )


def make_income(d: date, spec: Spec, rng: random.Random, *, business: bool = False) -> Txn:
    if spec.category == "微信红包":
        status = "已存入零钱"
    elif spec.category == "退款":
        status = "退款成功"
    else:
        status = "已收钱" if spec.category == "转账" else "支付成功"
    return Txn(
        dt=rand_time(d, rng, business=business),
        category=spec.category,
        counterparty=rng.choice(spec.counterparties),
        goods=rng.choice(spec.goods),
        direction="收入",
        amount=money(spec.low, spec.high, rng),
        pay_method=rng.choice(PAY_METHODS_INCOME),
        status=status,
    )


def clamp_day(year: int, month: int, day: int) -> int:
    return min(day, monthrange(year, month)[1])


def build_year(year: int, rng: random.Random) -> list[Txn]:
    txns: list[Txn] = []

    d = date(year, 1, 1)
    last = date(year, 12, 31)
    while d <= last:
        f = day_factor(d)

        # —— 每日必有的支出（保证每天都有数据）——
        n_daily = max(2, int(round(rng.uniform(2.5, 5.5) * min(f, 2.0))))
        for _ in range(n_daily):
            txns.append(make_expense(d, pick(DAILY_EXPENSE, rng), rng))

        # —— 随机中等支出 ——
        n_regular = rng.choices([0, 1, 2, 3], weights=[26, 40, 24, 10], k=1)[0]
        if f > 1.5:
            n_regular += 1
        for _ in range(n_regular):
            txns.append(make_expense(d, pick(REGULAR_EXPENSE, rng), rng))

        # —— 零散收入 ——
        n_income = rng.choices([0, 1, 2], weights=[42, 42, 16], k=1)[0]
        for _ in range(n_income):
            txns.append(make_income(d, pick(DAILY_INCOME, rng), rng))

        d += timedelta(days=1)

    # —— 月度固定支出 ——
    for m in range(1, 13):
        for spec, day in MONTHLY_EXPENSE:
            dd = date(year, m, clamp_day(year, m, day))
            txns.append(make_expense(dd, spec, rng, business=True))

    # —— 月度固定收入 ——
    for m in range(1, 13):
        for spec, day in MONTHLY_INCOME:
            dd = date(year, m, clamp_day(year, m, day))
            txns.append(make_income(dd, spec, rng, business=True))
        # 年终奖
        if m == 1:
            txns.append(
                Txn(
                    dt=rand_time(date(year, 1, 26), rng, business=True),
                    category="转账",
                    counterparty="云启科技有限公司",
                    goods="年终奖金",
                    direction="收入",
                    amount=money(120000, 240000, rng),
                    pay_method="招商银行储蓄卡(1234)",
                    status="已收钱",
                )
            )

    txns.sort(key=lambda t: t.dt)
    return txns


def rescale(txns: list[Txn], direction: str, target: float) -> None:
    """把某个方向的总额按比例缩放到目标值附近。

    只缩放"弹性"部分（非固定月度项也一起缩，但保持金额量级合理），
    缩放后重新做尾数修饰，避免出现 3721.8374 这种数值。
    """
    subset = [t for t in txns if t.direction == direction]
    total = sum(t.amount for t in subset)
    if total <= 0:
        return
    k = target / total
    for t in subset:
        v = t.amount * k
        if v < 100:
            v = round(v, 2)
        elif v < 1000:
            v = round(v, 1)
        elif v < 20000:
            v = float(round(v))
        else:
            v = float(round(v / 100) * 100)
        t.amount = max(0.01, v)


def write_csv(path: Path, year: int, txns: list[Txn]) -> None:
    income_total = sum(t.amount for t in txns if t.direction == "收入")
    expense_total = sum(t.amount for t in txns if t.direction == "支出")
    income_cnt = sum(1 for t in txns if t.direction == "收入")
    expense_cnt = len(txns) - income_cnt

    preamble = [
        ["微信支付账单明细"],
        [],
        ["微信昵称：[小猪记账测试]"],
        [f"起始时间：[{year}-01-01 00:00:00] 终止时间：[{year}-12-31 23:59:59]"],
        ["导出类型：[全部]"],
        [f"导出时间：[{year + 1}-01-05 10:30:00]"],
        [],
        ["共%d笔记录" % len(txns)],
        ["收入：%d笔 %.2f元" % (income_cnt, income_total)],
        ["支出：%d笔 %.2f元" % (expense_cnt, expense_total)],
        ["中性交易：0笔 0.00元"],
        [],
        ["备注：以下是本次账单导出的明细数据"],
        ["-" * 40 + "微信支付账单明细列表" + "-" * 40],
    ]

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        for line in preamble:
            w.writerow(line)
        w.writerow(HEADER)
        for i, t in enumerate(txns, start=1):
            w.writerow(t.to_row(i))


def main() -> None:
    rng = random.Random(RANDOM_SEED)
    print("生成微信账单 CSV ...\n")
    for year in YEARS:
        txns = build_year(year, rng)
        rescale(txns, "支出", EXPENSE_TARGET[year])
        rescale(txns, "收入", INCOME_TARGET[year])

        out = OUT_DIR / f"wechat_bill_{year}.csv"
        write_csv(out, year, txns)

        inc = sum(t.amount for t in txns if t.direction == "收入")
        exp = sum(t.amount for t in txns if t.direction == "支出")
        days = {t.dt.date() for t in txns}
        expected_days = (date(year, 12, 31) - date(year, 1, 1)).days + 1
        print(f"{out.name}")
        print(f"  记录数   : {len(txns)}")
        print(f"  覆盖天数 : {len(days)} / {expected_days}"
              f" {'[OK]' if len(days) == expected_days else '[WARN] 存在空档日'}")
        print(f"  收入合计 : {inc:,.2f} 元")
        print(f"  支出合计 : {exp:,.2f} 元")
        print(f"  结余     : {inc - exp:,.2f} 元\n")


if __name__ == "__main__":
    main()
