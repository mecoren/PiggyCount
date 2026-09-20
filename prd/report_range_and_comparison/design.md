# 报表增强（F2）— 设计文档

批次日志（file:line 证据、门禁）在 `docs/optimization-plan-2026-09-19.md` §13「F2」。
落地点：`lib/pages/report/range_report_page.dart`、`totalsByTag`
（`statistics_repository.dart:49-59` / `local_statistics_repository.dart:320-402`）、
`lib/utils/analytics_category_rollup.dart`。

## 一、两处与方案字面不同

### 1. 区间选择器用 `showDateRangePicker`，不是 `table_calendar`

方案写"复用已有 `table_calendar` 依赖与 `calendar_page.dart` 交互"。Material 自带的
`showDateRangePicker` 一次就返回**一个连续区间**（`DateTimeRange`），中文/韩文月份由已挂上的
`GlobalMaterialLocalizations.delegate`（`lib/main.dart:761`）出，**零新依赖、零新组件、零新代码**；
`table_calendar` 的 range 模式要自己管起止两个状态和"只选了一个"的中间态。
选择器语义是"含末日"，入口统一 `+1d` 转成半开区间，与全仓取数口径一致。

### 2. 报表是新页面，不是洞察页的第 5 个视角

方案措辞是在 `analytics_page` 上加列。那页的现实：1.5k 行、视角固定周/月/年/全部、
数据靠 `List<dynamic>` **位次**传递、摘要卡只有**一个** `prevTotal` 槽、左右滑手势=切周期、
还挂着分享海报分支。在它上面同时挂环比+同比两列再叠标签维度，改动面会铺满 4 个视角的取数
与手势语义 —— 回归面远大于新页。

代价是"两页"这个既成事实。为把它压到最小，两页**共享同一批 repo 方法与同一个分类聚合函数**。

## 二、口径同源怎么保证（而不是"看着一样"）

- 分类排行榜：把原来长在洞察页里的层级聚合原样抽到 `lib/utils/analytics_category_rollup.dart`
  （`aggregateTopLevelCategories`），两页调用同一个函数 → 同一份实现，不可能算出两个数。
- 标签维度：新 `totalsByTag` 与单标签详情页的 `getTagStats` 用测试**逐值对账**
  （两条不同查询、必须相等）。
- 顺手收的旧账（方案 §四点名）：`_calculateBalanceSeries` 原在 **build 期**调用，
  挪到加载侧。它是纯函数、两份序列各最长 6 桶×31 天，放 build 里等于每次 setState 重排一遍。

## 三、标签维度的两个非显然决定

1. **两条 SQL 在 Dart 侧按 tag id 合并**：一笔交易的标签可能来自主表（`transaction_tags → tags`，
   本机拥有的标签），也可能来自共享账本 Editor 路（`transaction_tag_overrides →
   shared_ledger_tags`，标签行不在主表）。后者按 `syncId` 转 synthetic **负 id**
   （与 `LocalTagRepository` 同源），于是同一张报表里两类标签各占一行、不会互相覆盖。
2. **占比按"标签行之和"算**：一笔可挂多个标签，各行之和通常**大于**区间总额。
   这是标签不互斥的口径，与标签详情页一致；若按区间总额算占比，多标签交易的百分比会超过 100%。

## 四、长区间与查询次数

- 一次 `Future.wait` 八条 SQL（三窗 `totalsInRange` + 日序列 + 分类 + 共享合成分类 + 标签 + 笔数），
  全部聚合，**零整行拉取**。
- 日粒度上限 `dayChartLimit = 31`：超出就在 Dart 侧对**已聚合的日序列**并桶到自然月，
  不多查一次库、不拉整行。三年区间会画 36 根柱而不是 1000+ 根。
- 单槽记忆化 `_futureFor(ledgerId, refreshTick)`，key = `ledgerId|start|end|dim|tick`
  （与洞察页 `_rememberAnalyticsFuture` 同口径）：切维度只重发查询，其他 `setState` 复用已发 Future。
- 窗口算术（`momWindow` / `yoyWindow` / `changeRate` / `rollToMonths`）做成 `static`，
  为的是纯函数可测 —— 不必 pump 页面就能钉住最容易写错的那部分（闰日、等长紧邻窗、基数 0）。
  `yoyWindow` 对 2/29 的处理是**进位到 3/1**（`DateTime` 的默认行为）：宁可多算一天也不抛异常。

## 五、内存门禁状态

F2 新增常驻只有一个 `Future.wait` 的 8 个结果对象（最坏 6 桶×31 天的日序列）。
本轮无真机 RSS 基线可前后对比（B6 的 `profile_memory.py` 至今无设备数据），
所以**不声称任何内存收益数字** —— 这是算式不是实测，设备到位后按 §七.2 回填。
