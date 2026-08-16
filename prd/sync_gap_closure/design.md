# 快照同步缺口修复设计（sync_gap_closure）

## 需求理解

将 WebDAV 快照链路（Path A）的 payload 从 v7 升级到 v8，补齐 budgets、recurring_transactions、全量分类/标签、手动汇率覆盖、月起始日收敛五个缺口，使纯快照用户换设备不丢数据。存储层（`provider.storage` + 序列化器）已解耦，iCloud/S3/Supabase Storage 接入时直接复用 v8 格式，本次改动不涉及存储后端。

## 关键技术决策

1. **payload v8 一次性扩容，而非分版本渐进**：五个缺口都改同一个快照文件，逐项升版本会造成 7→8→9→10 多次指纹漂移。一次升到 v8，漂移只发生一次（升级后首启两端判 different → 做一次全量上传即收敛，与 account_sync_fix 的指纹漂移处理方式一致）。新顶层结构：

   ```json
   {
     "version": 8,
     "accounts": [...],            // 不变（v7 已全量）
     "categories": [...],          // 全量 + 新增 syncId 字段
     "tags": [...],                // 全量（原先只有被引用的）
     "budgets": [                  // 新增：syncId/type/categoryName/amount/period/startDay/enabled
       { "syncId": "uuid", "type": "total", "amount": 3000,
         "period": "monthly", "startDay": 1, "enabled": true }
     ],
     "recurring": [                // 新增：分类/账户按 name+syncId 导出
       { "syncId": "uuid", "type": "expense", "amount": 50,
         "categoryName": "餐饮", "accountName": "支付宝",
         "frequency": "monthly", "dayOfMonth": 1,
         "startDate": "...", "endDate": null,
         "lastGeneratedDate": "...", "enabled": true }
     ],
     "exchangeRateOverrides": [    // 新增：user-global，随快照冗余携带
       { "baseCurrency": "USD", "quoteCurrency": "CNY", "rate": "7.20" }
     ],
     "items": [ { ..., "recurringSyncId": "uuid" } ]
   }
   ```

2. **recurring 的 `syncId` 与 `lastGeneratedDate` 分离处理**（本设计最关键的决策）：
   - 身份靠 `syncId`（v33 迁移加列，老行回填 UUID，对齐 budgets v22 的做法）；
   - `lastGeneratedDate` 是「本机生成进度」而非数据本体，两端天然不同。导出携带、导入取 `max(local, cloud)`（防恢复旧快照后生成器重放整段历史交易）；**指纹计算时将该字段规范化排除**——否则两端生成进度不同 → 指纹永久不同 → 每次启动误弹「云端有更新」，重蹈 account_dedup 排查时 5700/8350 行币种字段不收敛的覆辙（transactions_json.dart:171 已有同类注释）。
   - 双机同步前各自生成的交易仍可能重复（快照最终一致的固有限制）：生成器已有按 lastGeneratedDate 的防重，合并 max 后不会重放；极端并发重复靠既有交易 syncId 去重兜底，不引入新机制。

3. **导入合并统一为三级匹配 upsert-only**（不删除本地多余项）：
   - budgets：syncId 命中 → 更新；否则 type+categoryName+period 业务键命中 → 更新并回填 syncId；否则新建；
   - recurring：syncId 命中 → 更新（lastGeneratedDate 取 max）；否则 note+frequency+amount+dayOfMonth 组合键兜底 → 回填 syncId；否则新建。引用的 category/account 按 name 重建 int 外键，找不到置 null 并记 warning（与交易缺分类的既有处理一致）；
   - exchangeRateOverrides：按 (base, quote) 唯一键 upsert，syncId 回填；
   - categories：`ImportCategory` 补 syncId 字段，去重从「name+kind」升级为「syncId 优先 → name+kind 兜底 + 回填」，对齐标签/账户策略；
   - transactions：导入时按 item.recurringSyncId 反查已导入的 recurring 映射，回填 `recurringId`。

4. **monthStartDay 收敛放在导入服务收尾**：`importTransactionsJson` 完成后，若 payload 携带 ledgerId 且本地存在同 id（或同 syncId）账本，则以快照为准 upsert name/currency/monthStartDay。Cloud 用户的 `syncLedgersFromServer` 收敛不受影响（同值写入幂等）。

5. **指纹算法同步升版**（`sync_fingerprint.dart`）：新增数组纳入计算（budgets/recurring/汇率覆盖按稳定键排序后序列化）；recurring 的 `lastGeneratedDate` 替换为常量再哈希。老快照（v7，无新数组）与新导出必然不同 → 升级后首个同步周期两端显示 different 属预期，做一次全量上传即收敛。

## 实现步骤（≤5）

1. **DB 迁移 v33**（`lib/data/db.dart`）：`recurring_transactions` 加 `sync_id` TEXT 列；启动时为空值老行回填 UUID（参照 budgets v22 回填逻辑）；`flutter drift` 重新生成 `db.g.dart`。
2. **导出 v8**（`lib/cloud/transactions_json.dart`）：categories/tags 改全量查询；categories 补 syncId；新增 budgets/recurring/exchangeRateOverrides 数组（均稳定排序）；items 补 `recurringSyncId`；version → 8。
3. **导入与合并**（`lib/services/data_import_service.dart` + `transactions_json.dart` 的 parse）：`ImportData` 扩展 budgets/recurring/rateOverrides/categorySyncId/recurringSyncId；实现第 3、4 条决策的合并逻辑；收尾回写 ledger 元数据。
4. **指纹升版**（`lib/cloud/sync_fingerprint.dart`）：纳入新数组 + lastGeneratedDate 规范化；更新/新增单测：同数据双端导出指纹一致、lastGeneratedDate 差异不改变指纹、v7 快照解析不崩、v8 往返（导出→导入→再导出）幂等。
5. **验证**：`flutter analyze` 无新增告警；两台 dev（127.0.0.1:16416 / 16384）实测——dev2 建预算/周期规则/未引用分类/手动汇率后全部上传，dev1 全部恢复，核对五类数据集合按 syncId 对齐；恢复后再上传，确认指纹收敛（inSync）。

## 边界条件与风险

- **一次性指纹漂移**：升级后所有设备与云端旧快照判 different，弹一次「云端有更新/本地较新」。用户做一次全量上传后收敛；需在发布说明标注。**不可回避**（格式变更是全量的）。
- **旧版本读 v8**：`parseJsonToImportData` 用 `jsonDecode` + 按需取 key，未知数组天然忽略，v7 客户端读 v8 快照不报错（但看不到 budgets/recurring）。
- **新版本读 v7**：新数组为空列表 → 导入跳过、不删本地数据（upsert-only 语义保证）。
- **recurring 引用失效**：分类/账户改名后跨设备按 name 匹配失败 → 该规则分类/账户置 null + warning 日志，不阻断整体导入（与交易缺分类同策略）。
- **双机并发生成重复**：同步窗口内两端各自生成的交易会重复且 syncId 不同，需人工去重；频率低（要求两端同时在线且都过了生成时点），接受为快照同步固有限制。
- **budgets upsert-only 不删本地**：本地多余的预算项不会被云端快照删除（与交易 insert-dedup 同语义），避免旧快照误删新数据；删除预算的跨设备传播留待 Cloud 链路或后续 tombstone 机制。
- **发布顺序**：迁移 v33 不可逆（加列+回填），确保发版前备份；回滚版本读到多出来的 sync_id 列不报错（Drift 按列名映射，多余列忽略）。
