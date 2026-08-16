# 快照同步缺口修复需求（sync_gap_closure）

## 需求理解

用户要求盘点项目中「哪些表没同步、问题是什么、能否用 Path A（文件/快照式：iCloud / WebDAV / S3 / Supabase Storage）补齐」，并确认对全部缺口出 PRD。核心诉求：让 WebDAV 快照链路（Path A）的数据覆盖面对齐 PiggyCount Cloud 链路，消除换设备时的静默数据丢失。

## 盘点结论（2026-08-15，代码级审计）

两条链路现状：

| 链路 | 机制 | 覆盖实体 |
|---|---|---|
| PiggyCount Cloud（SyncEngine） | 实体级增量 + realtime | transaction、account、category、tag、ledger、budget、attachment（含二进制）、exchange_rate_override、transaction_tag_overrides |
| 快照链路（Path A，payload v7） | 每账本一个 `ledger_<id>.json` 全量快照 | transaction、account（全量）、category（仅被引用）、tag（仅被引用）、transaction_tags、账本元数据、附件元数据 |

缺口清单（本期范围）：

| # | 缺口 | 严重度 | 现状代码位置 |
|---|---|---|---|
| G1 | `budgets` 完全不在快照：WebDAV 用户换设备预算全丢（实测 dev2 45 条 vs dev1 0 条） | 高 | `exportTransactionsJson` payload 无 budgets 数组 |
| G2 | `recurring_transactions` 双链路都不同步，且表无 `syncId` 列；`transactions.recurringId` 也不导出，换设备后周期规则丢失、已生成交易与模板断链 | 高 | `db.dart` 表定义 + `transactions_json.dart` items 无 recurringId |
| G3 | 分类/标签仅导出「被交易引用的」：未被引用的自定义分类、删完交易的标签不上云（与已修复的 accounts G1 同类缺陷） | 中 | `transactions_json.dart` usedCatIds / allUsedTags 收集逻辑 |
| G4 | `exchange_rate_overrides`（手动汇率）不进快照：WebDAV 用户换设备后手动汇率丢失，多币种折算回退到自动汇率 | 中 | payload 无该数组 |
| G5 | 已有账本「下载恢复」时刻意不回写 `monthStartDay`（注释称由 Cloud 引擎收敛），纯 WebDAV 用户改月起始日后另一台设备不收敛 | 低 | `parseJsonToImportData` 刻意不读该字段 |

不在本期范围（已确认为设计决策或遗留）：

- `exchange_rates` 自动汇率缓存：可随时整表重建，设计上不同步（README D2）。
- 附件**二进制**文件：快照仅传元数据，物理文件仍走 Cloud 链路（cloudFileId）。Path A 传大文件的加密/冲突/进度管理成本高，后续单独立项。
- AI 对话（conversations/messages）：隐私 + 体积，纯本地，产品决策维持。
- Cloud SyncEngine 侧补 `recurring` 实体：需服务端 entity_type 白名单变更，另开需求。
- 共享账本镜像表（ledger_members / shared_ledger_*）：服务端权威，不进快照。

## 需求范围

### R1 预算进快照（G1）
- 快照 payload version 7 → 8，新增顶层 `budgets` 数组（含 syncId、type、categoryName、amount、period、startDay、enabled）。
- 导入按 syncId upsert；无 syncId 的老数据按 type+categoryName+period 业务键兜底匹配。
- 合并语义为 upsert-only（不删除本地多余项），与交易恢复的 insert-dedup 语义一致，避免误删。

### R2 周期交易进快照（G2）
- `recurring_transactions` 加 `syncId` 列（DB 迁移 v33，老行回填 UUID）。
- 快照新增 `recurring` 数组；分类/账户引用按 name（+账户 syncId）导出，导入时重建 int 外键。
- 交易 items 补 `recurringSyncId`，恢复后重建 `transactions.recurringId` 关联。
- `lastGeneratedDate` 参与 export/import，导入取 max（防旧进度重放生成）；**不参与指纹**（防两端生成进度不同导致永久 different）。

### R3 分类/标签全量导出（G3）
- 分类、标签改为全量导出（对齐账户 G1 修法）。
- 分类补 `syncId` 传输（表已有列，快照此前未导出），导入去重对齐标签既有「syncId 优先 → name 兜底 + 回填」策略。

### R4 手动汇率进快照（G4）
- 新增 `exchangeRateOverrides` 数组，随每个账本快照冗余携带（行数极少，同账户策略）。
- 导入按 (baseCurrency, quoteCurrency) 业务键 upsert。

### R5 月起始日收敛（G5）
- 「下载恢复到已有账本」路径在导入后以云端快照为准回写 ledger 元数据（name/currency/monthStartDay）。
- `importRemoteLedger`（新账本导入）已有该逻辑，无需改动。

## 验收标准

- dev2「全部上传」→ dev1「全部恢复」后：预算条数与金额一致；周期规则集合按 syncId 对齐且 `lastGeneratedDate` 不回退；未被交易引用的分类/标签出现；手动汇率生效。
- v8 快照被旧版本 App（读 v7）消费不报错（未知字段忽略）；新版读 v7 旧快照（无数组）不误删本地数据。
- 同一数据在两台设备各自导出，指纹一致（含 budgets/recurring/汇率覆盖；`lastGeneratedDate` 差异不影响指纹）。
- `flutter analyze` 无新增告警；相关单测（导出/导入/指纹）通过。
