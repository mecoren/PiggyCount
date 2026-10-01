# P1-E 快捷记账模式 — 设计文档

> 需求见同目录 `requirements.md`。本文档写「怎么实现」与取舍，不重复需求背景。
> 五个待拍板项见 `requirements.md` 第五节，下文按**建议选项**展开（记忆来源 A、金额优先方案 2、
> 不记忆类型、加设置开关、换分类保留金额）。

## 一、需求理解

把「记一笔」的进入落点从**分类网格**改为**金额表单**，分类由「上次记这个类型的分类」自动预填；
同时补上金额表单里**完全缺失的分类可见性**（`amount_editor_sheet.dart:44` 字段注释明写
「不在 UI 展示」）。分类仍可一键更换，换分类回到网格——即现有流程变成快捷模式的**退路**而非主路。

关键是本需求**不需要新的提交路径**：`initState`（`transaction_editor_page.dart:137-163`）已经在做
「给出 `initialCategoryId` 就自动直落金额表单」，小组件 deep link 走的就是这条。本需求只是让
「记住的分类」成为 `initialCategoryId` 的第二个来源。

## 二、关键技术决策

### 决策 1：R1 用「索引倒序游走 + K 上限」，不做 schema 迁移

候选 SQL：

```sql
SELECT category_id, category_sync_id_override
FROM transactions
WHERE ledger_id = ? AND type = ? AND happened_at IS NOT NULL
ORDER BY happened_at DESC, id DESC
LIMIT ?
```

已核实 `transactions` 上有 v32 建的复合索引 `idx_transactions_ledger_happened
ON transactions(ledger_id, happened_at)`（`db.dart:1256-1258` 迁移、`db.dart:1483-1485`
`onCreate` 同步建，新装库也有），`ledger_id = ?` 等值 + `happened_at DESC` 排序可被它一次满足。

**但 `type` 与 `category_id` 都不在索引里**，SQLite 需回表逐行判定，所以「倒序找到第一行匹配」
在病理场景下（如最近 10 万笔全是支出、用户要收入的记忆）可能回表十万次。取舍：

- **方案 A（选定，已按实现修正）**：SQL 加 `LIMIT 100`，在 Dart 侧取第一个非空分类。**零 schema 变更**。
  代价：最近 100 笔内没有同类型交易时记忆 miss → 退回网格。而本功能 miss 的后果只是
  「和改动前一样」，没有正确性损失。

  > **⚠️ 实现期修正（2026-09-18，由单测在实现当天测出）**
  >
  > 本节最初给出的 SQL 是
  > `WHERE ledger_id = ? AND type = ? AND happened_at IS NOT NULL ... LIMIT ?`，
  > 并断言「工作量上界 = 100 次索引项 + 至多 100 次回表」。**这个推理是错的。**
  >
  > SQLite 的 `LIMIT` 约束的是**结果行数**，不是**扫描行数**。`type = ?` 在 WHERE 里
  > 属于过滤条件，不计入 LIMIT 的计数；因此当最近 K 笔都不是目标类型时，SQLite 必须
  > 沿索引一路回表扫描，直到凑满 K 行**匹配**记录（或扫完整个索引）才返回 ——
  > **上界在病理场景下直接丢失，退化成与被否决的方案 C 同量级的 O(N)。**
  >
  > 暴露它的用例：`scanLimit 生效：窗口内没有同类型交易时返回 null`
  > （K=3 时返回了那笔旧支出，而按本节语义应为 null）。
  >
  > **修正后**：`type` 过滤移出 SQL、交给 Dart 侧，SQL 只保留
  > `WHERE ledger_id = ? AND happened_at IS NOT NULL ORDER BY happened_at DESC, id DESC LIMIT ?`
  > —— 此时 `LIMIT` 才真正等价于「只看最近 K 笔」，K 次索引项 + 至多 K 次回表的
  > 上界才成立。SQL 字符串以 `quickEntryLastCategorySql` 导出，单测对**同一份**
  > 语句跑 `EXPLAIN QUERY PLAN`，防止将来有人把 `type` 挪回 WHERE 或改坏 ORDER BY。
  >
  > 教训与本仓库既有的一条完全同源：**性能结论必须实测，不能推理**。
  > 本文档上一版正是引用着那条教训、又犯了一次同类错误。

- 方案 B（暂不采用）：加 `(ledger_id, type, happened_at)` 覆盖索引（迁移 v36）。保证一次索引 seek，
  但要再加一次迁移 + 迁移测试。**升级触发条件**：若实测「最近 100 笔无同类型交易」在真实用法中常见
  （例如用户在收入/支出间大幅来回切换），再补 v36 索引。
- 方案 C（否决）：照搬 `getNoteHistory` 的 `GROUP BY` 全账本聚合
  （`local_transaction_repository.dart:800-816`）。功能等价但代价是无上界的全表扫，比方案 A 严格更差。

**验证手段（必须做）**：单测里跑
`EXPLAIN QUERY PLAN` 并断言输出包含 `idx_transactions_ledger_happened`
（且**不**含 `SCAN transactions`）。这样后续任何改动把查询退化成全表扫都会被测试拦住——
本仓库此前已有「性能断言写错、实测才发现无上界」的教训，这条断言把结论钉死在 CI 里。

### 决策 2：共享账本的分类在**读取时**派生 synthetic id，绝不持久化

共享账本下 Owner 分类以 `category_id = NULL` + `category_sync_id_override = <syncId>` 落库
（该列见 `db.dart:142`；同一约定见 `local_transaction_repository.dart:786-793` 的备注历史过滤）。
所以 R1 读到的行有两类：

| 行的形态 | 返回 | 说明 |
|---|---|---|
| `category_id` 非空 | 该 int id | 普通本地分类路径 |
| `category_id` 为 NULL、`category_sync_id_override` 非空 | `syntheticIdForSyncId(override)`（负数） | 与 `CategorySelector` / `initialCategoryId` 现有约定一致，`transaction_editor_page.dart:143-151` 已能处理 `id < 0` |
| 两者皆空 | 跳过该行，继续往前找 | 该笔无分类 |

**硬约束：synthetic id 只在读取时派生，绝不存在任何持久化位置。**
依据：`syntheticIdForSyncId`（`utils/shared_ledger_picker_filter.dart:26-30`）用 Dart
`String.hashCode` 派生负数 id，其跨 Dart VM 版本/平台的稳定性**没有任何保证**。一旦把派生值
写进 SharedPreferences，某次 Flutter 升级后哈希实现变化，存储的 id 就会指向另一个（或不存在）分类。
这正是「记忆来源必须从 `transactions` 派生（方案 A）而非存 pref（方案 B）」的决定性理由——
**不是性能差异，是正确性差异**。

### 决策 3：R1 结果用常驻 `FutureProvider` 预热 + 写后失效，不在点击时同步等

- 新增 provider（`lib/providers/`，跟随现有命名习惯）：按 `kind` 分族，读
  `currentLedgerIdProvider`，`keepAlive`，暴露给 UI 时用 `.valueOrNull` **同步**读取。
- **预热**：首页首帧后 fire-and-forget 读一次（`ref.read(provider('expense').future)` 不必 await），
  使 FAB 被点击时缓存已就绪，**点击到出表单之间没有 DB 往返延迟**。
- **失效锚点（实现期修正，2026-09-18）**：原文写「唯一写入点 `transaction_editor_page.dart:558-563`
  一带追加一句 `ref.invalidate(quickEntryCategoryProvider)`」——**该前提经全库 grep 不成立**：
  交易写入点有十来处（编辑器保存 / 明细页删除 `transaction_list.dart:696` / 分类详情
  `category_detail_page.dart:534` / 标签详情 `tag_detail_page.dart:511` / AI 对话 / 图像语音
  `PostProcessor` 五处 / 自动化记账 `auto_billing_service.dart` / CSV 导入
  `import_confirm_page.dart` / 云恢复 `cloud_sync_page.dart` + `sync_providers.dart:214`）。
  逐个挂线等于把「刷新漏一处 → 记忆陈旧」的风险面复制十来份，且新增写入点必然漏挂。
  **改为一句话解决**：provider 跟随 `statsRefreshProvider` 重算 —— 它正是上述所有写入点
  本来就**都会** bump 的粗粒度「数据变了」信号。代价只是一次走索引且 LIMIT 有界的查询，
  正确性由构造保证：今后新增写入点只要遵守既有约定（写完 bump 统计刷新）就自动被覆盖。
- 常驻性：Riverpod 2 里普通（非 `.autoDispose`）`FutureProvider.family` 即为常驻，
  无需额外 `keepAlive`。
- 账本切换天然正确：provider 读 `currentLedgerIdProvider`，账本变更自动重算。

### 决策 4：`AmountEditorSheet` 补分类位（唯一硬约束）

- 新增可选参数：`categoryDisplayName`、`categoryDisplayIcon`（或直接传 `Category`）与
  `onPickCategory`（null 表示不可换，如编辑交易的既有调用方）。
- 位置：金额表达式行（`amount_editor_sheet.dart:660-710`）上方或同排——具体以视觉稿为准，
  但必须在**金额键盘的视觉主注视区内**，不能藏在备注/标签之下。
- 现有调用方（编辑交易、小组件带分类）自动获得该分类位，行为一致——**刻意不做「只有快捷模式才显示分类」
  的分叉**，否则同一个表单会有两套信息层级。

### 决策 5：落点切换复用 `initState` 自动开窗路径，不做第二条提交链

- `TransactionEditorPage` 新增 `quickMode`（或复用现有 `quickAdd` 语义扩展）。`initState` 的
  自动开窗条件从「`initialCategoryId != null`」放宽为
  「`initialCategoryId != null` **或** 快捷模式且 R1 命中」，命中后走**同一个** `_onCategorySelected`。
- **换分类回路**：分类位点击 → 金额表单 `Navigator.pop(ctx, 当前金额)` → 回到编辑器抽屉
  （它一直挂在下层）→ 用户点新分类 → `_onCategorySelected` 重新弹金额表单，并把 pop 回来的金额
  作为 `initialAmount` 传入（编辑器侧加一个 `_lastAmount` 字段兜住）。
  **这样「换分类保留已输金额」（待拍板 #5 的建议选项）用 ~5 行实现，不需要把金额提升成额外状态源。**
- **免费获得通用退路**：金额表单可下拉/关闭，关掉就落在分类网格上——这正好满足
  `requirements.md` R4 里「不依赖设置开关的通用退路」。
- 记忆失效（分类已删/已隐藏/不属于当前账本）→ 不预填、不报错，落回网格：**预填错分类的危害
  大于不预填**，所以校验规则一律从紧（详见第四节）。

### 决策 6：入口与设置开关

- FAB 点击路径 `app.dart:869-875`：改为按设置开关分流。长按扇形菜单（`:606-688`）**完全不动**。
- deep link：`piggycount://new?type=...` 不带 category 时，`app.dart:544-551` 推的
  `TransactionEditorPage` 带上 `quickMode: true`，使两条入口行为一致；
  带 category 的既有路径（小组件分类格）本就直落金额表单，保持不变。
- 设置项：pref 键 + `StateProvider` + `FutureProvider` 初始化，**逐字对齐**
  `showTransactionTimeProvider` / `showTransactionTimeInitProvider`
  （`providers/theme_providers.dart:162-170`）的既有双 provider 范式，不发明新写法。

### 决策 7：不新建 `QuickEntrySheet`（取舍记录）

`AmountEditorSheet` 已经是金额优先的表单，且含键盘、备注、账户、标签、附件、币种折算。
再造一个「更简」的表单会引入第二条提交路径（两处都要维护写库、附件、标签 override、共享账本
synthetic 翻译、后处理与同步触发——见 `transaction_editor_page.dart:426-578`，这块逻辑相当厚），
长期成本远高于收益。本需求只做「补分类位 + 改落点」。

## 三、实现步骤

1. **R1 数据层**：`BaseRepository` 增 `getLastUsedCategoryId`；`LocalRepository` 实现
   （K 上限查询 + synthetic 派生）。**先写 RED 单测**覆盖 `requirements.md` AC-R1 的 7 个场景
   （真实临时库，沿用 `test/data/database_health_service_test.dart` 的做法），其中含
   `EXPLAIN QUERY PLAN` 断言。
2. **provider**：新增快捷分类 provider（分族 / keepAlive / 写后失效），首页首帧预热。
3. **R2 表单**：`AmountEditorSheet` 加分类位参数 + 渲染 + 点击回调；`TransactionEditorPage`
   加 `_lastAmount` 与 `quickMode` 分支。
4. **R3 入口**：FAB 分流 + deep link `quickMode: true`。
5. **R4 开关**：设置页加开关 + pref 读写。
6. **widget 测试**：覆盖 AC-R2 的 7 个场景（尤其 #4 记忆失效不预填、#6 提交结果与旧路径等价）。
7. `flutter analyze --fatal-infos` + 全量 `flutter test`。
8. 手动回归：支出/收入/转账、编辑交易、小组件三入口、冷启动 deep link、共享账本账本下的记忆。

### 实现状态（2026-09-18）

| 步 | 状态 | 落点 |
|---|---|---|
| 1 R1 数据层 | ✅ | `local_transaction_repository.dart`（`quickEntryLastCategorySql` + `getLastUsedCategoryId`）；测试 `test/data/repositories/local/quick_entry_last_category_test.dart`（13 例，含 EXPLAIN 断言） |
| 2 provider | ✅ | `providers/quick_entry_providers.dart`；接入 `ui_state_providers.dart` 的 `appSplashInitProvider`；首帧预热在 `app.dart` initState |
| 3 R2 表单 | ✅ | `AmountEditorSheet.displayCategory` / `onPickCategory` + `_effectiveAmount()`；`TransactionEditorPage.quickMode` / `_lastAmount` / `_resolveCategoryById` |
| 4 R3 入口 | ✅ | `app.dart` `_openNewTransactionSheet()`（FAB 点击 + 调试悬浮按钮共用）；deep link `quickMode: categoryId == null && 开关` |
| 5 R4 开关 | ✅ | `appearance_settings_page.dart`（「显示交易时间」下一项）+ `appearanceQuickEntryMode{,Desc}` 四语言词条 |
| 6 widget 测试 | ✅ | `test/widgets/quick_entry_mode_test.dart`（分类位 5 例，含窄屏让位守卫 + 对照组；落点 6 例；provider 校验 4 例） |

实现期对决策 4 的一处收窄：分类位**不再**是「可换 + 只读」两种调用形态，
而是由 `onPickCategory` 是否非空决定 —— 当前金额表单只在 `quickAdd` 下被打开
（`_onCategorySelected` 的非 quickAdd 分支直接 pop 页面），所以调用点恒传回调；
参数保留 null 语义是为了让 `AmountEditorSheet` 自身不假设调用方。
位置落在金额表达式行**最左**（原本是 `Spacer()` 让出的空白）：不增加纵向高度，
从而规避决策 4 列出的「表单因此显得拥挤」风险。

决策 4 风险项「是否显得拥挤」经实现期实测后**如实收窄**：分类位的槽位宽度由
金额行决定（它是 `Expanded`，吃的是「币种标 + 算式」剩下的余量），窄屏 + 大字
模式下可能只剩二三十像素，而分类位内部「图标 + 间距 + 箭头」是三件不可压缩的
固定物。故分类位改为**按可用宽度三级让位**（`_buildCategoryChip`）：宽 ≥72 显示
图标+名字+箭头；≥53 收掉名字、留图标+箭头；再窄只留图标（最小 24px）。
守卫用例 `test/widgets/quick_entry_mode_test.dart` 的窄屏那条即为此设。

AC-R2 #6（提交字段等价）由**结构性**保证而非新增断言：`quickMode` 只改
`initState` 的自动开窗条件，提交链仍是同一个 `_onCategorySelected` → `onSubmit`，
未新增任何写库分支 —— 这也是「不新建 QuickEntrySheet」这条非目标的直接收益。

## 四、边界条件与风险

| 风险 | 缓解 |
|------|------|
| **误报错分类（最高危）**：预填了不属于当前账本/已删除的分类，用户顺手保存 → 记到错分类 | 预填前逐项校验：id 存在、属于当前账本、未被隐藏；共享账本 synthetic id 必须能在 `SharedLedger*` 里反查到同一 `ledgerSyncId`。任一不满足即静默退回网格。**宁可不预填** |
| 索引被误用成全表扫 | 决策 1 的 `EXPLAIN QUERY PLAN` 单测断言（CI 硬拦） |
| 病理场景 K 上限 miss（最近 100 笔无同类型交易） | 后果 = 退回现有网格流程，无正确性损失；实测命中率低则上 v36 覆盖索引 |
| 点击到出表单的延迟 | provider 预热 + 同步读缓存；若缓存未就绪则退回网格（不做「先出网格再跳表单」的闪跳） |
| 缓存陈旧（刚记完一笔，记忆没更新） | 决策 3 的写后 `invalidate` 与既有刷新点同址；单测覆盖「新增后立即查询」 |
| 已有调用方漏传分类位导致表单信息层级不一致 | 分类位参数设为可选但**默认按传入的分类渲染**；编辑交易路径一并传（决策 4） |
| 设置开关与旧流程漂移（关掉后行为不等于改动前） | AC-R4 #1 以「逐帧一致」为验收口径；开关关闭时不进入任何新代码分支 |
| 转账类型 | 转账无分类语义，快捷模式只作用于 expense/income；`initialKind == 'transfer'` 直接走现有 `TransferForm`，不碰 |
| 金额/账户/币种的默认值 | 全部沿用 `_getDefaultAccountId`（`transaction_editor_page.dart:350-379`，含币种匹配与隐藏账户兜底）与现有 `AmountEditorSheet` 初值逻辑，不另起一套 |

## 五、工作量拆解（对齐报告「工作量 中」）

| 块 | 内容 | 量级 |
|---|---|---|
| R1 | 仓库方法 + 7 个单测（含 EXPLAIN 断言） | 小 |
| provider | 分族 provider + 预热 + 失效 | 小 |
| R2 | `AmountEditorSheet` 分类位 + `_lastAmount` + `quickMode` 分支 | 中（表单改动需视觉确认） |
| R3 | FAB 分流 + deep link 参数 | 小 |
| R4 | 设置开关 + pref | 小 |
| 测试 | AC-R2 的 7 个 widget 场景 | 中 |

主要不确定性集中在 R2 的视觉表现（分类位放哪、金额表单是否因此显得拥挤），需实机看效果再定。

## 六、2026-10-01 迭代：分类退化为记账表单的**子界面**

### 问题（用户反馈）

- 点「记账」看到的是分类网格（记忆未命中时）或「网格 + 盖在上面的金额表单」（命中时）——
  用户期望的是：**点记账只出记账界面，点分类才出分类界面**。
- 点金额表单的分类位时，表单会 `pop` 掉回分类网格（决策 5 的换分类回路）——
  用户描述为「弹出时把记账页面缩进去了」。

### 变更

| 维度 | 旧（决策 5 / 决策 4） | 新 |
|---|---|---|
| 记账落点 | `ExpandableBottomSheet`（`DraggableScrollableSheet`）+ `CategorySelector`；命中记忆时再在其上叠加 `AmountEditorSheet` | 直接渲染金额表单；分类网格**不再默认出现** |
| 分类形态 | 记账抽屉的正文 = 分类网格 | 记账表单的**子界面**：点分类位才用 `showCategoryPickerSheet` 叠加弹出 |
| 换分类 | `pop` 金额表单 → 回网格重选 → 以 `_lastAmount` 重弹表单 | 子界面返回新分类，表单**不关闭**，`setState` 就地更新分类位 |
| 记忆未命中 | 退回分类网格（AC-R2 #4/#5 旧口径） | 仍出金额表单，分类位显示「选择分类」占位 |
| 分类归属 | 调用方闭包捕获，提交时写库 | 表单内部持有（`AmountEditorSheet._category`），随 `AmountEditorResult.category` 回传 |

### 关键取舍

1. **不再用 `ExpandableBottomSheet`**：那个容器的意义是「分类网格与抽屉共享 `ScrollController`，
   拖网格即改变抽屉高度」。分类退成子界面后，共享控制器正是「弹出/滚动分类时记账界面被顶高或收起」
   的成因；金额表单本身自适应高度，不需要伸缩语义。
2. **`onPickCategory` 语义从「回传金额、由调用方 pop」改为「返回新分类」**：
   入参保留 `(current, currentAmount)` —— `currentAmount` 只服务**仍走网格的旧路径**
   （快捷开关关闭 / 编辑交易），它靠 `_lastAmount` 实现「换分类保留已输金额」。
3. **异步初值后补而非阻塞渲染**：记忆分类与默认账户都要查库，若等它们就绪再渲染会闪。
   改为先出表单（分类位占位、「无账户」高亮），解析完成后经
   `AmountEditorSheet.didUpdateWidget` 补上；用户已手动选过则不覆盖（`_categoryPicked` /
   `_accountPicked`）。
4. **提交逻辑抽成 `_persistTransaction`**：新形态只有一层 modal、旧形态有两层，
   差别只在关几层；写库语义（附件 / 标签 / 共享账本 synthetic override / 同步触发 / 缓存刷新）
   必须逐字一致，所以抽成同一方法，避免两条提交链漂移（呼应「非目标：不做全新 QuickEntrySheet」）。
5. **允许无分类提交**：分类位是占位而非阻断，用户没选分类也能保存（`categoryId` 写 null）。
   与「金额才是记账的主内容」一致，也避免把用户卡在无分类又无处可点。

### 未纳入本次迭代

- **deep link 全屏入口**（`app.dart` → `AppLinkAction.newTransaction`）仍是「全屏分类网格 +
  自动叠加金额表单」的旧形态：它要经过「重建可恢复」链路（`_drainPendingDeepLink`），
  改动面与回归风险高于收益。FAB 与 deep link 的形态差异由此保留，待单独评估。
- **日历页「记一笔」**（`calendar_page.dart`）与**账户详情页「快捷转账」**
  （`account_detail_page.dart`）仍是全屏 `TransactionEditorPage`（旧形态）。

### 2026-10-01 第二批：编辑交易统一到新形态

`transaction_edit_utils.editTransaction`（明细页入口）与 `ai_chat_page`（AI 对话页点交易卡片）
的编辑入口改为 `showTransactionFormBottomSheet(quickMode: true)`，即**恒走「金额表单优先」
形态、不受「快捷记账模式」设置开关控制** —— 开关只决定「记一笔」的进入方式；编辑的第一屏
就该是这笔交易的表单。`_isQuickEntryMode` 相应放宽（去掉 `initialKind != 'transfer'` 条件），
编辑转账也在新形态抽屉的转账分支里渲染（高度同样被锁定）。

原分类已被删除时（`initialCategoryId` 解析失败）不再像旧路径那样停在网格，
而是出表单 + 「选择分类」占位。

**仍走旧/全屏形态的入口清单（待逐一评估）：**

| 入口 | 位置 | 现状 |
|---|---|---|
| deep link `piggycount://new?...`（小组件分类格 / 快捷方式 / 浏览器 URL） | `app.dart` `_openDeepLink` | 全屏网格 + 自动叠加金额表单（重建恢复链路敏感，改动需单独回归） |
| 日历页「记一笔」 | `calendar_page.dart` `_addTransactionForSelectedDate` | 全屏 `TransactionEditorPage(quickAdd: true)`，无记忆分类 → 停在分类网格 |
| AI 对话页「记一笔」类入口之外的新建 | `ai_chat_page.dart` | 本次仅统一了它的**编辑**入口 |
| 账户详情页「快捷转账」 | `account_detail_page.dart` `_quickTransfer` | 全屏转账表单（无分类语义，形态差异影响最小） |

### 落点

| 文件 | 变更 |
|---|---|
| `lib/widgets/biz/amount_editor_sheet.dart` | `_category` 内态 + 占位态 + `didUpdateWidget` 补异步初值；`onPickCategory` 新签名；`AmountEditorResult.category` |
| `lib/widgets/category/category_picker_sheet.dart`（新增） | `showCategoryPickerSheet`：分类选择子界面（独立底部抽屉，不共享下层控制器） |
| `lib/pages/transaction/transaction_editor_page.dart` | `_isQuickEntryMode` / `_buildQuickEntrySheet` / `_buildQuickAmountSheet` / `_resolveQuickInitials`；提交抽成 `_persistTransaction` |
| `test/widgets/quick_entry_mode_test.dart` | 分类位占位 / 就地换分类 / 抽屉形态三条落点断言 |

