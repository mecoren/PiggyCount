# 底部抽屉化改造设计文档

## 一、需求理解

将"记账"和"添加账户"两个核心入口从全屏页面改为底部弹出抽屉，参考 wait-home 项目的 `ExpandableBottomSheet` + `movie_form_bottom_sheet.dart` 实现模式。新建模式用抽屉，编辑模式保留全屏页（降低改造风险）。

## 二、参考资源

### 2.1 wait-home 参考实现（外部项目，下列为该仓库内相对路径）
- `lib/shared/widgets/expandable_bottom_sheet.dart` - 可扩展底部抽屉容器
- `lib/modules/movie/movie_form_bottom_sheet.dart` - 影视表单抽屉
- `lib/modules/movie/movie_form_body.dart` - 表单主体

### 2.2 BeeCount 现有实现
- `lib/pages/transaction/transaction_editor_page.dart` - 记账页面（全屏）
- `lib/pages/account/account_edit_page.dart` - 账户编辑页面（全屏）
- `lib/widgets/biz/amount_editor_sheet.dart` - 金额输入弹窗（showModalBottomSheet）
- `lib/widgets/transaction/transfer_form.dart` - 转账表单
- `lib/widgets/category/category_selector.dart` - 分类选择器
- `lib/styles/tokens.dart` - PiggyDimens (radiusXl=16, p12=12 等)

## 三、关键技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 抽屉容器实现 | 移植 `ExpandableBottomSheet` 到 BeeCount | 保持与 wait-home 一致，复用已验证的 snap/键盘避让逻辑 |
| 抽屉内导航 | `IndexedStack` + 状态字段控制（不用 Navigator） | 避免 Navigator 嵌套导致 pop 冲突，状态管理简单 |
| AmountEditorSheet 复用 | 抽取 body 部分为 `AmountEditorBody`，原 sheet 包装 body | 保持向后兼容（其他地方仍用 sheet），抽屉内用 body |
| 编辑模式处理 | 保留 `TransactionEditorPage`/`AccountEditPage` 全屏页 | 编辑场景少且复杂（含附件、标签等），抽屉改造风险高 |
| AppLink 兼容 | AppLink 深链仍 push TransactionEditorPage（全屏） | 不破坏深链路由 |
| 抽屉背景色 | `PiggyTokens.surface(context)` | 项目规范 |
| 抽屉顶部圆角 | `PiggyDimens.radiusXl` (16) | 与其他 bottom sheet 一致 |
| 标题栏 | `GlassTitleBar` (blur: false, showHighlightLine: false) | 与 wait-home 一致，纯色背景 |

## 四、实现步骤

### 步骤 1：移植 ExpandableBottomSheet 组件

**文件**：`lib/widgets/ui/expandable_bottom_sheet.dart`（新建）

从 wait-home 移植 `ExpandableBottomSheet`，调整：
- 顶部圆角改用 `PiggyDimens.radiusXl`
- 背景色改用 `PiggyTokens.surface(context)`
- 标题栏用 BeeCount 的 `GlassTitleBar`（已存在）
- 保留 `_KeyboardBottomPadding` 和 `_DragHandle` 实现
- 保留 snap 行为和 `shouldCloseOnMinExtent`

### 步骤 2：实现记账底部抽屉

**文件**：`lib/pages/transaction/transaction_form_bottom_sheet.dart`（新建）

实现：
1. `showTransactionFormBottomSheet()` 顶层函数 - 弹出抽屉
2. `TransactionFormBottomSheet` ConsumerStatefulWidget - 抽屉容器
3. 内部状态：
   - `_selectedKind`: 'expense' / 'income' / 'transfer'
   - `_stage`: 'select' (分类选择) / 'input' (金额输入)
   - `_selectedCategory`: 选中的分类
4. 布局：
   - ExpandableBottomSheet (title 根据 stage 变化)
   - stage='select': 分段选择器 + CategorySelector / TransferForm
   - stage='input': AmountEditorBody（从 AmountEditorSheet 抽取）
5. 保存成功后 `Navigator.pop(context)` 关闭抽屉

**文件**：`lib/widgets/biz/amount_editor_sheet.dart`（修改）

抽取 body 部分为 `AmountEditorBody` widget：
- 原 `AmountEditorSheet` 保留（showModalBottomSheet 包装 AmountEditorBody）
- 新增 `AmountEditorBody` 暴露给抽屉使用
- 保持回调接口一致（onSubmit 等）

### 步骤 3：实现添加账户底部抽屉

**文件**：`lib/pages/account/account_form_bottom_sheet.dart`（新建）

实现：
1. `showAccountFormBottomSheet()` 顶层函数 - 弹出抽屉
2. `AccountFormBottomSheet` ConsumerStatefulWidget - 抽屉容器
3. 内部复用 `AccountEditPage` 的表单逻辑：
   - 提取表单字段和校验逻辑为 `AccountFormBody` widget
   - `AccountEditPage` 改为包装 `AccountFormBody`（保持向后兼容）
   - `AccountFormBottomSheet` 也包装 `AccountFormBody`
4. 保存按钮在 ExpandableBottomSheet 的 actions，调用 `AccountFormBody.save()`
5. 保存成功后 `Navigator.pop(context)` 关闭抽屉

**文件**：`lib/pages/account/account_edit_page.dart`（修改）

提取表单主体为 `AccountFormBody` widget：
- 原 `_AccountEditPageState.build` 的 body 部分移到 `AccountFormBody`
- `AccountEditPage` 改为 Scaffold + GlassTitleBar + AccountFormBody
- `AccountFormBody` 暴露 `save()` 方法供外部调用

### 步骤 4：接入入口

**文件**：`lib/app.dart`（修改）

- 找到记账按钮的点击处理（`_handleAddTransaction` 或类似）
- 改为调用 `showTransactionFormBottomSheet()`（新建模式）
- 编辑模式仍 push `TransactionEditorPage`

**文件**：`lib/pages/account/accounts_page.dart`（修改）

- 找到 `_addAccount` 方法
- 改为调用 `showAccountFormBottomSheet()`（新建模式）
- 编辑模式仍 push `AccountEditPage`

### 步骤 5：验证

- `flutter analyze` 0 errors
- 手动验证：首页记账按钮 → 抽屉弹出 → 选分类 → 输金额 → 保存 → 抽屉关闭
- 手动验证：资产管理添加按钮 → 抽屉弹出 → 填表单 → 保存 → 抽屉关闭
- 验证 AppLink 深链仍能打开 TransactionEditorPage
- 验证编辑交易/账户仍能打开全屏页

## 五、文件清单

| 文件 | 类型 | 描述 |
|------|------|------|
| `lib/widgets/ui/expandable_bottom_sheet.dart` | 新建 | 可扩展底部抽屉容器（移植自 wait-home） |
| `lib/pages/transaction/transaction_form_bottom_sheet.dart` | 新建 | 记账底部抽屉 |
| `lib/pages/account/account_form_bottom_sheet.dart` | 新建 | 添加账户底部抽屉 |
| `lib/widgets/biz/amount_editor_sheet.dart` | 修改 | 抽取 AmountEditorBody 供抽屉复用 |
| `lib/pages/account/account_edit_page.dart` | 修改 | 提取 AccountFormBody 供抽屉复用 |
| `lib/app.dart` | 修改 | 记账按钮接入抽屉入口 |
| `lib/pages/account/accounts_page.dart` | 修改 | 添加账户按钮接入抽屉入口 |

## 六、风险与边界条件

1. **AmountEditorSheet 改造风险**：抽取 body 时需保持原有回调接口，避免破坏其他调用方
2. **TransferForm 嵌套风险**：TransferForm 内部若有 Navigator.push（如选账户），抽屉内可能冲突。需测试并可能调整为回调式
3. **键盘避让风险**：抽屉 + 键盘 + DraggableScrollableSheet 三者协调，用 `_KeyboardBottomPadding` 隔离 viewInsets 重建
4. **AppLink 兼容风险**：AppLink 深链仍 push TransactionEditorPage，不调用抽屉
5. **编辑模式风险**：编辑现有交易/账户时仍用全屏页，降低改造风险
6. **CategorySelector 联动风险**：CategorySelector 内部可能有 Navigator 调用（如长按编辑分类），需测试

## 七、验证标准

1. ✅ `flutter analyze` 0 errors
2. ✅ 首页记账按钮 → 抽屉弹出（不跳转页面）
3. ✅ 抽屉内可切换支出/收入/转账
4. ✅ 点击分类后抽屉内切换到金额输入
5. ✅ 金额输入保存成功后抽屉关闭
6. ✅ 资产管理添加按钮 → 抽屉弹出（不跳转页面）
7. ✅ 账户表单填写、校验、保存正常
8. ✅ 支持向上拖动扩展、向下拖动关闭
9. ✅ 键盘弹出时内容正确上移
10. ✅ AppLink 深链仍能打开全屏页
11. ✅ 编辑交易/账户仍能打开全屏页
