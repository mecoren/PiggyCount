# 账本自定义字段全链路（custom_field_full_link）

一轮双版本：**v46**（字段定义 + 交易自定义值，2026-09-22 前后在途）与
**v47**（周期账单模板级字段值 + B×4 扩面收尾，2026-09-25）。本文按
「要做什么 / 验收标准」记录，技术决策见同目录 `design.md`。

## 需求理解

用户需要在本应用没有原生建模的维度上给账单挂信息（如「项目」「客户」「税费」），
且这些维度要能：跨设备同步、按账本隔离、可以放进周期账单让生成的实例自动带上、
在明细与统计里可见、CSV 导出/回导不丢。

## 需求范围与验收标准

### R1 定义与值（v46）

- 字段定义按账本独立（amount / text / date 三类，新增类型不动库结构）；
- 交易上的值以**定义的 syncId** 为键落在 `transactions.custom_values_json`
  （共享账本下 Editor 写 Owner 定义的字段无需 override 表）；
- 记账编辑器有录入分区（amount 数字键盘 / text 限长 / date 滚轮）；
- 「设置 → 数据管理」可达字段管理页：增删改 + 拖拽排序 + 删除前提示影响面；
- **验收**：`test/data/custom_field_repository_test.dart`、
  `test/data/custom_field_values_test.dart`、`test/widgets/custom_field_editor_test.dart`。

### R2 周期账单模板级字段值（v47，A2）

- `recurring_transactions` 新增可空列 `template_field_values`（零回填）；
- 生成实例时模板值**整包注入**实例的 custom_values_json；实例侧再改不影响模板，
  下一笔生成仍按模板值；
- 快照导出/解析/指纹白名单/importRecurrings 全链路透传，且满足防漂移三不变量
  （见 design.md §2）；
- 模板编辑页有与交易编辑器同款的录入分区；换账本自动剪掉不属于新账本的键；
- **验收**：`test/data/migration_v47_test.dart`、
  `test/services/data/recurring_template_field_values_test.dart`（含幽灵键防御）、
  `test/cloud/recurring_template_values_sync_test.dart`（跨设备指纹往返）。

### R3 B×4 扩面（本轮拍板纳入）

1. **明细展示**：账本明细行次要信息显示 `字段名: 值` 角标（无值不渲染，日期按
   本地格式化）；主列表已接，其余 `TransactionListItem` 调用点参数已留好；
2. **统计/洞察**：区间报表页新增「自定义字段汇总」卡——按字段聚合区间内交易的
   收支/笔数（Top 8 + 「其他」），纯函数聚合服务可单测；
3. **共享账本字段定义管理**：字段定义纳入方向仲裁证据源（`cf_u`/`cf_c`），
   定义-only 改动（建/改名/改类型/排序/删）不再让同步退化为 unknown；
4. **CSV 自动建字段**：导入 CSV 的「自定义字段」列里本地没有的字段名，按列值
   推断类型自动建定义（全数值→amount / 全日期→date / 否则 text）并接住值。
   **这 supersede 上一轮「只建映射、不建定义」的契约**（对应测试已更新）；
- **验收**：`test/services/custom_field_stats_service_test.dart`、
  `test/pages/data/import_confirm_page_test.dart`（自动建字段契约）、
  `test/cloud/local_change_evidence_test.dart`（证据源扩展不回归）。

### R4 删除一致性

- 删除字段定义同时清理两个载体：交易行上的值（记 transaction update change）与
  周期模板上的值（不逐行记账，模板整行以快照为准传播）；
- 生成器注入前按**现存定义**过滤（云端先删的在途幽灵键不得进新实例）；
- **验收**：`recurring_template_field_values_test.dart` 幽灵键用例。

### R5 i18n / a11y 收尾（E2 / D1）

- 接线 4 个在途 `customField*` 键（创建/更新成功提示、排序提示、空态提示）；
- 删除其余 96 个未用键（含 `commonUnitYuan`），四语言键数对齐、未用键归零；
- 字号 ratchet 基线实测化（pages 347 / widgets 212），上移构成与收敛计划写入
  门禁注释；本轮新增 UI 的字号一律走令牌；
- **验收**：`dart scripts/i18n/check_status.dart` 报 0 未用、四语言 100%；
  `flutter test test/styles/font_size_token_ratchet_test.dart` 绿。

## 明确不做（本轮边界）

- **明细角标只接主列表**：搜索/日历/账户详情/标签/分类详情页的接入参数已留好，
  未逐页接线；
- **统计卡只进区间报表**：年报页、金额偏差页不展示自定义字段维度；
- **快照同步下删除定义不跨设备传播**：apply 是 upsert-only（与标签/预算同策略，
  防旧快照误删），仅全量恢复路径删除缺失定义；
- **recurring `currency_code`（v42）不入快照/指纹**：补上会让所有带周期账单的
  用户指纹整体位移（强制一轮重同步），待单独立项拍板；
- **D1 剩余收敛**：在途 9 处字面量与 9/10 超小档需真机视觉评审，清单与顺序在
  ratchet 门禁注释里。

## 已知边界（发布说明候选）

- 混版本：v47 之前的客户端上传的快照缺 `templateFieldValues` 键，新客户端拉取
  应用后会把模板值清空（与 v45 originalAmount 同款跨版本语义）；
- 模板值是「生成时快照」：改模板不影响已生成的实例；
- CSV 自动建字段是静默的；类型推断保守（一列混入非数值即整列按 text）。
