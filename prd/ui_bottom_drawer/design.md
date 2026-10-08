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

---

## 追加批次（2026-10-08）：存量表单页全量收口

> **上一条 11 的取舍已被本批推翻**：账户编辑（含编辑态）早已全部走 `showAccountFormBottomSheet`，本批又把剩余五个表单页（周期账单 / 标签 / 分类 / AI 服务商 / AI 提示词）也统一到抽屉，「新建抽屉、编辑全屏」的过渡期口径不再存在。

### 改造手法（五页一致，可直接照搬）

1. 在编辑页文件顶部加 `showXxxFormBottomSheet(context, {...})`：内部只调 `showPiggyFormSheet<T>(context, builder: (_) => XxxEditPage(...))`，把「怎么弹」集中到一处。
2. 页面 `build()` 由 `Scaffold(appBar: PiggyTitleBar, body: Padding(top: scrollablePadding) → Column → Expanded → Form → ListView)` 改为
   `PiggyFormSheet(title, cancelLabel, confirmLabel, onCancel: pop, onConfirm, confirmBusy, child: Form → Column(crossAxisAlignment: stretch))`：
   - `ListView` 去掉（`PiggyFormSheet` 内容区已自带滚动），否则嵌套滚动；
   - 外层 `Padding` / `Expanded` / 顶部 `topScrollablePadding` 全去掉（卡片 chrome 由 `PiggySheetCard` 统一提供）；
   - 底部「保存」按钮去掉（底部按钮行由 `PiggySheetActions` 提供）。
3. 分组卡 `SectionCard(borderColor: primary, margin: zero)` → `SectionCard(flat: true)`：`flat` 只透传 child，避免「卡片套卡片」（该参数就是为表单抽屉形态设计的，见 `section_card.dart` 注释）。
4. 标题栏 `actions` 逐项搬迁（删除 → 主体末尾描边按钮；次要入口 → 就近行的 `trailing` 图标按钮），不静默丢弃。
5. 全部 `Navigator.push(MaterialPageRoute(... EditPage ...))` 调用点改为 `await showXxxFormBottomSheet(...)`；返回值语义保持不变。
6. 各页的 `dispose` / 校验 / 保存 / 删除逻辑一行未动 —— 抽屉只是外壳。

### 风险与已验证项

| 风险 | 处置 |
|---|---|
| 表单内容超长（周期账单 12+ 字段、分类含图标网格） | `PiggyFormSheet` 内容区受限并内部滚动；分类页的图标网格本身是 `GridView(shrinkWrap: true, physics: NeverScrollableScrollPhysics())`，可直接嵌 |
| 抽屉内再弹选择器（分类 / 账户 / 币种 / 日期 / 父分类） | 与账户抽屉同款，`showModalBottomSheet` 可嵌套，5 页全部实测通过 |
| 标题栏 action 无处安放 | 见 requirements 的「落点」表；分类两枚、AI 提示词两枚、周期账单删除、AI 服务商保存均已安置 |
| 页面被别处当作路由 push（测试宿主 / 深链） | 全仓检索调用点逐个改为新入口；`tag_edit_page_result_test` 与 `recurring_edit_currency_test` 已同步调整并保持绿 |
| 缩进错位 | 大块结构上提后用 `dart format` 归一（只格式化了本批实际改动的文件） |

### 追加（2026-10-08 同日，同一批收口）：外壳两处体验修正

用户反馈两点，都改在**共享外壳** `lib/widgets/ui/form_sheet.dart` 上，一次覆盖全部表单抽屉：

1. **「取消｜保存」固定在卡片底部**。原结构把「标题 + 字段 + 按钮行」整体塞进一个 `SingleChildScrollView`（在 `PiggySheetCard` 内），长表单（周期账单 12+ 字段、分类图标网格、AI 提示词）必须滚到底才能看到/点到按钮。现在拆成：

   ```
   抓取条(32×4) → 标题(固定) → p16 → Flexible(loose) → SingleChildScrollView(字段区) → p20 → PiggySheetActions(固定)
   ```

   `Flexible(loose)` 是照 `PiggyPickerSheet` 的既有做法（本版 Flutter 给 Column 非 flex 子项的主轴约束无界，`Expanded` 会直接报 unbounded；loose flex 拿到的剩余高度有界，且不会把自然高度的子项撑满）。

2. **可下拉关闭**。原结构下长表单**完全无法拖动关闭** —— 探针测试实测：长内容时在标题上向下拖也不会关（整个卡片是滚动区，手势被 `Scrollable` 在手势竞技场里吃掉）；云同步那类短表单能拖，只是因为内容短、卡片本身不高。现在三处都能关：

   - 抓取条 / 标题 / 按钮行（非滚动区）→ 靠模态抽屉自身手势（`enableDrag` 默认开）；
   - 字段区 → 新增 `_DragToDismiss`：`NotificationListener<OverscrollNotification>`，只在**顶部**过度滚动累计（`overscroll < 0`），累计 ≥ 72 逻辑像素触发 `onCancel`，滚动开始/结束清零。字段区显式用 `ClampingScrollPhysics`：bouncing 物理在顶部回弹时**不发** `OverscrollNotification`，不固定物理 iOS 上就永远关不掉；代价是抽屉字段区不做回弹（各平台一致）。

### 顺带收口：加密「设置密码」抽屉

`lib/widgets/encryption/password_setup_dialog.dart` 是**手抄了一遍外壳**（`KeyboardBottomInsetPadding` + `SafeArea` + `p16` 留距 + `Material(surfaceElevated/radiusXl/antiAlias)` + 整卡 `SingleChildScrollView` + 自带标题与 `PiggySheetActions`），因此同样有「长内容按钮滚走 / 拖不动」的问题，还多一份 chrome 漂移风险。已改为直接返回 `PiggyFormSheet`（字段区外什么都不留），入口 `_showSheet` 也换成 `showPiggyFormSheet`，净减约 40 行。

> 备注：`AGENTS.md` 第 259 条对表单抽屉结构的描述（标题 → p16 → 字段 → p20 → 按钮行）**未同步**这两点（抓取条、按钮行固定）—— 该文件当时正被另一并发会话修改，本批没动，待其落地后补一句即可。
