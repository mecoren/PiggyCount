# 洞察卡片注册表 + 命名数据包 — 设计文档

> **状态：已落地**（2026-10-13 拟稿，2026-10-13 落地并真机回归通过）。对应
> `requirements.md`（缺口②，先③后②之②）。
>
> **落地偏差说明**（均为实现细化，不违背设计决策）：
> - `sumOfSeries` 测试落为独立文件 `test/pages/main/analytics_sum_of_series_test.dart`
>   （5 例：day/month/year 形状 + 空/未知形状返回 0），而非塞进
>   `analytics_page_test.dart`。
> - `InsightCardDef.build` 返回**「卡片 + 后置间距」widget 片段列表**而非单卡
>   Widget：卡片间距不均匀（排行榜卡与自定义字段卡之间现状无间距），片段化才能
>   让 ListView children 序列与收编前逐节点一致（§二.4 树形红线）。
> - 分类构成卡的 `pieData` record 映射从内层 `Builder` 提升到注册表组装处，
>   `Builder` 只保树形不再藏取数逻辑。
> - 门禁全绿：`flutter analyze` 0 issue、全量 `flutter test` 2393 通过 +1 skip
>   （既有断言零改动）、`List<dynamic>`/`list[` 位次读取 grep 零残留、真机目检
>   （MuMu 127.0.0.1:16384）卡片顺序/树形/结余隐藏口径逐像素一致。

落地点（拟）：`lib/pages/main/analytics_page.dart`（数据包、load 函数、注册表、build
取数，主体都在本文件）、`lib/widgets/analytics/insight_card.dart`（新建，仅
`InsightCardDef` 类型定义）、`test/pages/main/analytics_page_test.dart`（不改断言）。
**不动**：数据层 / `analytics_scope.dart` 纯函数层 / 共享 widget 参数 / U8 缓存语义。

## 一、关键技术决策与理由

### 1. sealed 数据包，而不是「单类 + 可空字段」

- 两形状同名字段语义不同：`series` 在收支口径是分类主序列、结余口径是结余序列；
  `txCount` 一个是单维笔数、一个是收支合计（`analytics_page.dart:886-924` vs `:925-950`）。
  单类可空字段会把「跨形状误读」从运行时静默错值降级成 null 检查——没有根治。
- `sealed class InsightsData` → `InOutInsightsData` / `BalanceInsightsData`：
  形状即类型，`switch (data)` 穷尽匹配**编译期强制**补全两臂——与 `AnalyticsScope`
  枚举化同一哲学（`analytics_scope_enum_refactor/design.md` §一.1：把静默错分支
  变成编译错误）。
- shape 标签（`_shapeOf`）**保留原样**：它服务「在途查询继续渲染上一份同口径结果」
  的闸门（`:851-853`，注释 `:846-850` 解释了为何不能串口径），换成 `data is InOut`
  判定行为等价但会动性能修复沉淀区——纯重构不动（F4 冻结）。类型收拢后，标签未来
  可以再简化，属后续清理。

### 2. 数据包命名化的形状（一次到位）

```dart
sealed class InsightsData {
  final String shape;                    // 'inOut' | 'balance'，在途闸门用（现状语义）
  final dynamic series;                  // day/month/year 三形状 record 列表（不强类型化）
  final dynamic chartSeries;             // 同上
  final List<CatAgg> cats;               // 现 aggregateTopLevelCategories 返回的 record 列表
  final (double, double) curTotals;      // (本期收入, 本期支出)；结余口径同构
  final (double, double) prevTotals;     // (上期收入, 上期支出)
}
// InOut: + txCount
// Balance: + expenseCount, incomeCount, incomeSeries, expenseSeries
```

- `chartSeries` 成命名字段后，`:1038` 的 `list[list.length - 1]` 隐式约定删除——
  这是本批要杀掉的最脆一处（插任何位次都会静默读错）。
- `series` / `chartSeries` 保持 `dynamic`（day/month/year 三种 record 形状）：
  强类型化要 sealed 三种序列并波及图表全家桶的 `is` 分派，超出「收编位次」边界
  （requirements.md §五）。`_getSumFromSeries` 收编为同文件顶层纯函数
  `double sumOfSeries(dynamic seriesData)`（逻辑逐字搬迁，`:435-446`）。
- load 函数返回类型改 `Future<InOutInsightsData>` / `Future<BalanceInsightsData>`，
  `(String, List<dynamic>)` 元组随之消失（`_rememberAnalyticsFuture` 泛型同步改）。

### 3. 注册表是页内静态清单，不是跨文件组件化

- `InsightCardDef({required String id, required bool visible, required Widget Function() build})`
  ——类型定义可放 `lib/widgets/analytics/insight_card.dart`，但**清单在
  `analytics_page.dart` 的 build 作用域内组装**（`:1237` 附近）：卡片构建闭包依赖
  大量页面局部（`_chartSwiped`、横滑回调、`ref`、配色、`filteredSeriesRaw`…），
  抽成跨文件 builder 需要一个巨型 context 对象——是过度设计。
- 注册表收益边界：**清单数据驱动**（新增/隐藏卡片 = 清单一项 + 谓词一处），
  不是行为族抽象。这与「时间档位不做插件」的分寸一致
  （`custom_time_scope_extension/design.md` §三），但卡片清单本来就是列表，
  收编成列表没有抽象成本。
- `visible` 谓词固化现状条件：分类构成/排行榜/自定义字段 = `_type != 'balance'`
  （`:1374` 现状）；摘要/趋势 = 恒真。空态整页分支（`:968-1006`）**不属于卡片**，
  保留为 FutureBuilder 内的前置分支。
- ③批的自定义字段卡收编为一员（R4）：`build` 返回其自取数据的 widget，谓词同上。

### 4. 行为冻结的实现纪律

- 只动「数据怎么装」与「清单怎么列」，不动「数据怎么算、怎么显、怎么缓存」。
- widget 测试红线（R2）：任何 finder 变红先怀疑树形变了；仅允许因类型变更导致的
  finder 机械适配（先例：`analytics_scope_enum_refactor/design.md` 页眉偏差说明），
  断言语义零变化。

## 二、实现步骤（≤5 步，TDD 顺序）

1. **先确认基线**：全量 `flutter test` 绿（含 `analytics_page_test.dart`、
   `analytics_scope_test.dart` 43 例、③批测试）作为重构底线；为
   `sumOfSeries` 搬迁落特征测试（三种 record 形状 + 空/未知形状返回 0）。
2. **命名数据包**：定义 sealed 数据包 + 两个 load 函数改返回类型 + build 内位次读取
   改命名字段（`:886-950, :1038` 一带），`_rememberAnalyticsFuture` 泛型同步改；
   编译器驱动逐处清零 `list[n]`。
3. **`_getSumFromSeries` 收编**为 `sumOfSeries` 纯函数（含步骤 1 测试）。
4. **卡片注册表**：`InsightCardDef` + 清单组装 + `ListView` 改按清单渲染；
   五卡顺序/树形逐像素保持；③批卡片收编（R4）。
5. 门禁：`flutter analyze` 0 issue、全量 `flutter test` 绿（既有断言不改）、
   grep 证 `List<dynamic>` / `list[` 在 `analytics_page.dart` 零残留、
   `git diff --stat` 核对波及面（**不得跑 `dart format .`**）；真机目检 + 回填页眉。

## 三、边界条件与风险（对应 requirements.md §六）

- R1：空态判定 `:968`、在途复用 `:851-853`、U8 memoHit `:481-482` 三处是注释密集的
  修复沉淀区，重构 diff 里出现这些行 = 亮红灯自查。
- R2：注册表渲染前后各卡 widget 树逐节点对照（key 用现状的 `RepaintBoundary` 等
  包装原样保留）。
- R3：sealed switch 不加 `default`（穷尽性是本批收益落点）。
- 测试环境注意「A Timer is still pending」坑（项目记忆）：settle 末尾
  `tester.pump(const Duration(seconds: 3))` 推完 Logger 节流定时器。
- 性能预期：数据包命名化零运行时开销（record→class 一次性对象，同一取数频率）；
  注册表清单在 build 内组装是 O(卡数) 小列表，无感知。
