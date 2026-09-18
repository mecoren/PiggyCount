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
- **失效锚点**：唯一写入点 `transaction_editor_page.dart:558-563` 一带（现有 `countsForLedgerProvider`
  `invalidate` + `statsRefreshProvider` / `budgetRefreshProvider` 递增处）追加一句
  `ref.invalidate(quickEntryCategoryProvider)`。与既有刷新点同址，避免「刷新漏一处导致记忆陈旧」。
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
