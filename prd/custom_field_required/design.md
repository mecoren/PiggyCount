# 设计文档：自定义字段「必填校验」

## 1. 需求理解

在自定义字段定义上增加「必填」开关（数据列 + 同步 + 管理 UI），在手工记账表单提交口对必填字段做拦截校验（红色 `*` 标记 + Toast 提醒）。批量路径（导入/恢复/模板）不拦。数据层新增一列 + 快照格式升一版，UI 与校验只动记账链路。

## 2. 关键技术决策

### D1：新列 `is_required`，纯新增零回填

`CustomFieldDefinitions` 增 `BoolColumn get isRequired => boolean().withDefault(const Constant(false))();`（列名 `is_required`，INTEGER NOT NULL DEFAULT 0），`schemaVersion` 54 → 55，`onUpgrade` 用现成的 `_addColumnIfMissing` 范式（仿 v54 的 `options_json`）。

**理由**：与 v45/v46/v54 的「纯新增、防漂移」迁移范式一致；DEFAULT 0 保证存量行零回填恒为 false，升级即语义正确。改完跑 `dart run build_runner build --delete-conflicting-outputs` 重生成 `db.g.dart`。

### D2：快照格式 v13 → v14，完全复用 options 的收敛机制

- 导出：`transactions_json.dart` `customFieldItems` **恒写** `'isRequired': f.isRequired`（含 false）。
- 导入：键存在三态——`m['isRequired'] is bool ? 值 : null`（缺键 = 真·旧快照 → 保留本地；显式值 = 云端权威覆盖），与 v13 `options` 键同款语义。
- 指纹：`sync_fingerprint.dart` `customFieldCanon` 纳入 `'isRequired': f['isRequired'] == true`（缺键规范成 false）。
- 版本：`kSnapshotFormatVersion` 13 → 14，注释补 v14 条目；升级触发 `shouldRepublishSnapshotForFormatUpgrade` 一次性全量重传门控，旧云端快照自动收敛，不会永久 outOfSync。

**理由**：必填是定义的组成部分（跨设备必须一致），走定义同步实体是唯一正确位置；恒写 + 三态 + 版本门控是 v13 已验证过的组合，零新机制。

### D3：校验只做在 UI 提交口

`amount_editor_sheet.dart`「完成」键路径，在分类必拦校验之后、`_isSubmitting = true` 之前插入：
1. 先 `_applyCustomFieldAmountValues()`（把金额键盘暂存的字符串值并入 `_customValues`，规避 R4）；
2. 取 `customFieldsForCurrentLedgerProvider` 定义，筛 `isRequired` 且未填的字段名；
3. 非空则 `showToast(l10n.customFieldRequiredMissing(names))` 并 return（同款交互见分类必拦范式）。

「已填」判定用 `CustomFieldValueCodec.normalize(_customValues)` 后 `containsKey(syncId)`——与落库语义同口径（金额 0 合法、空串/空列表 = 未填）。

**理由**：CSV 导入、云端恢复、周期账单生成器等批量路径不拦，避免历史数据回填被卡死；UI 口拦截是唯一手工入口，改动面最小、可测性最好。

### D4：UI 标记与开关，不动危险确认

- `_CustomFieldEditSheet`（custom_field_manage_page.dart）：类型选择器下方加「必填」Switch 行（`bool _isRequired`，初值 `widget.existing?.isRequired ?? false`），随 `createDefinition/upsertDefinition/updateDefinition` 落库；管理列表 tile 副标题加「· 必填」徽标。
- `CustomFieldsSection._buildRow`（custom_field_input.dart）：`def.isRequired` 时字段名后缀红色 `*`（错误色取 token）。
- 必填开关**不进** `detectCustomFieldEditHazard` 双重危险确认（非破坏性）。

**理由**：与现有编辑弹窗/录入控件结构完全一致，纯增量；危险确认只留给改类型/删选项这类会丢数据的变更。

### D5：仓储签名三态对齐 options

`custom_field_repository.dart` + `local_custom_field_repository.dart`：
- `createDefinition/upsertDefinition` 增 `bool isRequired = false`；
- `updateDefinition` 增 `bool? isRequired`（null = 不改动，与 options 三态同款），Companion 写列；`_recordDefinitionChange` 已随 update 记 change，无需额外处理。

## 3. 实现步骤（≤5 步）

1. **数据层**：db.dart 增列 + schemaVersion 55 + `if (from < 55)` 迁移（`_addColumnIfMissing`）；`dart run build_runner build --delete-conflicting-outputs` 重生成 db.g.dart；仓储接口与实现增必填参数。
2. **同步层**：kSnapshotFormatVersion 13→14 + 注释；导出恒写 `isRequired`；解析三态；`customFieldCanon` 纳入；`data_import_service.dart` `ImportCustomField` 增 `bool? isRequired` 并在归并对齐/新建分支随 `updateDefinition/upsertDefinition` 传入。
3. **UI 与校验**：编辑弹窗「必填」开关 + 列表徽标；`CustomFieldsSection` 红色 `*`；`amount_editor_sheet` 提交校验 + Toast。
4. **多语言**：4 个 arb（zh / zh_TW / en / ko）增 `customFieldRequiredLabel` / `customFieldRequiredHint` / `customFieldRequiredBadge` / `customFieldRequiredMissing`（带 `{names}`），`flutter gen-l10n`。
5. **测试与验证（TDD 先红后绿）**：`test/data/migration_v55_test.dart`（旧库升级列存在、存量行 false、新插入 true）；`test/widgets/custom_field_editor_test.dart` 扩展（`*` 显示、未填拦截不出 onSubmit、填写后提交、编辑被拦）；同步契约测试更新（恒写键、指纹、三态、常量 14）；`flutter analyze` + `flutter test` 全绿 + 手动冒烟。

## 4. 边界条件与潜在风险

| 编号 | 风险 | 处置 |
|---|---|---|
| R1 | 旧客户端读 v14 快照 | 未知键宽容，旧端忽略 `isRequired` 不炸；新端缺键三态保本地 |
| R2 | 编辑存量交易被拦 | 用户已确认接受（编辑时补填） |
| R3 | 金额键盘暂存值导致误判未填 | 校验前强制 `_applyCustomFieldAmountValues()` |
| R4 | 周期账单模板页复用同一录入控件会显示 `*` | 显示无害；但模板保存**不拦**（模板是配置不是交易） |
| R5 | 迁移并发/漂移 | `_addColumnIfMissing` 幂等，重复升级安全 |

## 5. 不做的事（明确排除）

- 不做行内红字逐字段报错，只做 Toast 拦截。
- 不拦 CSV 导入、云端恢复、合并「一键应用全部」、周期账单生成。
- 不回填/不校验历史存量交易（只在编辑该交易时拦）。
- 不把必填纳入 `detectCustomFieldEditHazard` 危险确认。
- 不改快照 v13 及更早版本的解析兼容逻辑。
