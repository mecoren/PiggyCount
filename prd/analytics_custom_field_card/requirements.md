# 需求文档：自定义字段卡片进洞察（缺口③）

> **状态：待评审**（2026-10-13 拟稿）
> 批次序列：可扩展性路线图「先③后②」——本批为③（最小闭环），后续批
> `prd/analytics_card_registry/`（②卡片注册表 + 命名数据包）会把本批卡片收编进注册表。
> 前置已落地：`prd/analytics_scope_enum_refactor/`（枚举 + 纯函数层）、
> `prd/custom_time_scope_extension/`（季度/自定义档位，六档位均有 `start/end`）。

## 一、需求理解

把区间报表已有的「自定义字段汇总」能力复用进洞察页：六个时间档位下，用户能看到本区间内
自定义字段值桶的分布（字段名 + 值桶 + 笔数 + 金额）。洞察页目前对
`CustomFieldStatsService` **零引用**，本批补齐这块，不新增任何聚合逻辑。

## 二、背景与用户价值

- 可扩展性评估的三缺口中，③「自定义字段进洞察」是唯一的小闭环功能项（评估结论：
  数据层零改动，复用现成纯函数聚合 + 参考实现就在隔壁）。
- 区间报表（`range_report_page.dart:119-130`）已实现同款能力：定义非空才查值行、
  `CustomFieldStatsService.aggregate` 聚合、值桶渲染（topN=8 +「其他」合并）。
  洞察页定位「切个周期快速看」，与区间报表「出报表」互补（边界见
  `prd/custom_time_scope_extension/design.md` §四），同一份值桶分布在洞察侧也应可见。

## 三、功能范围

### F1 新卡片：自定义字段汇总（洞察页，排行榜之后）

- 位置：洞察页卡片序列**末位**（分类构成/排行榜之后，`analytics_page.dart:1374` 的
  `_type != 'balance'` 块内、排行榜卡之后）。
- 显示条件：聚合结果**非空**才渲染（对齐 `range_report_page.dart:327`
  `if (data.customFields.isNotEmpty)`）；定义为空或值行为空 → 整卡不出现，无空态占位。
- 卡片铬沿用洞察页既有样式（surface 底 + 主色描边 + accent 竖条标题，
  `analytics_page.dart:1257-1283` 先例）；标题文案**复用**既有键
  `rangeReportCustomFieldTitle`（「自定义字段汇总」），零新增 l10n。

### F2 维度跟随与结余视角隐藏

- 收入视角 → 收入维度取桶排序；支出视角 → 支出维度（对齐 range_report 的 `_dim` 语义，
  `CustomFieldFieldStats.sorted(dim)`，`custom_field_stats_service.dart:37-48`）。
- **结余视角隐藏本卡**（与分类构成/排行榜一致，`analytics_page.dart:1374` 现状口径，
  记为行为冻结项）。

### F3 六档位通用

- 周/月/季/年/自定义/全部六档位均显示（各档 `start/end` 已由
  `resolveAnalyticsPeriod` 统一给出）；「全部」= 1970→今天 的大区间，聚合纯函数可承受
  （值行只扫 `custom_values_json` 非空的行）。

### F4 渲染逻辑共享（一处实现两处使用）

- 把 `range_report_page.dart:686-761` 的 `_customFieldStats` / `_customFieldValueRows`
  抽成共享 widget（内容区，不含卡片铬）：字段名 + 值桶行（标签、`analyticsTxCountShort`
  笔数、`AmountText` 金额），topN=8、超出合并「其他」（`commonOther`）。
- `range_report_page` 改调共享 widget，**其既有测试不改断言全绿**。

### F5 查询优化沿用

- 「定义为空跳过值行查询」（`range_report_page.dart:119-128`）在洞察侧同样成立：
  账本零定义时不发 `customFieldStatsRows` 查询。

## 四、验收标准

1. 收入/支出视角下，含自定义字段数据的账本在任一档位（含全部）都能看到值桶分布卡；
   金额、笔数、排序、topN=8 +「其他」合并与区间报表口径一致。
2. 定义为空 / 值行为空 / 结余视角 三种情况下卡片不出现，页面无异常、无空态占位。
3. 区间报表的自定义字段区块行为零变化（`range_report_page_test.dart` 原样绿）。
4. 新增/编辑交易（`statsRefreshProvider` +1）后卡片数字随下次查询刷新（键含 refreshTick）。
5. 卡片内文字全走 `PiggyTextTokens`，无新增 fontSize 字面量（U1 ratchet 不顶高）。
6. `flutter analyze` 0 issue；全量 `flutter test` 绿；`git diff --stat` 波及面仅限本批
   点名文件（**不得跑 `dart format .`**）。

## 五、未纳入（另批处理）

- **卡片注册表 + 命名数据包**（缺口②）：`prd/analytics_card_registry/`，本批卡片届时
  收编为注册表一员。
- 自定义字段的编辑/管理入口、海报包含自定义字段、值桶图表化（饼图/趋势）、
  字段间公式派生。
- 自定义字段明细钻取（点值桶跳交易列表筛选）——RangeReport 也没有，保持两处同构。

## 六、边界条件与潜在风险

- **R1 与主链路解耦**：卡片自取数据（见 design.md 决策 1），不并入
  `_loadCategoryData/_loadBalanceData` 的位次表——避免在批次②收编前先恶化
  `List<dynamic>` 耦合（`analytics_page.dart:68` 的越界注释、`:1038`
  `list[list.length - 1]` 的隐式约定都经不起插位次）。
- **R2 在途复用的时间差**：主卡片区有「在途查询继续渲染上一份结果」机制，本卡独立
  刷新，切换周期瞬间两区可能短暂显示不同区间的数据；下同后一致。附属卡可接受。
- **R3 超大区间**：「全部」档位下 `customFieldStatsRows` 全期扫描（仅非空值行），
  实测可接受即不优化；若真机掉帧，再考虑按期预聚合（另立批次）。
- **R4 多字段长卡**：字段多时卡片纵向变长，沿用区间报表行为（不折叠）；topN 合并
  已限制单字段行数。
- **R5 结余视角隐藏**是口径决定而非缺陷，测试钉住，防后人「顺手补上」破坏一致性。
