# 洞察页自定义时间档位（季度 / 任意起止区间）— 设计文档

> **状态：已落地**（2026-10-13，Q1–Q6 按推荐方案实现完成，门禁结果见文末「落地回填」）
> 配套需求：`requirements.md`（同目录）。评审确认（含 §六拍板项）后按 §五 TDD 步骤实现。

落地点：`lib/utils/analytics_scope.dart`（扩）、`lib/pages/main/analytics_page.dart`、
`lib/widgets/analytics/analytics_summary.dart`、`lib/widgets/analytics/category_rank_row.dart`、
`lib/pages/report/range_report_page.dart`（1 处权宜值归位）、
`test/utils/analytics_scope_test.dart`（扩）。**数据层零改动**（复用
`totalsByDay` / `totalsByMonth` / `totalsByYearSeries` 既有聚合）。

## 一、关键技术决策与理由

### D1 枚举直接加 `quarter` / `custom`，穷尽 switch 编译器强制补全

```dart
enum AnalyticsScope { week, month, quarter, year, custom, all }
```

上一批枚举化的全部收益在本批兑现：加两个成员后，`analytics_page.dart` 的 8 处分支簇、
`analytics_summary.dart` 3 处、`category_rank_row.dart` 1 处、纯函数层 4 处
**全部编译报错**，逐处补 `quarter`/`custom` 分支即可，不存在静默落错分支。

### D2 锚点形状：record 参数扩展，不引入 sealed class

`resolveAnalyticsPeriod` 签名扩为：

```dart
AnalyticsPeriodRange resolveAnalyticsPeriod(
  AnalyticsScope scope, {
  required DateTime anchor,      // quarter=季度首月标签月 DateTime(y, 3k+1, 1)
  DateRange? range,              // custom 专用：显式 [start, end)
  required int startDay,
  required DateTime now,
})
```

- `quarter` 锚点编码为「季度首月的标签月」，**完全复用 `DateTime` 锚点形状**
  （`selectedMonthProvider` 可继续持有，切档时吸附到季度首月），`nextAnchor/prevAnchor`
  签名不变，仅补分支。
- `custom` 用可选 `DateRange? range`（`month_range.dart` 既有 record，已 re-export），
  对应旧设计 §三「record 形状扩展」的预留路线；不引入 sealed class `AnalyticsAnchor`
  ——只有一个档位需要携带区间，sealed 继承体系是过度设计（同上一批 §三的判断哲学）。
  `custom` 分支对 `anchor` 视而不见；断言 `scope==custom ⇒ range != null`。
- `custom` 的平移另立纯函数 `shiftCustomRange(DateRange range, int dirDays)`（等长平移），
  **不塞进** `nextAnchor/prevAnchor`（那两个返回 `DateTime?`，塞区间会破坏签名语义）。

### D3 季度周期 = 账期口径，与「年」同哲学

```dart
/// 季度标签 (year, q1..q4) → [起始月-startDay, 起始月+3-startDay)
({int year, int quarter}) quarterLabelFor(DateTime date, int startDay);
DateRange quarterRangeFor(int year, int quarter, int startDay);
```

「年」档位现状就是账期口径（`yearRangeFor = [1-d, 次年1-d)`），季度若用自然季度会出现
「年切 4 份 ≠ 4 个季」的口径裂缝。startDay=1 时自然退化为自然季度（单代码路径，
同 `month_range.dart` 头注释哲学）。纯函数放 `lib/utils/analytics_scope.dart`
（或 `month_range.dart` 同层），`now`/`startDay` 注入、可单测。

### D4 季度取数走日序列 + 内存按季滚桶，不加 repo 方法

- seriesKind：`quarter` → `day`（`totalsByDay(start, end)` 覆盖一个季度约 90 行）、
  `custom` → `day`（`totalsByDay(start, end)`，超长区间行数可接受，见风险 §七）。
- 图表 6 桶：`chartSeriesWindow(quarter)` = `[quarterRangeFor(Q-5).start, quarterRangeFor(Q).end)`，
  一条 `totalsByDay` 查 6 个季度（约 540 行），新纯函数 `_aggregateToQuarters`
  （按 D3 边界分桶）聚合。`custom` 图表窗口 = 区间本身，≤60 天直接按天、
  超过复用既有 `rollToMonths` 按月滚桶（RangeReportPage 同款先例，
  `dayChartLimit` 口径对齐）。
- 理由：`totalsByMonth` 只支持单年查询，6 季度跨 2 年要发 2 条查询再拼接；
  日序列单查询 + 内存分桶与月档位的 `_aggregateToMonths` 是同一模式，零数据层改动。
  （落地修正：D4 上文「≤60 天」实际按 `RangeReportPage.dayChartLimit = 31` 执行。）

### D5 状态归属延续现状拆分

- quarter：锚点（季度首月标签月）进 `selectedMonthProvider`（与月/年共享），
  切到季档时把 `selMonth` 吸附到所在季度首月；选期器选定后写回。
- custom：区间存页面本地 `_customRange`（默认近 30 天含今天），与 `_selWeek` 同定位
  ——自定义区间不是「共享选中月」语义，不进全局 Provider。
- 状态写回仍全部留在页面（沿用上一批决策，纯函数层只算不写）。

### D6 新旧档位口径对照（新档位不复制旧档位的口径不一致）

| 口径 | 既有冻结（不改） | quarter | custom |
|------|------------------|---------|--------|
| 当前周期判定 | 月=标签相等；周/年=区间包含 | 区间包含 | 无此概念（不截断，Q6） |
| end 截断 | 含今天截到 today+1d | 同（延续口径 6） | 不截断 |
| 上期 | 周=环比；月/年=同比；all=无 | 同比去年同季度（Q2） | 等长环比 momWindow（Q4） |
| 前进钳制 | 三口径不一 | 不进未来季度（同年档） | 无钳制（等长平移，同 RangeReport） |
| 平均值标签 | 周/月=日均；年=月均；all=平均 | 日均 | 日均（除数=区间天数） |
| 图表 | 6 桶；all 不高亮 | 6 季度桶、高亮末桶 | 自适应桶、不高亮 |
| 海报 | 周→月报回退 | 年报回退（Q5） | 隐藏分享（Q5） |

## 二、改动面盘点

纯函数层 `analytics_scope.dart`（穷尽 switch 全部补分支）：
`seriesKind`（quarter/custom→day）、`resolveAnalyticsPeriod`、`nextAnchor`/`prevAnchor`
（quarter 平移一季、钳制不进未来；custom 返回 null）、`chartSeriesWindow`（quarter=6 季窗、
custom=区间本身）；新增 `quarterLabelFor` / `quarterRangeFor` / `shiftCustomRange` /
`aggregateToQuarters` 纯函数。

`analytics_page.dart`：
1. 选期器 `_showPeriodPicker` +2 分支（quarter=吸附式季度选择、custom=`showPiggyRangePickerSheet`）；
2. 导航行文案 `_navPeriodLabel` +2 分支（`2026Q3`、`yyyy-MM-dd ~ yyyy-MM-dd`）；
3. 左右滑/箭头 +2 分支（quarter→next/prevAnchor；custom→shiftCustomRange）；
4. 取数路由（seriesKind→day，锚点换 range 传参）；
5. 图表分桶 switch +2 分支（`_aggregateToQuarters`、自适应天/月）；
6. x 轴标签（quarter=`26Q3` 式）、高亮（quarter=末桶、custom=不高亮）；
7. 海报 switch +2 分支（Q5 结论）；
8. 分段控件加 2 段（label：`analyticsQuarter`「季度」、`analyticsCustom`「自定义」）。

共享 widget + 调用点：
- `analytics_summary.dart`：`_avgLabel`、对比文案（新增 `_compareLabel` 穷尽 switch）各 +2 分支
  （custom 新增 l10n `analyticsComparedToPrevRange`「比上一区间」）。
- `category_rank_row.dart`：`_currentPeriodLabel` +2 分支（quarter=`2026Q3`、
  custom 由页面传 `periodLabel` 覆盖，分支可回落 range 文案）。
- `range_report_page.dart:574`：`scope: AnalyticsScope.month` → `AnalyticsScope.custom`
  （保留原注释并更新为「归位」说明）。

l10n（zh / zh-Hant / en / ko 四份 arb 同步）：`analyticsQuarter`、`analyticsCustom`、
`analyticsThisQuarter`、`analyticsSelectedRange`、`analyticsComparedToPrevRange`。

## 三、为什么不做成「时间档位插件注册表」

与上一批 §三同结论：档位差异是**计算参数**（窗口、粒度、钳制、对比），不是行为族。
两个新档位只是枚举 + record 参数形状的扩展；穷尽 switch 已保证「新增档位编译期强制
补全」。注册表/Strategy 在只有 6 个封闭成员时是纯负担。

## 四、与 RangeReportPage 的边界（Q1 内嵌方案下的定位互补）

- 洞察页 custom 档位 = **概览三件套**（摘要卡 + 趋势图 + 分类排行）+ 单一对比格，
  面向「切个区间快速看」；
- RangeReportPage = **明细报表**（分类层级 + 标签维度 + 环比/同比双对比 + 自定义字段），
  面向「出报表」；
- 两者共用 `showPiggyRangePickerSheet` / `momWindow` 语义 / `rollToMonths`，口径同源；
- 洞察页右上角 RangeReportPage 入口（date_range 图标）保留不动。

## 五、实现步骤（≤5 步，TDD 顺序）

1. **RED**：扩展 `test/utils/analytics_scope_test.dart`——quarter/custom 的
   `quarterRangeFor`（含 startDay=1/10/28 借位）、`resolveAnalyticsPeriod`
   （当前季截断、同比上期、custom 不截断 + 环比上期）、`nextAnchor/prevAnchor`
   （钳制）、`chartSeriesWindow`、`shiftCustomRange`、`aggregateToQuarters`
   逐条先写断言看红。
2. **GREEN**：`analytics_scope.dart` 扩枚举 + 纯函数，让新测试全绿；既有 22 个
   特征测试保持原样通过（既有档位行为零变化）。
3. `analytics_page.dart` 按 §二盘点逐簇补分支（编译器驱动），custom 接
   `showPiggyRangePickerSheet` + `_customRange` 本地状态，quarter 锚点吸附进
   `selectedMonthProvider`；widget 测试补选期/平移用例（注意「A Timer is still
   pending」坑：settle 末尾 `tester.pump(const Duration(seconds: 3))`）。
4. 共享 widget +2 分支、l10n 四份 arb、`range_report_page.dart:574` 权宜值归位。
5. 门禁：`flutter analyze` 0 issue、全量 `flutter test` 绿、grep 验证新档位分支无
   `default` 兜底残留、`git diff --stat` 核对波及面（**不得跑 `dart format .`**，
   新代码手工对齐仓库旧式换行风格）、真机 UI 回归、回填本文件页眉落地状态与门禁结果。

## 六、待用户拍板项

见 `requirements.md` §三 Q1–Q6（含推荐方案）。**全部确认后**才进入 §五实现；
任何一条改选会改本文件的 D6 对照表与 §二 l10n 清单。

## 七、边界条件与风险

- **分段控件 6 段窄屏挤压**：周/月/季/年/自定义/全部 6 段在小屏上单段宽度紧张。
  对策：字号沿用 fs14、实测 1200x2608（MuMu）与窄屏；若挤压，「自定义」段短标签
  （如「区间」）兜底。
- **custom 档位与 `selMonth` 解耦后的 memoKey**：memoKey 已含 start/end，天然隔离；
  但 `_navPeriodLabel`/传参处 `selMonth` 对 custom 无意义，需统一传 `_customRange.start`
  作展示锚，防 null 断裂。
- **quarter × startDay=28 借位**：Q4=10/28~次年1/28、2 月周期边界全靠 DateTime 进位，
  测试必须钉住 2/28、12/28 附近用例。
- **custom 超长区间性能**：`totalsByDay` 数年区间数千行在内存滚桶，实测可接受即不优化；
  若真机掉帧，再考虑按月预聚合（新 repo 方法，另立批次）。
- **对比文案 l10n 四语种**：新增 key 必须四份 arb 同步，否则 analyze 的
  untranslated-messages 门禁会红。
- **既有 22 个特征测试是回归底线**：任何一条变红 = 既有档位口径被顺手改了，必须回退。

## 八、落地回填（2026-10-13）

- 实现按 §五 TDD 步骤完成：RED（21 个新断言编译失败）→ GREEN（纯函数层 43 测试全绿）
  → 页面/共享 widget 编译器驱动补分支 → 门禁。
- 门禁结果：`flutter analyze` **0 issue**；全量 `flutter test` **2359 个全部通过**
  （基线 2338 + 新增 21，含既有 22 个特征测试原样通过）；grep 确认新档位分支无
  `default`/`_ =>` 兜底；`git diff --stat` 波及面仅限 §二盘点文件 + l10n 生成物；
  未跑 `dart format .`（新代码手工对齐仓库旧式换行风格）。
- 与初稿的偏差（均已在 `requirements.md` §六同步）：
  1. custom 图表阈值按 `RangeReportPage.dayChartLimit = 31`（非 60）；
  2. 对比文案落为「比上一区间」（非「较上一区间」），与「比上周/比上年」措辞体系一致；
  3. l10n 实际新增 5 key（初稿列 3）：另含 `analyticsThisQuarter`/`analyticsSelectedRange`
     （折线卡标题 switch 需要）。
