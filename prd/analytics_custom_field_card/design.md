# 自定义字段卡片进洞察 — 设计文档

> **状态：待评审**（2026-10-13 拟稿）。对应 `requirements.md`（缺口③，先③后②之③）。

落地点（拟）：`lib/providers/custom_field_providers.dart`（新增区间聚合 provider）、
`lib/widgets/analytics/custom_field_stats_view.dart`（新建，共享内容 widget）、
`lib/widgets/analytics/custom_field_stats_card.dart`（新建，洞察卡片自取数据 + 自隐藏）、
`lib/pages/main/analytics_page.dart`（接入卡片）、`lib/pages/report/range_report_page.dart`
（改调共享 widget，一处调用点）、`test/widgets/custom_field_stats_view_test.dart`（新建）、
`test/widgets/custom_field_stats_card_test.dart`（新建）。
**不动数据层**：`StatisticsRepository.customFieldStatsRows`（`statistics_repository.dart:175-179`）
与 `CustomFieldStatsService`（`custom_field_stats_service.dart:51+`）零改动。

## 一、关键技术决策与理由

### 1. 卡片数据自取（family provider），不并入 `_loadCategoryData/_loadBalanceData`

- 现状：主数据是 `(String, List<dynamic>)` 位次表（`analytics_page.dart:1531, 1581`
  位次注释；`:68`「跨口径复用会读到 list[7] 越界」；`:1038` 用
  `list[list.length - 1]` 隐式读图表序列）。往里插新位次会：①破坏「最后一位=图表序列」
  隐式约定；②在批次②（命名数据包）里还要再动一次——先恶化再重构，禁止。
- 方案：新增 `customFieldStatsForRangeProvider`——`FutureProvider.autoDispose.family<
  List<CustomFieldFieldStats>, ({int ledgerId, DateTime start, DateTime end, int refreshTick})>`
  （record 键自带 `==`，family 天然去重），放在
  `lib/providers/custom_field_providers.dart`（既有归属：`:18/:31/:42` 已有 defs 查询
  provider）。内部逻辑照抄 range_report：`getDefinitionsForLedger` → 空则返回 `[]`
  **不发值行查询**（F5）→ `customFieldStatsRows` → `CustomFieldStatsService.aggregate`。
- `autoDispose` 对应 U8「旧键的 future 无人再读直接丢弃」语义（`analytics_page.dart:77-80`
  字段注释）：切档位/切周期后旧键无人 watch 即释放，不随交互累积。
- 键含 `refreshTick`（`statsRefreshProvider`）：新增/编辑交易后卡片数字才刷新，
  与主链路 memoKey（`:477-479`）同源同语义。

### 2. 共享 widget 只抽「内容区」，卡片铬留在各页

- 新建 `lib/widgets/analytics/custom_field_stats_view.dart`：
  `CustomFieldStatsView({required List<CustomFieldFieldStats> fields, required String dim})`，
  移植 `range_report_page.dart:686-761` 的字段名 + 值桶行渲染（topN=8、「其他」合并、
  `analyticsTxCountShort` 笔数、`AmountText` 金额，全走 `PiggyTextTokens`——该文件
  `:687-688` 注释的 U1 约束随代码一起搬）。
- 不抽卡片铬：洞察页卡片铬是「surface + 主色描边 + accent 竖条标题」
  （`analytics_page.dart:1257-1283`），区间报表是 `_SectionCard(title:…)`
  （`range_report_page.dart:327-332`），两种铬差异大、各页自持更简单。
- 标题文案两处**复用** `rangeReportCustomFieldTitle`（「自定义字段汇总」）：语义通用，
  零新增 l10n 键、零 arb 改动面。
- `dim` 参数沿用 `CustomFieldFieldStats.sorted(dim)` 的 `'income'|'expense'` 约定
  （`custom_field_stats_service.dart:37`），不新造类型（渲染层 2 值分派不值得上枚举）。

### 3. 洞察页接入点：排行榜卡之后（实现细化：卡片自隐藏，独立文件）

- 位置：`analytics_page.dart` 卡片序列末位（`if (_type != 'balance')` 块之后、
  底部留白之前），卡片**自隐藏**：`type == 'balance'` 时返回 `SizedBox.shrink()`
  （结余口径与分类构成/排行榜一致，记为行为冻结项 requirements.md R5）。
  *（实现细化：初稿计划放进 `:1374` 的块内并由页面条件隐藏；改为卡片收
  `type` 自隐藏后，「结余隐藏」契约可以在卡片层直接测试钉住（R5），页面 diff
  也更小，批次②注册表收编时 visible 谓词可直接 `() => true`。）*
- 维度映射：`type`（'expense'|'income'|'balance'）即值桶排序/金额展示维度
  （balance 不渲染，无需映射）。
- 卡片内部用 `ref.watch(customFieldStatsForRangeProvider((ledgerId:…, start:…, end:…,
  refreshTick:…)))`：`waiting → SizedBox.shrink()`（不渲染）；`hasError → logger.warning`
  后不渲染（附属卡失败不拖垮主链路，且不吞错——满足「关键路径禁空 catch」约束）；
  `data.isEmpty → SizedBox.shrink()`。空态/错误态都不占位，与「非空才出现」的
  F1 显示条件天然一致。

### 4. 行为冻结红线

- range_report 侧只做「搬渲染逻辑 + 改调共享 widget」，`_ReportData.customFields`
  字段、查询时序（`:119-130`）、`if (data.customFields.isNotEmpty)` 显示条件
  （`:327`）全部原样；`range_report_page_test.dart` 不改断言全绿是回归底线。
- 主链路（`_rememberAnalyticsFuture`、位次表、shape 标签、空态、横滑）一行不动。

## 二、实现步骤（≤5 步，TDD 顺序）

1. **RED**：新建 `test/widgets/custom_field_stats_view_test.dart`——共享 widget 的
   值桶渲染断言（topN=8 后合并「其他」、笔数文案、金额维度取 `dim`、空字段列表），
   对尚未存在的 `CustomFieldStatsView` 先编译失败（红）。
2. **GREEN（共享层）**：新建 `CustomFieldStatsView`，移植
   `range_report_page.dart:686-761`；range_report 改调共享 widget；
   `range_report_page_test.dart` 原样绿（不改断言）。
3. **接入洞察**：provider + 卡片（F1/F2/F3/F5 条件全落），补 widget 测试钉住：
   结余视角隐藏、空数据不渲染、六档位中至少「月/自定义/全部」三档出卡、
   refreshTick 变化后数字刷新（注意「A Timer is still pending」坑：settle 末尾
   `tester.pump(const Duration(seconds: 3))`，项目记忆先例）。
4. 门禁：`flutter analyze` 0 issue、全量 `flutter test` 绿、
   `git diff --stat` 波及面仅限落地点清单（**不得跑 `dart format .`**）。
5. 真机（MuMu `127.0.0.1:16384`，dev flavor）回归 + 回填本文件页眉落地状态。

## 三、边界条件与风险（对应 requirements.md §六）

- R1 的插位次风险由决策 1 规避；批次②再把本卡收编进注册表（届时卡片自取数据模式
  不变，只换清单入口）。
- R2 在途时间差：接受（附属卡）；不为主链路一致性引入联动刷新复杂度。
- R3/R4：沿用 range_report 口径不优化；真机实测为准。
- 测试注意：provider 内是异步查询，widget 测试用 `ProviderScope(overrides:…)` 注入
  假 repo 结果或 Future.value 数据，避免真实 DB。
