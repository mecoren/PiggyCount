# BeeCount 启动时云端数据拉取提示需求文档

> 版本：v1.0  日期：2026-07-27
> 关联设计：`/prd/startup_sync_check/design.md`

---

## 1. 背景与目标

### 1.1 背景

BeeCount 当前启动流程中，路径 A（S3 / WebDAV / Supabase / iCloud）的首次同步仅在后台静默执行 `refreshAllLedgersStatus()` 预热状态，**不会主动拉取云端数据并与本地合并**。用户在新设备安装 App、或在多设备间切换后，必须手动进入「云端同步」页面点击下载按钮才能把云端最新数据拉到本地，体验割裂且容易遗忘，导致本地数据与云端长期不一致。

### 1.2 目标

- **主动拉取**：App 冷启动进入主界面后，主动检查云端是否有更新
- **强制提示**：检测到云端有更新时，强制弹出提示框（用户必须主动选择，不能被忽略）
- **预览合并**：使用现有的「同步预览」功能（`showSyncPreviewDialog`）让用户查看具体变更并决定是否应用
- **逐账本确认**：多账本场景下逐个账本弹窗，用户可对每个账本独立决定

### 1.3 非目标

- **不覆盖路径 B（BeeCount Cloud）**：路径 B 保持现有的 `_triggerInitialCloudSync` 自动同步逻辑，不弹任何提示框（其增量同步无 preview 能力）
- **不修改同步预览弹窗 UI**：复用现有 `showSyncPreviewDialog`，不改其接口和视觉
- **不改变加密流程**：与已实现的 E2EE 装饰器解耦，加密透明
- **不实现后台/定时检查**：仅在 App 冷启动时触发一次，不做周期性轮询

## 2. 用户故事

### US-1：启动时检测云端更新

**作为**一个配置了 S3/WebDAV/Supabase/iCloud 同步的 BeeCount 用户，
**我希望** App 启动进入主界面后能自动检查云端是否有更新，
**以便**我不用每次手动进同步页面去拉数据。

**验收标准**：
- App 冷启动进入 `BeeApp` 主界面后触发检查
- 仅当 `activeCloudConfigProvider` 返回的 `cfg.type` 属于路径 A（`s3` / `webdav` / `supabase` / `icloud`）且 `cfg.valid == true` 时执行
- 路径 B（`beecountCloud`）和本地模式（`local`）跳过本功能
- 检查在后台执行，不阻塞首屏渲染

### US-2：强制提示用户是否合并

**作为**一个云端有新数据的用户，
**我希望** App 弹出强制提示框告诉我云端有更新，
**以便**我主动决定是否合并到本地。

**验收标准**：
- 弹窗 `barrierDismissible: false`，用户必须主动点击按钮（点击外部不消失）
- 弹窗文案明确告知是哪个账本、有多少条变更（新增 N / 修改 M / 删除 K）
- 提供「查看详情并应用」和「暂不合并」两个选项
- 用户选择「暂不合并」后该账本本次启动不再弹窗

### US-3：使用同步预览查看并应用变更

**作为**一个确认要合并的用户，
**我希望**能看到具体的变更列表并勾选要应用的项，
**以便**我对合并内容有最终控制权。

**验收标准**：
- 用户点击「查看详情并应用」后，弹出 `showSyncPreviewDialog`
- 预览框展示该账本的 `SyncPreview`（新增/修改/删除分组，支持分项勾选）
- 用户勾选后点击「应用选中」按钮，调用 `applyPreviewChanges` 写入本地
- 应用完成后弹出结果摘要（应用了 N 条变更）
- 应用后触发 `PostProcessor.runAfterDownload(ref)` 刷新 UI

### US-4：多账本逐个确认

**作为**一个有多个账本的用户，
**我希望**每个有更新的账本都被独立检查和提示，
**以便**我对每个账本独立决策。

**验收标准**：
- 遍历所有本地账本，对每个账本调用 `getStatus` 检查 `SyncDiff`
- 仅有更新的账本（`cloudNewer` 或 `different`）触发弹窗
- 多个账本按顺序弹窗（前一个处理完才弹下一个），避免叠加
- 用户可以中途取消剩余账本的检查（在某个账本弹窗点「跳过剩余」）

## 3. 功能需求

### FR-1：触发时机

| 条件 | 行为 |
|------|------|
| 冷启动进入 `BeeApp.initState` | 在 `_refreshLedgersStatusInBackground` 完成后触发检查 |
| 配置为路径 A 且 valid | 执行检查流程 |
| 配置为路径 B 或 local | 跳过，走现有逻辑 |
| `appInitStateProvider != ready` | 等待 ready 后再触发 |
| 本次启动已触发过 | 不重复触发（启动级幂等） |

### FR-2：检查流程

1. 读取 `activeCloudConfigProvider`，确认是路径 A
2. 获取所有本地账本列表（`ledgerListProvider` 或等价 provider）
3. 对每个账本调用 `syncService.getStatus(ledgerId:)`
4. 筛选 `diff == cloudNewer || diff == different` 的账本
5. 若有候选账本，按顺序进入弹窗流程

### FR-3：弹窗流程（每个账本）

```
对每个候选账本 ledgerId：
  1. 调用 syncService.downloadAndPreview(ledgerId) 拿到 SyncPreview
  2. 若 preview == null（旧格式）：
     - 弹 AppDialog.confirm 询问是否全量替换
     - 用户确认 → downloadAndRestoreToCurrentLedger
     - 跳过 showSyncPreviewDialog
  3. 若 preview.isEmpty（无变更）：
     - 静默跳过，不弹窗
  4. 若 preview 有变更：
     - 弹 AppDialog.confirm 显示汇总（新增/修改/删除计数）
     - 用户选「暂不合并」→ 跳到下一个账本
     - 用户选「查看详情并应用」→ showSyncPreviewDialog
  5. showSyncPreviewDialog 返回选中列表：
     - null 或空 → 视为取消，跳到下一个账本
     - 非空 → applyPreviewChanges + PostProcessor.runAfterDownload
  6. 弹 AppDialog.info 显示应用结果摘要
```

### FR-4：错误处理

| 错误场景 | 处理 |
|---------|------|
| `getStatus` 抛异常 | 记录日志，跳过该账本，继续下一个 |
| `downloadAndPreview` 抛异常 | 弹 `AppDialog.error` 提示该账本拉取失败，继续下一个 |
| `applyPreviewChanges` 抛异常 | 弹 `AppDialog.error` 提示应用失败，不影响其他账本 |
| 网络异常 / 超时 | 同上，按账本级错误处理 |
| 加密密钥不匹配（DecryptionException） | 弹 `AppDialog.error` 提示去加密设置页重新输入密码，跳过该账本 |

### FR-5：并发与幂等

- 启动级单次触发：使用 `_startupSyncCheckDone` 标志位，避免 `initState` 重复调用或 `syncServiceProvider` 重建时重复触发
- 与现有 `_triggerInitialCloudSync`（路径 B）互斥：路径 A 不走该函数，无冲突
- 与用户手动在 `cloud_sync_page` 点击下载互斥：若用户已在同步页面操作，启动检查弹窗会感知 `uploadingLedgerIdsProvider` 非空并延后

## 4. 非功能需求

### NFR-1：性能

- 检查流程在后台 Isolate / microtask 中执行，不阻塞 UI 线程
- `getStatus` 调用串行，避免并发请求打爆云端
- 整体检查耗时（无更新场景）≤ 3 秒（取决于账本数量和网络）

### NFR-2：可观测性

- 所有检查步骤打日志（`logger.info('StartupSyncCheck', ...)`）
- 错误场景打 `logger.warning` / `logger.error`
- 不引入新的埋点 SDK

### NFR-3：兼容性

- 不破坏现有路径 A 同步流程
- 不影响路径 B（BeeCount Cloud）用户
- 不影响未配置云端同步的本地用户
- 不影响 E2EE 加密功能（密文格式 `BEECRYPT1:...` 透明解密）

### NFR-4：可测试性

- 核心检查逻辑抽取为独立函数/类，支持单元测试
- 弹窗流程通过依赖注入可 mock
- 不依赖真实网络，测试用 mock `SyncService`

## 5. 边界条件

| 场景 | 处理 |
|------|------|
| 用户首次安装，无任何账本 | 跳过检查（账本列表为空） |
| 用户未登录（supabase/beecount_cloud 需登录） | 跳过（`needsLogin` 但 `user == null`） |
| 账本在本地为空但云端有数据 | 视为 `cloudNewer`，正常弹窗 |
| 账本在云端无备份（`noRemote`） | 跳过该账本 |
| 云端数据为旧格式（v5 及以下，无 syncId） | 走全量替换确认流程（FR-3 步骤 2） |
| 用户在弹窗期间切到后台再回来 | 弹窗保持，不重复触发 |
| `globalNavigatorKey.currentContext` 为 null | 跳过本次检查（理论上不会发生，因 ready 后才有 BeeApp） |
| 多设备并发上传导致云端版本变化 | `downloadAndPreview` 拿到的是当下快照，应用后再次上传会覆盖 |

## 6. 验收清单

- [ ] 冷启动进入主界面后，路径 A 配置下自动检查云端更新
- [ ] 无更新时不弹任何窗，静默通过
- [ ] 有更新时弹强制提示框，barrierDismissible=false
- [ ] 提示框显示账本名 + 变更汇总（新增/修改/删除计数）
- [ ] 「查看详情并应用」正确弹出 showSyncPreviewDialog
- [ ] 预览框分项勾选后应用变更成功，本地数据更新
- [ ] 应用后 UI 自动刷新（PostProcessor.runAfterDownload）
- [ ] 多账本场景逐个弹窗，不叠加
- [ ] 用户取消某账本后不影响后续账本检查
- [ ] 路径 B（BeeCount Cloud）配置下不触发本功能
- [ ] 本地模式（local）下不触发本功能
- [ ] 网络异常 / 加密异常时弹错误提示，不崩溃
- [ ] 重复触发被幂等保护，不会重复弹窗
- [ ] 单元测试覆盖核心检查逻辑
