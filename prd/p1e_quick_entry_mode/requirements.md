# P1-E 快捷记账模式 — 需求文档

> 来源：优化评估报告（`docs/optimization-assessment-report/optimization-assessment-report.html`）
> 建议 9「记账效率：快捷记账模式」（影响 中 / 工作量 中 / P1 / 1–2 月）。
>
> 报告原文：
> - 原因：「记一笔」仍是核心高频操作，当前需多步选择；竞品普遍提供 1–2 步路径。
> - 下一步：记忆上次分类 + 金额优先的极简表单；入口复用现有 home_widget/deep link 范式。
> - 证据行：`transaction_editor_page.dart:309-321`。

## 一、背景

### 1.1 当前「记一笔」实际路径（已逐行核对）

| 步 | 位置 | 发生什么 |
|---|---|---|
| 1 | `app.dart:869-875` | 点底部中央 FAB → `showTransactionFormBottomSheet(context, initialKind: 'expense')`（该函数的 `quickAdd` 默认 `true`，见 `transaction_editor_page.dart:30`） |
| 2 | `transaction_editor_page.dart:280-347` | 抽屉一：`ExpandableBottomSheet`，`initialChildSize: 0.7`，标题「记一笔」，底部槽是「支出/收入/转账」分段控件，正文是 `CategorySelector` 分类网格 |
| 3 | 用户在网格里**找到**目标分类并点击 → `_onCategorySelected`（`:381`） | 抽屉二：`AmountEditorSheet` 叠在抽屉一之上（`:401`），含金额键盘、备注、账户、标签、附件、币种 |
| 4 | 输入金额 → 保存（`:426-578`） | 写库后两层抽屉依次 pop |

即 **2 次点击 + 输金额**。单看点击次数已落在报告所说的「1–2 步」区间边缘，真正的摩擦在**第 3 步要「找」分类**：

### 1.2 三条勘察结论（本需求的存在理由）

**结论 A：分类列表是固定顺序，不随使用变化。**
`CategorySelector` 走 `repo.getTopLevelCategories(kind)` → `local_category_repository.dart:242-247`
按 `sortOrder` 升序返回，不存在任何分类记忆机制。检索佐证：`lastCategory` / `recentCategor` /
`favoriteCategor` 在 `lib/` 下**零命中**；`last_used` 有 3 处命中，但均为备注/标签查询内部的 SQL
别名（`local_transaction_repository.dart:796-797`、`local_tag_repository.dart:754-759`、
`shared_ledger_picker_filter.dart:181-186`），与分类记忆无关。用户每次记账都要在网格里重新定位
同一个常用分类。

**结论 B：金额表单完全不显示分类。**
`AmountEditorSheet.categoryName` 的字段注释即为「仅用于上层提交，不在 UI 展示」
（`amount_editor_sheet.dart:44`）。**推论：任何「跳过分类网格」的方案都必须先补上分类可见性**，
否则用户看不见这笔钱记到哪个分类去了——这是本需求唯一的硬约束，不是可选项。

**结论 C：报告说的「复用 home_widget/deep link 范式」指的是一条已经跑通的现成路径。**
小组件「快速记账」点某个分类格 → `piggycount://new?type=expense&category=<id>`
→ `app_link_service.dart:326-338` 派发 `AppLinkAction.newTransaction`
→ `app.dart:544-551` 推 `TransactionEditorPage(quickAdd: true, initialCategoryId: ...)`
→ `initState`（`:137-163`）**自动直接落到金额表单**，用户只需输金额 + 保存。

也就是说：**「进入即落在金额表单，分类已预先确定」的能力，代码里已经存在**。
缺的只是一个可信的「预先确定的分类」来源——目前唯一来源是用户在小组件上手动点的那一格。
本需求就是把来源扩展到「上次记这个分类的记忆」。

## 二、需求范围

### R1 上次分类记忆（数据层）

- 新增仓库方法 `getLastUsedCategoryId({required int ledgerId, required String kind})`：
  取该账本 + 该类型下**最近一笔**带分类交易的分类。
- **按 kind 分开记忆**：支出与收入各自独立，互不覆盖。
- **数据来源优先从 `transactions` 聚合派生，不新增表、不新增 SharedPreferences 键。**
  依据：本仓库既有先例 `getNoteHistory`（`local_transaction_repository.dart:769-831`）
  的注释明确写了「备注历史直接基于已保存交易聚合，**避免维护会与同步数据脱节的缓存副本**」。
  派生数据天然随云同步一致，且不会有「分类已删而记忆仍指向它」的悬空指针长期残留。
- 查询需走索引，不做全表扫（详见 `design.md` 决策 1；本表数据量在万级账本下必须可控）。

### R2 金额优先的极简表单

- `AmountEditorSheet` 新增**分类显示位**（补结论 B 的缺口）：在金额表达式上方/同排展示当前
  分类（图标 + 名称），点击可更换分类。
- 该分类位在既有调用路径（编辑交易、小组件带分类）下同样显示，行为一致——不新增「只有快捷模式才看得见分类」的分叉。
- 打开编辑器且 R1 命中时，**直接落在金额表单**，跳过分类网格；用户按需点分类位更换。

### R3 入口

- 底部中央 FAB **点击** → 快捷模式；**长按**的扇形菜单（拍照/相册/语音）保持不变。
- deep link `piggycount://new?type=expense`（**不带** category）→ 走同一快捷模式。
  现状是推全屏 `TransactionEditorPage` 停在分类网格，与 FAB 路径不一致。
- deep link 带 `category=<id>`（小组件分类格）→ 保持现状，本来就已经是「金额优先」。
- **默认账本 / 默认账户沿用现有解析逻辑**（`_getDefaultAccountId`，
  `transaction_editor_page.dart:350-379`，含币种匹配校验与账户隐藏兜底），不另起一套。

### R4 开关与退路

- 新增设置项「快捷记账模式」，默认开启（pref 持久化，范式对齐
  `showTransactionTimeProvider` + `showTransactionTimeInitProvider`，
  `providers/theme_providers.dart:162-170`）。
- 关闭后 FAB 点击回到现有「抽屉一 → 分类网格」流程，其余不受影响。
- 另需一个**通用退路**（不依赖设置）：从快捷表单可一键切到完整流程（换分类即回到网格）。

## 三、验收标准

### AC-R1

| # | 场景 | 预期 |
|---|------|------|
| 1 | 账本有若干笔支出，最近一笔分类为「餐饮」 | `getLastUsedCategoryId(kind:'expense')` 返回「餐饮」的 id |
| 2 | 同一账本最近一笔是收入「工资」 | `kind:'income'` 返回「工资」，`kind:'expense'` 仍返回「餐饮」（互不覆盖） |
| 3 | 空账本 / 全新账本 | 返回 `null`，不抛异常 |
| 4 | 最近若干笔交易的 `category_id` 均为 NULL | 返回 `null`，且不因扫描到 NULL 提前中断（应取最近一笔**非空**分类） |
| 5 | 该分类随后被删除 | 返回已删 id 或 `null`，**调用方必须做存在性校验后才可预填**（见 AC-R2 #4） |
| 6 | 转账交易 | 不参与统计（转账无分类语义） |
| 7 | 单笔新增交易后再次查询 | 立即反映新分类（无缓存陈旧窗口，或缓存被正确失效） |

### AC-R2

| # | 场景 | 预期 |
|---|------|------|
| 1 | 开启快捷模式 + R1 命中 | 点 FAB 后**直接出现金额表单**，中途不出现分类网格 |
| 2 | 金额表单内的分类显示 | 显示 R1 记忆到的分类（图标 + 名称），与提交时写库的 `categoryId` **严格一致** |
| 3 | 点分类位换分类 | 回到分类网格；选中后回到金额表单，且已输入的金额不丢（或明确重置，二者择一写死在设计里） |
| 4 | R1 命中但分类已删除/已隐藏/不属于当前账本（含共享账本 synthetic id） | 静默退回分类网格流程，**不预填、不报错、不白屏** |
| 5 | 首次使用（R1 返回 null） | 退回分类网格流程，不显示空的快捷态 |
| 6 | 提交结果 | 与现有路径写库完全一致：金额/分类/日期/备注/账户/标签/附件/币种折算全字段等价 |
| 7 | 编辑已有交易 | 不受快捷模式影响，仍走现有编辑路径 |

### AC-R3

| # | 场景 | 预期 |
|---|------|------|
| 1 | `piggycount://new?type=expense` | 落在快捷模式（与 FAB 行为一致） |
| 2 | `piggycount://new?type=expense&category=12` | 行为与改动前一致（预填分类 12，直接金额表单） |
| 3 | FAB 长按 | 扇形菜单三项（拍照/相册/语音）行为不变 |
| 4 | 冷启动 deep link | 仍走 `_restoreCurrentLedgerId` + `pendingNewTransaction*` 既有链路，记账落账本正确 |

### AC-R4

| # | 场景 | 预期 |
|---|------|------|
| 1 | 设置项关闭 | FAB 点击回到「抽屉一 → 分类网格」，与改动前逐帧一致 |
| 2 | 设置项持久化 | 重启 App 后仍为关闭状态 |

### AC-通用

- `flutter analyze --fatal-infos` 无新增 issue。
- 全量 `flutter test` 通过（含新增的 R1 单测、R2 widget 测试）。
- 手动回归：支出/收入/转账三条路径、编辑交易、小组件三个入口、冷启动 deep link。

## 四、非目标

- **不做全新的 `QuickEntrySheet` 组件。** `AmountEditorSheet` 已经是「金额优先」的表单
  （金额表达式在最上方），且已含键盘、备注、账户、标签、附件、币种。重写一个「更简」的
  表单会同时带来两条提交路径需要维护的长期成本，收益仅为视觉上少几行。本需求只做
  「补齐分类可见性 + 改变进入时落点」。
- **不做「一键复记上一笔」**（复制上笔全部字段直接落库）。与「记忆分类」相比，它跳过金额输入——
  而金额是每笔必然不同的字段，跳过后用户仍要改，反而多一步。属另一个需求。
- **不动分类网格自身的排序规则**（`sortOrder` 是用户在分类管理页手工排的，改它属于抢用户的控制权）。
- **不引入新的持久化表**（见 R1 的取舍理由）。
- 不改 `app_link_service.dart` 的 URL 解析与 `AppLinkBuilder` API。

## 五、待拍板（实现前需要你确认的 5 点）

> 这 5 点会改变实现范围与用户可感知行为，不宜由我单方面决定。

| # | 决策点 | 选项 | 我的建议 |
|---|--------|------|----------|
| 1 | 记忆来源 | **A. 从 `transactions` 聚合派生**（无新表/新 pref，跨设备天然一致，有 `getNoteHistory` 先例）<br>B. SharedPreferences 存 id（更快，但设备本地、跨设备不一致、易留悬空指针） | **A**。本仓库对「派生数据 vs 缓存副本」已有明确取舍倾向 |
| 2 | 默认路径激进度 | **1. 保守**：仍走网格，仅在网格顶部加一行「最近」置顶<br>**2. 金额优先**（报告原意）：直接进金额表单 + 分类位可改<br>**3. 极简**：独立精简表单，隐藏账户/日期/标签/币种 | **2**。1 没有减少点击步数，3 引入第二条提交路径 |
| 3 | 是否连「上次类型」一起记忆 | 是（FAB 直接出上次是支出还是收入）／否（FAB 恒为支出，不变） | **否，先不做**。类型选错的代价高于分类选错，且分段控件就在手边；可留作后续 |
| 4 | 设置开关 | 加（默认开，可关回旧流程）／不加（直接替换默认交互） | **加**。这是改变默认高频交互的行为变更，应留退路 |
| 5 | 换分类时已输金额 | 保留（回到网格再回来金额还在）／清空 | **保留**。清空金额属惩罚用户点错分类 |

确认后我按 `design.md` 实施；若对第 2 点选保守方案，R2 的改动量会显著缩小（只补分类位 + 网格置顶，不动落点）。
