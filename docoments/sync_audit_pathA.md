# Path A 快照同步（S3/WebDAV/Supabase/iCloud）代码审查报告

> 审查范围：PiggyCount 的快照同步链路（Path A），即 `TransactionsSyncManager` / `transactions_json` / `startup_sync_checker` / `sync_fingerprint` / `sync_diff_service` 以及 provider 包 `flutter_cloud_sync`（S3/WebDAV/Supabase/iCloud 实现）。
> **明确排除**：PiggyCount Cloud 增量同步模块（`lib/cloud/sync/sync_engine*`、`change_tracker`、`entity_serializer`、`sync_coordinator`、`sync_engine_realtime` 等 WS 实时协作链路）。
> 审查方式：只读静态审查，未修改任何代码。

---

## 一、总体结论

Path A 的主干逻辑（指纹规范化、状态机缓存、竞态防护、加密哨兵、空覆盖守卫）做得相当扎实。但存在 **3 个高严重度问题**和若干中/低问题，集中在：

1. 反序列化**缺乏容错**（远端/损坏 JSON 任意字段异常即中断整账本导入）；
2. **恢复语义不一致**（覆盖 vs 合并混用，且"全量覆盖"实际只覆盖交易，不覆盖预算/周期规则/分类）；
3. provider 包层的**安全降级、非幂等重放、缺超时、缺完整性校验**。

---

## 二、高严重度（High）

### H1 — 反序列化硬类型转换，缺容错（数据导入脆弱）
- **位置**：`lib/cloud/transactions_json.dart`
  - `parseJsonToImportData`：`acc['name'] as String`(459)、`cat['kind'] as String`(484)、`r['type'] as String`(521)、`(r['amount'] as num).toDouble()`(522)、`it['type'] as String`(613)、`(it['amount'] as num).toDouble()`(622)、`it['startDate'] as String`(534) 等多处。
- **类型**：健壮性 / 异常处理。
- **潜在影响**：同步来源是远端不可信数据。只要云端快照中任一交易/账户/分类的某字段为 `null` 或类型不符（传输损坏、版本错配、手工编辑），`as` 强转即抛 `CastError`，**整个账本下载导入中断**，用户看到崩溃而非降级。
- **改进建议**：统一改为带默认值的解析，复用 `rate override` 已有的 `num.tryParse` 模式；对 `amount`/`startDate` 等必填字段缺失时**跳过该条记录并记 warning**，而非整账本失败。

### H2 — 恢复语义不一致：覆盖 vs 追加合并混用
- **位置**：
  - `downloadAndRestoreToCurrentLedger`（764-865）先 `_clearLedgerTransactions`(821) 再导入 → **真正覆盖**；且有 P1-1 守卫拒绝"空云端覆盖非空本地"(798-813)。
  - `downloadRemoteLedger`（1464-1614）同名本地账本分支（1494 `reuseExistingByName`）直接 `importTransactionsJson`(1558) **不清空** → 追加合并。
  - `fullRestoreAllRemoteLedgers`（1752-1811）：本地已存在同 id → 走覆盖；云端独有 → 走 `downloadRemoteLedger`（可能触发同名合并，1785-1803）。
- **类型**：数据一致性 / 同步冲突策略。
- **潜在影响**：用户在"恢复/下载"时预期云端为准。但同名本地账本（名称相同、id 不同）场景下，云端交易被**追加**进本地账本，与本地独有交易并存 → 数据重复、统计虚高。两条恢复路径行为不一致，难以预期。
- **改进建议**：统一恢复语义。同名账本也应先清空本地对应账本数据再导入；或在 UI 明确让用户选"替换 / 合并"；并补充单测覆盖"同名不同 id"分支。

### H3 — "全量覆盖"实际只覆盖交易，其余实体合并
- **位置**：`downloadAndRestoreToCurrentLedger`(820-824) 仅 `db.transaction` 内清空 `transactions/tags/attachments`；`importTransactionsJson` 走 `dataImportService.importData` 对 categories/accounts/tags/budgets/recurring/rateOverrides 为 **upsert**（按 syncId/name），**从不删除本地多出的**。
- **类型**：数据一致性 / 同步冲突策略。
- **潜在影响**：云端快照删除了某预算/周期规则/分类，本地恢复后**这些仍保留**（并集而非镜像）。名为"全量覆盖下载"，实为"交易覆盖 + 其余合并"，与用户心智和"全量覆盖"语义不符，易造成脏数据长期存在。
- **改进建议**：覆盖模式下对预算/周期规则/分类也做"云端集合对账"——本地存在、云端缺失且为同步实体的行应删除（注意 user-global 的 accounts/tags 不可删本地独有，需区分 ledger-scoped 与 user-global）。

---

## 三、中严重度（Medium）

### M1 — 云端交易为空时 computeDiff 把所有本地交易标为 deleted
- **位置**：`lib/cloud/sync_diff_service.dart`
  - `computeDiff` 88-92：`cloudTransactions.any((t)=>t.syncId!=null)` 对**空列表**返回 false → 不提前返回 null；随后 180-189 遍历本地把每条标 `deleted`。
- **类型**：同步冲突策略 / 数据破坏性。
- **潜在影响**：当传入空云端列表（如用户选了一个空云端账本做合并预览），`SyncPreview` 含全部本地交易的"删除"项；若经 `applyPreviewChanges` 应用，会**误删全部本地交易**。注：`downloadAndRestoreToCurrentLedger` 有 P1-1 守卫，但手动 diff 合并 UI 仍可达此路径。
- **改进建议**：`computeDiff` 在 `cloudTransactions.isEmpty` 时直接返回 `null`（无法计算 diff），由调用方走全量替换或提示。

### M2 — 导出时分类查询 N+1
- **位置**：`lib/cloud/transactions_json.dart` 112-119：对 `usedCatIds` 中每个分类逐个 `db.select(categories).where(id.equals(cid)).getSingleOrNull()`。
- **类型**：性能。
- **潜在影响**：大账本引用的不同分类数可达数百~上千，产生等量 DB 往返，导出/指纹计算变慢（每次 `getStatus` 都触发）。
- **改进建议**：改为一次 `db.select(categories).where(c.id.isIn(usedCatIds.toList())).get()`，内存建 map。

### M3 — Path A 下载可能污染 local_changes（recordChanges 默认 true）
- **位置**：`lib/cloud/transactions_json.dart` `importTransactionsJson` 默认 `recordChanges: true`(683-698)；`downloadRemoteLedger`(1558)、`importRemoteLedger`(1949)、`downloadAndRestoreToCurrentLedger`(823) 已显式传 `false`（做得对），但 `downloadAndPreview`→`applyPreviewChanges`→`syncDiffService.applySyncChanges` 内调用 `dataImportService.import*` 仍会写 local_changes。
- **类型**：数据一致性 / 同步状态。
- **潜在影响**：从云端拉取的数据若被写入 `local_changes`（标记为"本地待推送变更"），一旦该设备后续启用 PiggyCount Cloud，这些"远端已有"的变更会被当成本地新变更重新推送，导致重复或孤儿变更（此前实测 session 已出现过 dangling upsert）。
- **改进建议**：Path A 合并路径（`applySyncChanges`）对来自云端的实体统一 `recordChanges: false`；明确本地变更水合规则。

### M4 — 跨时区同步时间漂移
- **位置**：`lib/cloud/transactions_json.dart` 导出 `happenedAt.toUtc()`(169)，导入 `DateTime.parse(...).toLocal()`(625)。
- **类型**：数据正确性（时区）。
- **潜在影响**：DB 存朴素本地时间。A 设备(UTC+8)记 08:00 → 导出 00:00Z → B 设备(UTC-5)导入显示 19:00 前一日。同一时刻在双设备显示不同钟点；若 A 再拉回，偏差会"翻倍"。
- **改进建议**：存储与比较均以 UTC 即时为准（保留时区或统一 UTC 比较），展示层再本地化，避免 round-trip 漂移。

---

## 四、Provider 包层问题（flutter_cloud_sync / flutter_cloud_sync_*）

> 由探索代理对 S3/WebDAV/Supabase/iCloud provider 及其 core 层审查得出（已排除 PiggyCount Cloud 后端）。

### P1（高）— 安全存储失败明文降级
- **位置**：`cloud_service_store.dart` 52-68。
- **影响**：`FlutterSecureStorage` 写入失败时，把含 `password/secretKey/anonKey` 的配置以明文 `SharedPreferences` 落盘 → 凭据泄露。
- **建议**：安全存储失败应"失败即停止"，绝不回退明文；或本地对称加密兜底。

### P2（高）— 离线队列对非幂等写操作重放
- **位置**：`database_sync_manager.dart` 370-409、671-704。
- **影响**：`insert/update/delete` 全按 `retryCount` 重放；首插已在服务端成功但响应丢失时重放会**再次插入** → 重复记录（Supabase insert 尤甚）。
- **建议**：insert 类首试失败即置"需人工/冲突处理"，仅对确认瞬断重试；或引入 idempotency key / `on_conflict`。

### P3（高）— WebDAV / iCloud 缺网络超时
- **位置**：`webdav_provider.dart` 82-87（无 connect/send/receive timeout）；`icloud_method_channel.dart` 45-94（`invokeMethod` 无超时）。
- **影响**：服务端无响应时同步永久挂起，UI 卡死。
- **建议**：显式设置连接/读写超时（15-30s）；原生调用加超时。

### P4（中）— 网络异常被吞成"文件不存在"
- **位置**：`webdav_storage_service.dart` 203：`if (_isNotFound(e) || e is CloudStorageException) return null;` 把任意网络错误当 not-found。
- **影响**：网络抖动误判为缺失 → 触发覆盖上传或错误同步方向。Supabase 同处 235 行正确 rethrow，行为不一致。
- **建议**：仅 not-found/认证错误返回 null，网络错误 rethrow。

### P5（中）— 全链路缺完整性校验
- **位置**：`s3_client.dart` 160-216、`supabase_storage_service.dart`、`icloud_storage_service.dart` 79-81。
- **影响**：上传后不校验 ETag/Content-Length；下载直接 `utf8.decode(bodyBytes)` 信任内容 → 静默截断/串包难发现。
- **建议**：put 后比对 ETag；get 后比对 Content-Length/自定义 SHA256 头。

### P6（中）— 上传零重试 + 无分片/断点续传
- **位置**：`s3_client.dart` 124-175。
- **影响**：一次瞬时抖动即失败；大备份文件无断点续传，弱网几乎必败。
- **建议**：上传加客户端版本号/`If-None-Match` 幂等重试；大文件分片 + 失败续传。

### P7（低）— iCloud 空文件与缺失不区分 + list 硬转换
- **位置**：`icloud_storage_service.dart` 79-81（空文件 base64Decode('')→''）、108-109（`as String` 硬转缺字段抛 CastError 丢整个列表）。
- **建议**：区分 `null`(缺失) 与空串(存在)；列表项用 `as String? ?? ''`。

---

## 五、正向（做得好的部分，供对照）

- **指纹规范化**（`sync_fingerprint.dart`）：金额按数值排序(P3-1)、rate TEXT 兼容、transfer 忽略分类、override 纳入指纹、排序键稳定——是收敛"误报云端有更新"的关键保障。
- **状态机**（`getStatus`）：`_statusCache` TTL 防过期"已同步"、ATTACH-2 局部变量防 NPE 竞态、salt 不匹配转哨兵、error 状态不缓存——设计严谨。
- **P1-1 空覆盖守卫**（`downloadAndRestoreToCurrentLedger` 798-813）：拒绝空云端清空非空本地，避免"恢复"变"抹除"。
- **启动检查**（`startup_sync_checker`）：`_statusTimeout/_applyTimeout/_publishTimeout` 三级超时、哨兵递归重激活、失败账本计入而非误报"已最新"——防护周全。
- **附件顺序协议 + 内容寻址 + 信号量限流**（uploadAttachmentObjects / drainAttachmentJobs / `_Semaphore`）：上传先于 JSON、按 sha256 去重、并发 4 限流，避免打满连接。

---

## 六、修复优先级建议

1. **先修 H1（反序列化容错）** 与 **P1/P2/P3（凭据明文、非幂等重放、缺超时）**——均可在异常/恶意/弱网输入下造成数据破坏或崩溃，且修复独立、风险低。
2. **再修 H2/H3（恢复语义）**，避免"全量覆盖"产生重复/残留数据，需配合单测。
3. **M1（空云端 diff 删除）** 与 **M3（local_changes 污染）** 属于"破坏性/污染"类，应在合并路径落地前修。
4. **M2/M4/P4/P5/P6/P7** 为性能/鲁棒性增强，可排入常规迭代。

> 说明：以上结论基于静态审查与必要行号定位。H2/H3 涉及的数据实体对账边界（user-global vs ledger-scoped）建议修复前再确认 `dataImportService` 的具体 upsert/删除实现。
