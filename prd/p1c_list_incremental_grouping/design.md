# P1-C 列表增量分组 + provider 收敛 — 设计文档

## 一、需求理解

交易列表（首页明细 tab）在万级账本下每次数据变化全量重算日分组，改为「两遍 O(n) 轻量
diff + 仅脏日重建」；首页 AI 开关的顶层 watch 收敛到头部 Consumer。正确性底线：增量
结果与全量重算在任何场景下逐项等价。

## 二、关键技术决策

### 决策 1：抽取纯类 `TransactionDayGrouper`（新文件 `lib/widgets/biz/transaction_day_grouper.dart`）

- 持久状态：`_idDayKey`（tx id → 日 key）、`_idItem`（tx id → 上次条目）、
  `dayGroups`（日 key → 条目列表，保持输入顺序）、`sortedDayKeys`（日 key 降序）。
- 纯逻辑无 BuildContext/widget 依赖 → diff 算法可直接单元测试（核心风险点），
  不必靠 pump widget 间接验证。
- State 持有一个实例，扁平项从 grouper 结果重建。

### 决策 2：两遍 diff 算法（避免脏集顺序问题）

第一遍判定脏日集合时无法预知后续条目会不会弄脏早前判断过的日（例：列表中第 5 项
所在日后被第 9000 项的新增弄脏），因此拆两遍：

- **Pass 1（O(n)，零字符串格式化）**：对每条新条目查 `_idDayKey`/`_idItem`：
  - id 未见 → 新交易，格式化日 key，标记脏；
  - 条目值相等（见决策 3）→ 复用旧 key，不标记；
  - 值不等 → 格式化新 key；新 key ≠ 旧 key 时新旧两日都标记脏，否则单日标记脏。
  同时逆向检查：旧 id 集中不在新列表的 → 其旧日标记脏（删除场景）。
- **Pass 2（O(n)，仅脏日收集）**：按 Pass 1 得到的 id→新日 key，收集脏日的全部新条目
  并按新列表顺序重建该日分组；空日从 `dayGroups`/`sortedDayKeys` 移除；新日按二分插入
  （'yyyy-MM-dd' 字符串字典序 == 时间序）。
- 增量维护两张 id 索引（新增/变更写、消失删）。
- **性能特征**：单笔编辑 ≈ O(n) 整数哈希查找 + 记录值比较 + 1~2 个日重建 + O(days)
  扁平项重排；无实质变化的 emit ≈ O(n) 比较 + 0 重建。原全量路径为
  DateFormat × n + O(d log d) 排序 + 全量扁平项重建。

### 决策 3：值相等依赖 Drift 生成的 `==`（已核实）

`db.g.dart` 的 `Transaction`（2739 行）及 Category/Account 均生成全字段值相等的
`==`。条目 record（`({Transaction t, Category? category, Account? account,
Account? toAccount})`）的 `==` 为字段结构相等 → 「账户/分类改名导致的 JOIN 重发」
能正确判为变更并重建对应日；「Drift 重复 emit 等值对象」正确判为无变化。
`updatedAt` 参与 `==`：仅触碰 updatedAt 的保存会保守地重建该日——正确且开销可忽略。

### 决策 4：日 key 手工构建，格式与 `DateFormat('yyyy-MM-dd')` 严格一致

`'${y.padLeft(4,'0')}-${m.padLeft(2,'0')}-${d.padLeft(2,'0')}'`。下游消费
（`jumpToMonth` 的 split('-') 解析、VisibilityDetector key、DaySectionHeader）对格式
敏感，全量路径同步换用同一实现，保证两路径产出字节级一致；同时消除全量路径的
ICU 格式化开销。

### 决策 5：`_buildFlatItems` 双路径结构

- grouped 模式（`wrapInOuterCard=true`，唯一在用）：grouper 已 seed → 先试
  `applyDiff()`，返回 false 则直接跳过（扁平项不动）；有变更 → 从
  `sortedDayKeys`+`dayGroups` O(days) 重建扁平项、`_dateIndexMap`、累计
  flatDayStart、首/末日标记。首次构建走 `fullRebuild()` 并 seed。
- flat 模式（无调用方）：原全量代码保留不动，不 seed grouper。
- build() 现有指纹门（identical/length/firstId/lastId）不变，仍是第一道短路；
  增量 diff 是第二道。

### 决策 6：R2 —— aiEnabled 收敛进头部已有 Consumer

home_page 顶层 `ref.watch(aiAssistantEnabledProvider)` 移入头部
`Consumer`（现 watch `headerStyleProvider` 处），line 828 的 AI 入口按钮在同一
子树内。其余顶层 watch 经调研各自合理（账本切换需整页重建、repo 稳定、
cachedFullData 仅启动变化），不做额外改动。

## 三、实现步骤

1. 新建 `transaction_day_grouper.dart`（dayKey 手工构建、fullRebuild、applyDiff），
   先写 RED 单测（AC-R1 表 9 个场景）再实现。
2. 重构 `transaction_list.dart` 的 `_buildFlatItems`：grouped 模式接入 grouper
   （决策 5 双路径），日合计复用既有口径（转账不计入）。
3. home_page `aiAssistantEnabledProvider` 收敛到头部 Consumer。
4. `flutter analyze` + 全量 `flutter test`。
5. 手动回归：增删改交易、跨日改日期、月份跳转、下拉删除、启动预载→stream 切换。

## 四、边界条件与风险

| 风险 | 缓解 |
|------|------|
| 增量与全量结果不一致（核心风险） | 单测逐场景对拍两算法输出；等价性是硬验收线 |
| dayKey 格式偏差破坏 jumpToMonth/可见性检测 | 手工构建与 DateFormat 产出一致性单测；两路径共用同一实现 |
| 云端合并 emit 同长度但 id 被替换的列表 | diff 按值比较处理 id 替换（等值→跳过；不等→脏日重建），原指纹首尾 id 检查仍作第一道防线 |
| 内存增量 | `_idDayKey`/`_idItem` 两张 O(n) 引用索引（万级 ≈ 2 万条目，不复制数据） |
| 条目在日内的顺序语义 | 脏日从新列表顺序重建，与全量重算的 putIfAbsent 顺序语义一致 |
| record 值相等误判 | 已核实 Drift 全字段 `==`；`identical` 快路径先行 |
