# 云端账本发现设计文档

> 版本：v1.0  日期：2026-08-14
> 关联需求：`/prd/remote_ledger_discovery/requirements.md`

---

## 1. 需求理解

设备 A 在路径 A（S3/WebDAV/Supabase/iCloud）上新建账本并上传后，云端多出 `ledger_N.json`，但设备 B 的启动检查只遍历本地账本，永远看不到这个文件。需要在启动检查中增加"云端文件发现"环节：列出云端 `ledger_*.json` → 找出本机没有的 → 弹窗确认 → 下载并创建本地账本。

## 2. 关键技术决策

### D1：发现机制用 `storage.list()` 而非维护云端索引文件
- 四个路径 A 后端的 `CloudStorageService.list()` 均已实现（S3 listObjects / WebDAV PROPFIND / Supabase list / iCloud listFiles），且内部已处理各自的路径前缀
- 维护索引文件需要处理"索引与数据文件不一致"的额外一致性复杂度，收益低
- 文件名 `ledger_N.json` 中的 N 正是同步路径的 key，天然可解析

### D2：导入时**保留远端 id 作为本地账本 id**（关键决策）
- 路径 A 的同步 key 就是本地 id（`_pathForLedger(ledgerId)`）；若导入时分配新本地 id，该账本的后续上传/下载将永远对不上云端文件
- 保留 id=N 后：导入完成 → 本地指纹==云端指纹 → 后续启动检查自然 inSync，零额外处理
- SQLite 显式插入 autoIncrement 列合法，且 sqlite_sequence 自动推进到 max(id)，不影响后续本地新建
- `syncId` 写 `N.toString()`：与 v21 迁移"旧数据 id 回填 syncId"语义一致（payload 不携带创建侧 UUID，无法恢复原值）

### D3：发现流程复用 `StartupSyncChecker` + overlay，不新建页面
- 启动检查已有配置校验（仅路径 A）、overlay 进度 UI、异常兜底
- 确认弹窗走 `AppDialog.confirm`（与现有 salt 恢复/冲突确认一致的模式），进度复用 `ApplyingState`

### D4：payload 缓存避免二次下载
- `discoverRemoteLedgers()` 下载文件提取元信息（名称/币种/起始日/条数）时，把解密后的 JSON 缓存到 manager 的 `Map<int, String>`
- 确认导入时 `importRemoteLedger()` 直接用缓存，未命中才重新下载

### D5：账本元信息从导出 payload 直接读取
- `parseJsonToImportData` 刻意丢弃 `monthStartDay`（恢复路径由 PiggyCount Cloud 收敛），路径 A 需要自己从原始 JSON 读 `ledgerName`/`currency`/`monthStartDay`/`count`

## 3. 实现步骤

1. **`TransactionsSyncManager`**（lib/cloud/transactions_sync_manager.dart）
   - 新增 `RemoteLedgerMeta` 数据类（id/name/currency/monthStartDay/txCount）
   - 新增 `discoverRemoteLedgers()`：`_provider.storage.list(path: '')` → 正则筛 `ledger_(\d+).json` → 排除本地已有 id → 逐个下载+`_decryptIfNeeded` → 解析元信息并缓存 payload → 返回 meta 列表（单个失败跳过并记日志）
   - 新增 `importRemoteLedger(RemoteLedgerMeta)`：事务内【再查 id 占用 → 显式 id 插入 ledger 行 → `importTransactionsJson(recordChanges: false)`】→ 清缓存 → 返回导入条数
2. **`StartupSyncCheckerDeps` + `WidgetRefDeps`**（lib/cloud/startup_sync_checker.dart）
   - 接口新增：`discoverRemoteLedgers()`、`importRemoteLedger(meta)`、`showNewLedgersConfirmDialog(metas)`、`getNewLedgersDownloadedMessage(count)`
   - `WidgetRefDeps` 实现转发到 syncManager；确认弹窗用 `AppDialog.confirm`（l10n 文案）
3. **`StartupSyncChecker._runInternal`**（lib/cloud/startup_sync_checker.dart）
   - 在步骤 3（取本地账本）与步骤 4（逐账本检查）之间插入发现环节；`ledgers.isEmpty` 的提前返回移到发现之后
   - 发现→弹窗→确认则 `startApplying` 逐个导入（单账本超时 `_applyTimeout` 守卫）→ `done(已下载 N 个新账本)` → 重新拉取本地账本列表继续原流程；跳过则直接继续原流程
   - 整个发现环节 try/catch 降级：list 失败记日志跳过
4. **l10n**：4 语言 arb 新增 `startupSyncNewLedgersTitle/Message/Ok/Cancel/Done` → `flutter gen-l10n`
5. **测试与验证**：更新 `test/cloud/startup_sync_checker_test.dart` 的 FakeDeps 补新方法；跑 `flutter analyze` + 相关单测

## 4. 预期边界与风险

- **撞号语义不解决**：本地已有同 id 不同账本时该文件被当作"已有"，属路径 A 既有设计（文件名=本地 id），本设计显式不改
- **弹窗在 overlay 之上**：确认弹窗用 `showDialog`，需先 `controller.dismiss()` + `await Future.delayed(Duration.zero)` 让遮罩消失（沿用 confirmEach 模式的既有做法），选择后 `reattach()` 恢复
- **空 count 账本**：正常创建（本地无对应账本，无"空覆盖"风险，不触发 P1-1 拦截）
- **`_statusCache`**：导入后无需失效（新 id 从未缓存过）；`runAfterDownload()` 刷新 UI providers 让账本列表立即可见
