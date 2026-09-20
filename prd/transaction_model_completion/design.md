# 交易建模补全（F1）— 设计文档

批次日志（file:line 证据、门禁、事故记录）在 `docs/optimization-plan-2026-09-19.md` §13 的
「F1-a」与「F1-b → 移交」两节。本文件只留设计决策、代价与接手清单。

## 一、F1-a 的核心决策：归档表，不是 `deleted_at` 列

方案原文写的是"`transactions` 增 `deleted_at`（nullable）+ 所有读路径补
`deleted_at IS NULL`"。读路径清点后改判。

**为什么不照原文做**：transactions 的读约 75 处、其中约 50 处是**手写 SQL 字符串**
（`SUM(CASE type …)`、`date(happened_at,'unixepoch','localtime')` 这类，见
`local_account_repository.dart:287-312`、`local_statistics_repository.dart:210,253,330`）。
漏一条 = "已删的交易仍计入余额"，是静默的账目错误，**编译器完全管不住**。

**改成什么**：软删 = 整行搬进 `deleted_transactions`（PK 仍是原 `tx_id`，`payload` 存整行 JSON）。
于是余额 / 统计 / 预算 / 附件 GC / 首页列表**自动正确**，因为它们读的是 `transactions`，
而那行真的不在了。用 correct-by-construction 换掉 50 处人工谓词收口。

代价（换来什么、丢什么），三条都过了一遍代码：

| 代价 | 实况 |
|---|---|
| 回收站**只在本机** | 归档行不进快照（`transactions_json` 只导 `transactions`）→ 不上云、不进备份。对端感知这笔删除走的仍是原本那条路（本地有/云端无的 diff 项，按 SYNC-05 默认不勾选），与今天的硬删除语义一致，没有变得更差 |
| 恢复要能"原地复位" | `transaction_tags` / `transaction_attachments` / `transaction_tag_overrides` 三类辅助行**刻意不删**，所以恢复不需重建它们，附件文件也不会被 30 天孤儿 GC 吃掉（GC 以 `transaction_attachments` 全表行判存活，不按账本 join） |
| 与"清空账本"的交叉 | 收集待删文件用的 `getAttachmentFileNamesByLedger` 是 INNER JOIN `transactions` → 归档条目的文件**不在**那份清单里，既不会被误删、也不会被即时回收；`purgeDeletedTransactions*` 走自己的引用计数删文件。净效果：只在回收站里留着的文件由 30 天 GC 兜底，无泄漏 |

顺带证伪一个担心：软删时辅助行还在，若 SQLite 外键被打开就会 `FOREIGN KEY constraint failed`。
全仓 `grep foreign_keys` 零命中 + 测试绿 → 本库连接未开 FK，搬行安全。

## 二、撤销体验：页面，而不是 Snackbar Undo

方案要求"软删 + Snackbar Undo"。实测本 app 的通知原语 `lib/widgets/ui/toast.dart:26` 是挂在
rootOverlay 上的 `IgnorePointer` 覆盖层，**没有 action 位**；全仓 `SnackBarAction` 0 处。
删除入口有 4 个，给其中 1 个单独配撤销反而更不一致 → 改为"4 个入口统一由回收站页面兜底 +
删除后 Toast 明示'已移入回收站'"。

add when：真要原地撤销，先给 Toast 加 action 或换 SnackBar —— 那是全局组件改造，不该夹在功能批里。

## 三、恢复遇 id 被占用 → 拒绝，不换 id

标签/附件是按原 id 挂着的，换个 id 落回去等于把它们丢在原地。底层直接拒绝，页面如实告知。
宁可不恢复，也不要恢复出一笔"没有标签没有附件"的假原件。

## 四、方案里这条前置依赖被证伪：CT-1

方案写"前置依赖（必须先修）：CT-1 ChangeTracker 未注入导致 `local_changes` 全空转……
变更日志不可靠时引入软删除，会让同步把删除'复活'"。核实结果：**不必修，且不成立**。

- `database_providers.dart:24` 起 ChangeTracker 已随云端协同下线**不再构造**，
  `local_changes` 只有 `orphan_seeder.dart:223`（debug 塞数据）会写；
- 唯一读者 `transactions_sync_manager.dart:892-921` 的 `_localChangeEvidence` 在冷启动下给
  `trusted:false` → `_detectUploadConflict` 返回 `'unknown'` → 结果是**多弹一次合并确认**
  （fail-safe），不是静默覆盖；
- 更直接：归档表设计**根本不写 tombstone**，被引用的那条复活路径不存在。

## 五、F1-b（退款 / 报销）移交下一轮 — 接手清单

方案给 F1-b 的定义是 `transactions` 增 `refund_of_id`（自引用）+ `reimburse_status`
（`none/pending/reimbursed`）。**这两列必须进快照才能在多设备下存活**，改动面：

1. `lib/cloud/transactions_json.dart` 导出 + 导入；
2. `lib/cloud/sync_fingerprint.dart` 的 `contentFingerprintFromMap` **字段白名单**
   （不加进去 = 该字段对端不可见、下次全量 pull 静默丢）；
3. `sync_diff_service.dart` 比较逻辑；
4. **首次上线必然触发一轮 outOfSync 升级**（白名单加字段的既有先例：M2 / TSM-P3）。

按本轮硬约束——"不新增依赖、不改协议/容器格式来解决内存问题；**触碰线上格式一律判为
独立立项**"——它不属于可以顺手夹带的批次。

接手时先定的两件事：

- **口径先写死**：退款应回补预算（Firefly #7697）。动列之前必须在本文件与统计侧确定义，
  并配一致性测试。可复用的现成件是 `excludeFromStats`
  （`local_account_repository.dart:476,565,572,578` 的余额 SQL 已在用它），
  这是 F1-b 唯一不需要新协议的部分。
- **别把 `adjustment` 当冲正**：现状 `type == 'adjustment'` 是**账户余额调整**
  （`local_account_repository.dart:292` 计入余额），不是"冲正某笔交易"，没有链接字段。

## 六、明确不做

- **一键清空回收站 / 30 天 TTL 自动清理**：回收站占的只是被删交易的元数据行（约 1KB JSON/行），
  没有容量压力；自动删除用户数据是比不删更糟的默认。
  add when：用户报"回收站条目多到翻不动"再加批量操作。
