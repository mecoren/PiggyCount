# 洞察时间维度枚举化重构 — 需求文档

## 〇、需求理解（1-2 句）

对洞察页（`lib/pages/main/analytics_page.dart`）的时间维度做**纯重构**：把裸字符串
`_scope`（`'week' | 'month' | 'year' | 'all'`）与散落全页的 8 处 if-else 分支簇收拢为
**枚举 + 穷尽 switch + 纯函数周期计算层**。本轮**不新增任何功能、行为零变化**，目的只是
为后续扩展（自定义时间档位 / 自定义字段进洞察 / 卡片注册表）打底。

## 一、背景

现状（已核实，file:line 证据见 design.md §二）：

- `_scope` 是裸字符串（`analytics_page.dart:37`），全文件 `_scope ==` 命中 32 处，
  分布在 8 个互不相连的分支簇里（选期器、左右滑切周期、导航文案、时间范围、上期范围、
  取数路由、图表 6 桶窗口、海报分支）。
- 每个分支簇都各自实现一遍「week/month/year/all 四路」，新增一个时间档位要同步改
  8 处以上，且漏改任一处都**没有编译期报错**——switch 里普遍带 `default` 兜底
  （如 `_navPeriodLabel` 的 `case 'month': default:`），漏改会静默落进错误分支。
- 时间计算（含「当前周期只到今天」截断、上期窗口）与 UI 状态耦合在 `build` 里
  （`:403-451`），无法脱离页面单测。
- scope 字符串还泄漏进两个共享 widget：`AnalyticsSummary.scope`
  （`analytics_summary.dart:61`）、`CategoryRankRow.scope`（`category_rank_row.dart:20`），
  后者的 `scope != 'all'` 语义被 range_report 页用硬编码 `scope: 'month'` 权宜绕过
  （`range_report_page.dart:571-573` 注释自认）。

这是先前「洞察可扩展性评估」结论的三缺口之一（时间维度枚举化），本轮只做这一件。

## 二、需求范围

### R1 时间维度枚举化

- 引入 `AnalyticsScope` 枚举（`week | month | year | all`），洞察页内部状态、两个共享
  widget 的 `scope` 参数、分段控件值全部改为该枚举类型，代码中不再出现 `'week'` 等
  裸字符串比较。
- 所有按 scope 分支的代码改为**穷尽 switch**，删除 `default` 兜底分支：未来新增档位时
  编译器强制指出每一处需要补的分支。

### R2 周期计算收拢为纯函数层

- 「选中锚点 → `(start, end, prevStart, prevEnd)`」的计算（含「当前周期只到今天、历史
  周期到周期末」截断、上期窗口）收拢为**纯函数**，`now` 与账本 `monthStartDay` 由调用方
  注入，不依赖 `BuildContext` / Provider。
- 导航步进（‹ › 与图表左右滑的下一周期/上一周期，含「不能超过当前周期」钳制）同样收拢
  为纯函数：输入锚点输出新锚点，**状态存储在哪（`_selWeek` 本地 / `selectedMonthProvider`
  共享）仍由页面决定**。
- 图表 6 桶窗口（周=本周+前 5 周、月=本月+前 5 周期月、年/全部=年序列）的窗口起点计算
  收拢进同一层。

### R3 行为冻结（硬要求）

- 本轮**零行为变化**：任一视角下同一笔数据算出的区间、上期区间、图表桶、导航钳制、
  海报分支、文案与重构前逐值一致。
- 现状中已存在的**口径不一致原样保留**，不顺手统一（详见 design.md §四行为冻结清单），
  例如「当前周期」判定：月视角用周期标签相等、周/年视角用区间包含判定。

### R4 门禁

- `flutter analyze` 0 issue；全量 `flutter test` 绿（含既有
  `test/pages/main/analytics_page_test.dart` 回归）。

## 三、验收标准

1. 周期纯函数有特征测试钉住现状口径：四档位各自的 `(start, end)` 与上期窗口；当前周期
   截断到「今天+1 天」而历史周期到周期末；月视角 `startDay` 跨月周期（如起始日 10：
   2026-12 周期 = [2026-12-10, 2027-01-10)）；同比 2/29 进位；全部视角上期为 null。
2. 导航步进纯函数有测试：周/月/年各自的前进钳制**按现状口径**（周=周标签比较、月=自然
   年月比较、年=自然年比较）逐值钉住；全部视角步进为 no-op。
3. `analytics_page.dart` 及两个共享 widget 中 `String scope` 与 `'week'` 等字面量比较
   **零残留**（grep 可证）；所有按 scope 的 switch 无 `default` 分支。
4. 既有 `analytics_page_test.dart` 不改断言全绿（行为冻结的回归证据）。
   - 落地偏差说明：唯一改动是 1 处 finder 从 `find.byType(WaitSlidingSegmentedControl<String>)`
     改为无泛型 `is` 谓词（scope 分段控件枚举化后泛型参数变 `AnalyticsScope`，精确
     runtimeType 匹配兜不住两种实例化），属类型变更的机械适配、断言语义不变，其余断言逐字未动。
5. `flutter analyze` 0 issue + 全量 `flutter test` 绿；`git diff --stat` 波及文件仅限
   本批点名文件（防 `dart format` 噪音，见项目记忆踩坑记录）。

## 四、未纳入本轮

- **自定义时间档位**（季度 / 任意起止日期）：枚举化只是它的前置，本轮不加档位、不加
  日期范围选择器。
- **自定义字段进洞察 / 卡片注册表 / 命名数据包**：可扩展性评估的另两个缺口，另批处理；
  `List<dynamic>` 位次传递（`analytics_page.dart:52-55`）本轮原样保留。
- **`tag_detail_page.dart` 的自有 `_scope` 字符串**（`month | year | all`，无 week 档）：
  语义与洞察页不同源，共享枚举属后续「统一周期语义」批次，本轮不动。
- **`CategoryRankRow` 的 `scope: 'month'` 权宜值清理**（range_report 传假档位）：根治需要
  改该 widget 的参数语义（`includeRange` + 显式标签），超出「纯类型收拢」边界，本轮仅
  把它换成 `AnalyticsScope.month` 并保留原注释。
- 统一口径顺手修（如导航钳制三口径不一）：行为冻结红线，明确拒绝混入。
