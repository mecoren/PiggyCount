# 设计与技术决策（custom_field_full_link）

## 1. 数据形状

- **定义**：`custom_field_definitions`（v46）——按账本独立的 name/fieldType/
  sortOrder/syncId/updated_at，索引 `(ledger_id)` + 唯一 `sync_id`。
  fieldType 存字符串（amount/text/date），扩类型不改表。
- **交易值**：`transactions.custom_values_json`（v46，TEXT 可空）——
  `{fieldSyncId: value}` JSON 对象。键用 syncId 而非本地 int id，共享账本下
  Editor 写 Owner 定义的值天然可锚定，不需要 tag 那样的 override 表。
- **模板值**：`recurring_transactions.template_field_values`（v47，TEXT 可空）
  ——同一形状挂在周期模板上，生成实例时整包注入。
- **编解码唯一入口**：`CustomFieldValueCodec`
  （`lib/data/models/custom_field_values.dart`）——normalize（剔空/数值统一/
  嵌套剔除）、encode（键序稳定、空→NULL）、canonical（指纹/差分用规范化串，
  `1/1.0/1.00` → `1`）、三态契约（null=不改动 / {}=清空 / 非空=覆盖）。
  散落手写 jsonEncode 会让同一值在不同链路得到不同串 → 假差异 → outOfSync 空转。

## 2. 防漂移三不变量（v45 originalAmount 教训的全量复用）

1. **空即缺失**：NULL / `{}` / 全空值在 canonical 下都是 `''`；导出**仅非空写键**，
   绝不写 `?? {}` 兜底——否则「旧快照无此键」与「显式空对象」指纹不等价，
   引发永不收敛的假冲突。
2. **键序无关**：encode 按键排序输出，canonical 按键排序拼接。
3. **数值表示统一**：比较走 canonical（`1/1.0` 同串），存储保留 JSON 原生类型
   （金额回导后仍是数字）。

迁移侧配套：v46/v47 都是**纯新增、零回填**（回填 `{}` 会破坏不变量 1），
存量行导出与上一版本逐字节一致。

## 3. 同步合并语义（importRecurrings）

- 快照缺 `templateFieldValues` 键 → null → 本地列写 NULL（清空）。**必须与指纹
  语义一致**：指纹把缺键规范成 `''`，导入若「缺键保留本地值」，则已填值的本地行
  与云端永远差一个键 → 永不收敛（v45 曾在导入侧犯过对称性错误，见
  `original_amount_sync_test.dart` 的 A3 注释）。
- `lastGeneratedDate` 是唯一例外（机器本地生成进度，指纹刻意排除，导入取
  max）；模板值是数据本体，不享该待遇。
- 指纹白名单新增 `templateFieldValues` 一项（recurringCanon），跨设备「只改
  模板值」才会被判 different 并传播。

## 4. 幽灵键的两道防线

定义删除后，值键残留会让快照带脏数据、生成器注入渲染不出的值：

1. **源头**：`LocalCustomFieldRepository.deleteDefinition` 同时 strip 交易行
   （LIKE 粗筛 + Dart 精判，逐笔记 change）与周期模板（同策略，不逐行记账）；
2. **兜底**：生成器注入前按该账本**现存定义**过滤——云端先删的在途状态
   （本地模板尚未被云应用清干净）也不会把幽灵值写进新实例。

## 5. UI 接入点与取舍

- **录入**：`CustomFieldsSection`（编辑器与模板编辑页共用）；表单页取定义走
  Future 型 provider（`customFieldDefinitionsOnceProvider`）而非 Drift `watch()`
  流——watch 的 stream query 调度器会在组件测试里留下 pending Timer
  （recurring_edit_currency_test 踩过）；管理页是常驻页面，保留 watch 流。
- **明细角标**：`customFieldValueBadgesProvider` watch
  `custom_values_json IS NOT NULL` 的交易行，任何交易更新自动重发；字段名按
  定义反查、按定义排序输出；「全部账本」模式下他账本值解析不出名称 → 不显示
  （预期行为）。
- **统计卡**：`CustomFieldStatsService.aggregate` 纯函数（与
  original_amount_insight_service 同哲学）；SQL 只捞 `custom_values_json IS
  NOT NULL` 行（绝大多数账本 0 行），分组聚合在 Dart 侧做，不依赖 JSON1；
  日期桶键收敛 yyyy-MM-dd **仅对 date 类型字段**生效（文本值 "2026" 不许被
  误改写成日期）。

## 6. 同步证据源（B3）

`_localChangeEvidence`（方向仲裁的「本地确有未上云内容」断言）补入
`custom_field_definitions` 的 `MAX(updated_at)`/`MAX(created_at)`。v46 起定义
是快照 customFields 段的数据本体且带触碰触发器；漏掉它，定义-only 改动不留
持久痕迹 → 仲裁退化为 unknown → 字段定义同步不可靠。占位符 11→13，
`variables` 数量与注释同步更新（少给会整条语句抛错并被 catch 吞成无证据）。

## 7. i18n / a11y 收尾

- E2：4 个在途 `customField*` 键接线；96 个未用键用
  `scripts/i18n/check_status.dart` 清理（key + @key 全 arb 文件）后 gen-l10n；
  强证据/弱证据两级判定保留「疑似死键」不盲删的护栏。
- D1：基线 pages 340→347 / widgets 209→212（+7 记账在门禁注释）；就地收敛被
  否决的原因——`PiggyTextTokens` 成员携带 theme 行高（bodyLarge 1.28 /
  labelMedium 1.25）与字体族回退链，裸字面量继承环境 DefaultTextStyle
  （bodyMedium 链），逐处替换的净效果取决于命中点环境槽位，必须真机截图对比；
  9/10 无令牌档位。

## 8. 落地

- 提交：`fe72cd0`（v46 在途 + v47 全链路 + B×4 + E2/D1，2026-09-25）。
- 测试地图见 `requirements.md` 各节验收项。
