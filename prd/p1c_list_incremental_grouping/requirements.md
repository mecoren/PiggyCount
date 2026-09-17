# P1-C 列表增量分组 + provider 收敛 — 需求文档

## 一、背景

优化评估报告（docs/optimization-assessment-report/optimization-assessment-report.html，建议 7）指出：

1. **交易列表全量重算**：`transaction_list.dart` 的 `_buildFlatItems()` 在每次数据变化时
   对全部交易做「DateFormat 格式化 × n + 按天分组 + 天序排序 + 全部扁平项重建」，万级账本
   上单笔增删改的成本为 O(n log n)。现有指纹短路（引用/长度/首尾 id）只能挡住「同一列表
   引用的 rebuild」，Drift 每次 emit 都是新引用，必然全量重算。
2. **首页 watch 依赖链宽**：评估时首页顶层 watch 导致整页重建。

## 二、需求范围

### R1 交易列表增量分组（主要收益项）

- Drift stream emit 新列表后，与上次分组结果做增量 diff，只重建「内容发生变化的日分组」，
  不再全量重算。
- 单笔交易增/删/改的分组成本从 O(n log n) 降为 O(n) 轻量比较 + O(脏日) 重建。
- Drift 无实质变化的重复 emit（如无关表触发的 watch 重发）不再触发任何重建。
- 分组结果（日分组、日期索引、扁平项、日合计、Dismissible key、月份跳转）与全量重算
  完全等价——这是硬性正确性要求。

### R2 首页 provider 收敛（次要项）

- 调研结论：前期「D 方案」重构后首页顶层 watch 已大幅收敛（repositoryProvider 稳定、
  currentLedgerIdProvider 账本切换必须重建、cachedTransactionsProvider 仅启动阶段变化 2 次），
  剩余可收敛项只有 `aiAssistantEnabledProvider`（AI 开关切换时触发整页重建，实际仅头部
  一个按钮消费）。
- 将 `aiAssistantEnabledProvider` 的 watch 收敛到头部已有的 Consumer 子树内。

## 三、验收标准

### AC-R1

| # | 场景 | 预期 |
|---|------|------|
| 1 | 首次加载 | 分组结果与原全量算法一致（含跨月/跨年数据乱序输入） |
| 2 | 无变化重复 emit（新列表引用、内容值相等） | 不重建任何日分组（diff 返回 false） |
| 3 | 新增一笔交易（已有日） | 仅该日重建，日合计含新交易 |
| 4 | 新增一笔交易（新日期） | 新日插入正确排序位置，首/末日边框归属正确 |
| 5 | 修改交易日期（跨日移动） | 新旧两个日都重建 |
| 6 | 修改交易金额（同日） | 该日重建，日合计为新值 |
| 7 | 删除某日全部交易 | 该日从分组与扁平项中移除 |
| 8 | 预加载 fallback 列表（每次 rebuild 新 list 引用） | 值相等 → 无重建 |
| 9 | `jumpToMonth`、`_dateIndexMap`、VisibilityDetector key | 与重建前行为一致 |

### AC-R2

- AI 开关切换时仅头部 Consumer 重建，页面主体（StreamBuilder 子树）不重建。

### AC-通用

- `flutter analyze` 无新增 error/warning。
- 全量 `flutter test` 通过（现有 1172 项 + 新增单测）。

## 四、非目标

- 不做 keyset 分页 / 列表虚拟化改造（FlutterListView 已虚拟化）。
- 不处理评估报告「14 处 shrinkWrap: true 确认」项（不在 P1-C 标题范围）。
- `wrapInOuterCard = false` 的平铺旧风格保留原全量路径，不做增量（唯一调用方
  home_page 使用默认 true，平铺分支无调用方，YAGNI）。
- 不引入新的派生 provider 体系（现有 watch 各自合理，见 R2 调研结论）。
