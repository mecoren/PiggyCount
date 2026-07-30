# PiggyCount 启动时云端数据拉取提示设计文档

> 版本：v1.1  日期：2026-07-27
> 范围：路径 A（S3 / WebDAV / Supabase / iCloud）快照同步
> 不在范围：路径 B（PiggyCount Cloud 增量同步，保持现有自动同步逻辑）
> 关联需求：`/prd/startup_sync_check/requirements.md`
>
> v1.1 变更：引入全屏遮罩 overlay，进入 app 即阻断用户交互，优化弹窗样式

---

## 0. v1.1 架构变更概览

**新增组件**：`lib/cloud/startup_sync_overlay.dart`
- `StartupSyncState` sealed class 状态机（Idle/Checking/HasUpdates/Applying/Done/Error/Dismissed）
- `StartupSyncController extends ChangeNotifier`：持有状态、attach/detach OverlayEntry
- `_StartupSyncOverlayView`：根据 state 渲染对应卡片，全屏 AbsorbPointer 阻断交互

**重构**：`lib/cloud/startup_sync_checker.dart`
- 移除 `deps.showSummaryDialog` / `deps.showError` / `deps.showInfo`
- 改为通过 `controller.startChecking()` / `controller.showHasUpdates()` / `controller.done()` 等方法推送状态
- 用户选择通过 `Completer<SummaryChoice>` 异步等待 overlay 回传
- confirmEach 模式下先 dismiss overlay，再用 showDialog 接管（`deps.showLegacyError/Info`）

**接入变更**：`lib/app.dart`
- `_runStartupSyncCheck` 新增：创建 controller + attach overlay + 监听状态管理生命周期
- DoneState 自动 1.5s 后 dismiss → DismissedState → detach overlay
- ErrorState 等待用户点确定 → dismiss → detach
- dispose 时清理 controller

**样式优化**：
- 居中卡片 + 加载动画（CircularProgressIndicator with progress value）
- 进度条显示 N/M（检查中、应用中）
- BeeTokens.surfaceElevated 背景 + radius16 圆角 + BeeShadows.card 阴影
- 三按钮垂直排列（主按钮 FilledButton + 次按钮 OutlinedButton + 文字按钮 TextButton）
- 完成/错误用图标（check_circle / error_outline）+ 品牌色

---

## 0.1 状态机流转图

```
IdleState
  │
  ▼ (runIfNeeded 开始)
CheckingState(checked=0, total=N)
  │ (每检查一个账本)
  ▼ updateCheckingProgress(checked++, total)
CheckingState(checked=N, total=N)
  │
  ├─ 无候选 ──► DismissedState (overlay detach)
  │
  ▼ showHasUpdates(candidates, completer)
HasUpdatesState
  │
  ├─ 用户选 skip ──► DismissedState
  │
  ├─ 用户选 applyAll ──► ApplyingState(applied=0, total=N)
  │     │ (每个账本 apply 完成)
  │     ▼ updateApplyingProgress(applied++, total, name, changes)
  │     ApplyingState(applied=N, total=N)
  │     │
  │     ├─ 全成功 ──► DoneState("已合并 N 个账本，共 M 条变更")
  │     ├─ 全失败 ──► ErrorState("全部 N 个账本合并失败")
  │     └─ 部分失败 ──► DoneState("已合并 X 个账本，Y 个失败")
  │
  └─ 用户选 confirmEach ──► DismissedState (overlay 关闭)
        │ (showDialog 接管，逐账本弹窗)
        │ 每个账本: showPerLedgerDialog → showSyncPreviewDialog → apply
        │ 错误用 showLegacyError，成功用 showLegacyInfo
        ▼ (全部完成)

DoneState
  │ (1.5 秒后自动)
  ▼
DismissedState (overlay detach)

ErrorState
  │ (用户点确定)
  ▼
DismissedState (overlay detach)
```

---

## 1. 需求理解

在 PiggyCount 冷启动进入主界面后，对配置为路径 A（S3/WebDAV/Supabase/iCloud）的用户主动检查每个账本的云端更新状态，发现 `cloudNewer` 或 `different` 的账本时强制弹窗提示，并复用现有 `showSyncPreviewDialog` 让用户预览并选择性应用变更。路径 B（PiggyCount Cloud）保持现有 `_triggerInitialCloudSync` 自动同步逻辑不动。

## 2. 现状分析

### 2.1 启动钩子现状

`BeeApp._BeeAppState.initState()`（[lib/app.dart:86-108](file:///c:\Develop\project\00_AI\PiggyCount\lib\app.dart)）当前流程：

```
initState
  ├─ addObserver(this)
  ├─ 初始化动画控制器
  ├─ _refreshLedgersStatusInBackground()  ← microtask 内做后台同步
  └─ addPostFrameCallback
       ├─ _setupAppLinkListener()
       └─ _setupQuickActions()
```

`_refreshLedgersStatusInBackground()`（[lib/app.dart:159-209](file:///c:\Develop\project\00_AI\PiggyCount\lib\app.dart)）内部：
- 路径 A：调 `syncService.refreshAllLedgersStatus()` 仅预热状态，**不拉数据、不合并**
- 路径 B：调 `_triggerInitialCloudSync(engine)` 自动 push/pull

### 2.2 现有可复用资产

| 资产 | 位置 | 复用方式 |
|------|------|---------|
| `downloadAndPreview(ledgerId)` | [transactions_sync_manager.dart:380](file:///c:\Develop\project\00_AI\PiggyCount\lib\cloud\transactions_sync_manager.dart) | 直接调用，返回 `SyncPreview?` |
| `applyPreviewChanges(...)` | [transactions_sync_manager.dart:422](file:///c:\Develop\project\00_AI\PiggyCount\lib\cloud\transactions_sync_manager.dart) | 直接调用，应用选中变更 |
| `getStatus(ledgerId)` | [transactions_sync_manager.dart:443](file:///c:\Develop\project\00_AI\PiggyCount\lib\cloud\transactions_sync_manager.dart) | 直接调用，返回 `SyncStatus` |
| `downloadAndRestoreToCurrentLedger` | transactions_sync_manager.dart:328 | 旧格式全量替换兜底 |
| `showSyncPreviewDialog` | [sync_preview_dialog.dart:12](file:///c:\Develop\project\00_AI\PiggyCount\lib\pages\cloud\sync_preview_dialog.dart) | 直接调用，`barrierDismissible: false` |
| `AppDialog.confirm/info/error` | [widgets/ui/dialog.dart](file:///c:\Develop\project\00_AI\PiggyCount\lib\widgets\ui\dialog.dart) | 提示框 + 结果摘要 |
| `PostProcessor.runAfterDownload(ref)` | cloud_sync_page.dart 引用 | 应用后刷新 UI providers |
| `globalNavigatorKey` | [main.dart:42](file:///c:\Develop\project\00_AI\PiggyCount\lib\main.dart) | 无 BuildContext 时拿 context 弹窗 |

### 2.3 关键约束

- `appSplashInitProvider` 完成后才会切到 `BeeApp`，故 `BeeApp.initState` 时 `globalNavigatorKey.currentContext` 已可用
- 路径 A 的 `syncServiceProvider` 在 `BeeApp.initState` 时可能尚未完成初始化（`activeCloudConfigProvider` 是 `FutureProvider`），需要异步等待
- `getStatus` 内部会下载云端 JSON 计算指纹，已有缓存机制，但首次启动时缓存为空，每个账本都会触发一次下载

## 3. 关键技术决策

### 3.1 新增独立编排器 `StartupSyncChecker`

**决策**：新建 `lib/cloud/startup_sync_checker.dart`，将启动检查逻辑封装为独立类，不污染 `BeeApp` 和 `TransactionsSyncManager`。

**理由**：
- `BeeApp` 已 600+ 行，职责过载，不宜继续堆砌启动同步逻辑
- `TransactionsSyncManager` 是数据层，不应承担 UI 弹窗编排
- 独立类便于单元测试（依赖注入 `SyncService` / `BuildContext` / `ref`）
- 与现有 `SyncDiffService`、`TransactionsSyncManager` 解耦风格一致

**接口设计**：

```dart
/// 启动时云端数据拉取检查编排器
///
/// 仅适用于路径 A（S3/WebDAV/Supabase/iCloud），路径 B 跳过。
class StartupSyncChecker {
  StartupSyncChecker(this._ref);

  final WidgetRef _ref;
  bool _done = false;  // 启动级幂等标志

  /// 执行启动检查。若已执行过则直接返回。
  ///
  /// 流程：
  /// 1. 等待 activeCloudConfig 就绪，确认是路径 A
  /// 2. 等待 syncService 就绪为 TransactionsSyncManager
  /// 3. 获取所有账本，逐个 getStatus 检查
  /// 4. 对有更新的账本依次弹窗 + 预览 + 应用
  Future<void> runIfNeeded();
}
```

### 3.2 触发点：`BeeApp.initState` 的 `addPostFrameCallback`

**决策**：在 [app.dart:104-107](file:///c:\Develop\project\00_AI\PiggyCount\lib\app.dart) 的 `addPostFrameCallback` 内追加 `StartupSyncChecker(ref).runIfNeeded()`，与 `_setupAppLinkListener` / `_setupQuickActions` 并列。

**理由**：
- `addPostFrameCallback` 保证首帧渲染完成、`context` 可用、`globalNavigatorKey.currentContext` 非 null
- 不阻塞首屏渲染（`_refreshLedgersStatusInBackground` 走 microtask 抢先跑，本检查走 postFrame 让 UI 先出）
- 与现有 `_lastInitialCloudSyncTriggeredAt` 节流模式一致

**不选 `appSplashInitProvider` 的原因**：在 splash 阶段阻塞会延迟进入主界面，且 splash 阶段 `globalNavigatorKey` 还指向 SplashPage 而非 BeeApp，弹窗会错位。

### 3.3 弹窗 Context 来源：`globalNavigatorKey.currentContext`

**决策**：弹窗统一用 `globalNavigatorKey.currentContext!.context`，不依赖 `BeeApp` 的 `BuildContext`。

**理由**：
- `globalNavigatorKey` 是 App 级 NavigatorKey，无论用户在哪个页面都能正确弹出
- 避免持有 `BeeApp` 的 `context` 导致内存泄漏或 `mounted` 检查复杂化
- 与现有 service 层弹窗模式一致（搜索结果中提到 service 层用 `globalNavigatorKey` 弹路由）

### 3.4 多账本顺序弹窗：串行 await

**决策**：用 `for await` 循环串行处理账本，前一个弹窗关闭后才弹下一个。

**理由**：
- 并行弹窗会叠加遮挡，用户体验差
- Flutter `showDialog` 本身是 await 的，天然适合串行
- 用户可在某个账本弹窗点「跳过剩余」跳出循环

### 3.5 账本列表来源：`repositoryProvider.getAllLedgers()`

**决策**：直接调 `ref.read(repositoryProvider).getAllLedgers()` 拿所有账本（含 id + name）。

**理由**：
- `repositoryProvider` 是 `Provider<BaseRepository>`（[database_providers.dart:23](file:///c:\Develop\project\00_AI\PiggyCount\lib\providers\database_providers.dart)），`BaseRepository.getAllLedgers()` 透传到 `LedgerRepository.getAllLedgers()` 返回 `Future<List<Ledger>>`
- `Ledger` 类型来自 `lib/data/db.g.dart`（drift 生成），含 `id`、`name`、`currency` 等字段
- 与 `app.dart:241`、`sync_providers.dart:902` 等多处现有用法一致

### 3.6 一键应用全部账本：汇总弹窗 + 三选项

**决策**：在收集到所有有更新的账本后，先弹一个汇总对话框，提供三个选项：
- **「一键应用全部」**：跳过逐账本预览，对所有账本依次执行 `downloadAndPreview` → `applyPreviewChanges`（应用所有变更，不分项勾选）
- **「逐个确认」**：进入原设计的逐账本弹窗流程（`AppDialog.confirm` + `showSyncPreviewDialog`）
- **「暂不合并」**：全部跳过

**理由**：
- 用户对「快速合并」与「精细控制」有不同需求，提供两种模式覆盖两类场景
- 「一键应用」跳过预览弹窗，串行 apply 所有账本，速度更快
- 「逐个确认」保留原设计的分项勾选能力
- 三选项通过 `AppDialog` 的扩展按钮实现（不用 `_show` 的双按钮模板，需新增三按钮变体或直接用 `showDialog` + `AlertDialog` 自定义）

**实现方式**：新增私有方法 `_showSummaryDialog(candidates)` 返回 `enum _SummaryChoice { applyAll, confirmEach, skip }`，在 `runIfNeeded` 内根据返回值分支。

### 3.7 幂等保护：实例级 `_done` 标志

**决策**：`StartupSyncChecker` 实例内 `bool _done` 标志，`runIfNeeded` 开头检查。

**理由**：
- `BeeApp.initState` 只触发一次，但 `syncServiceProvider` 重建时 `listenManual` 可能再次触发兜底逻辑，需要幂等
- 实例级标志足够，不需要持久化（每次冷启动都需要重新检查，符合"每次启动都检查"的需求）
- 与现有 `_lastInitialCloudSyncTriggeredAt` 模式一致

## 4. 实现步骤

### 步骤 1：创建 `StartupSyncChecker` 类（TDD）

**文件**：`lib/cloud/startup_sync_checker.dart`

**职责**：
- 接收 `WidgetRef`
- `runIfNeeded()` 编排整个检查流程
- 内部拆分为私有方法：`_isPathAConfigured()` / `_checkAllLedgers()` / `_handleOneLedger(ledgerId, ledgerName)`

**测试文件**：`test/cloud/startup_sync_checker_test.dart`

### 步骤 2：在 `BeeApp.initState` 接入

**文件**：[lib/app.dart](file:///c:\Develop\project\00_AI\PiggyCount\lib\app.dart)（修改 line 104-107 的 `addPostFrameCallback`）

**变更**：

```dart
WidgetsBinding.instance.addPostFrameCallback((_) {
  _setupAppLinkListener();
  _setupQuickActions();
  // 启动时检查路径 A 的云端更新（仅路径 A，路径 B 走现有 _triggerInitialCloudSync）
  StartupSyncChecker(ref).runIfNeeded();
});
```

**注意**：`StartupSyncChecker` 实例不缓存为成员变量，每次 `initState` 创建新实例，`_done` 标志在该实例内有效。因 `BeeApp` 重建时 `initState` 不会重复调用（除非整个 widget 树重建），幂等性足够。

### 步骤 3：实现弹窗流程

**复用现有组件**：
- `AppDialog.confirm<bool>` 询问是否合并
- `showSyncPreviewDialog` 展示变更详情
- `AppDialog.info` 展示应用结果
- `AppDialog.error` 展示错误

**新增文案**（在 `lib/l10n/app_localizations.dart` 增加对应 key）：
- `startupSyncCheckTitle`：'云端有更新'
- `startupSyncCheckSummaryMessage`：'检测到 {count} 个账本有云端更新，是否合并到本地？'
- `startupSyncCheckLedgerMessage`：'账本「{ledger}」检测到云端有 {added} 条新增、{modified} 条修改、{deleted} 条删除，是否合并到本地？'
- `startupSyncCheckApplyAll`：'一键应用全部'
- `startupSyncCheckConfirmEach`：'逐个确认'
- `startupSyncCheckViewDetail`：'查看详情并应用'
- `startupSyncCheckSkip`：'暂不合并'
- `startupSyncCheckSkipRest`：'跳过剩余'
- `startupSyncCheckApplyResult`：'已应用 {count} 条变更'
- `startupSyncCheckApplyAllResult`：'已合并 {ledgerCount} 个账本，共 {changeCount} 条变更'
- `startupSyncCheckFetchError`：'账本「{ledger}」拉取失败：{error}'
- `startupSyncCheckApplyError`：'账本「{ledger}」应用失败：{error}'
- `startupSyncCheckDecryptionError`：'账本「{ledger}」解密失败，请前往加密设置重新输入密码'

### 步骤 4：处理旧格式与边界

- `preview == null` → 走 `downloadAndRestoreToCurrentLedger` + `AppDialog.confirm` 确认
- `preview.isEmpty` → 静默跳过
- 加密异常 `DecryptionException` → 弹错误提示并指引用户去加密设置页
- 网络异常 → 弹错误提示，继续下一个账本

### 步骤 5：测试与验证

**单元测试**（`test/cloud/startup_sync_checker_test.dart`）：
- mock `TransactionsSyncManager` / `SyncDiffService`
- 验证：路径 B 配置下不触发
- 验证：本地模式不触发
- 验证：无账本时不触发
- 验证：所有账本 `inSync` 时不弹窗
- 验证：单个账本 `cloudNewer` 时弹一次提示
- 验证：幂等标志生效，二次调用不触发

**集成验证**：
- `flutter analyze` 无新增警告
- `flutter test` 全部通过
- 手动验证：配置 S3/WebDAV 任一后端，云端有更新时冷启动弹窗

## 5. 数据流

```
BeeApp.initState
  └─ addPostFrameCallback
       └─ StartupSyncChecker(ref).runIfNeeded()
            ├─ 0. _done 检查 → 已执行过则 return
            ├─ 1. await activeCloudConfigProvider.future
            │     ├─ type == local/piggycountCloud → return（跳过）
            │     └─ type ∈ {s3,webdav,supabase,icloud} && valid → 继续
            ├─ 2. syncService = ref.read(syncServiceProvider)
            │     └─ is! TransactionsSyncManager → return（兜底）
            ├─ 3. ledgers = ref.read(repositoryProvider).getAllLedgers()
            │     └─ empty → return
            ├─ 4. 收集候选账本 candidates：
            │     for ledger in ledgers:
            │       status = await syncService.getStatus(ledger.id)
            │       diff ∈ {cloudNewer, different} → 加入 candidates
            │     candidates 空 → return
            ├─ 5. 弹汇总对话框 _showSummaryDialog(candidates) 返回三选项之一：
            │     ├─ skip → return
            │     ├─ applyAll（一键应用全部）→
            │     │     for c in candidates:
            │     │       previewResult = await syncService.downloadAndPreview(c.id)
            │     │       preview == null → downloadAndRestoreToCurrentLedger（全量替换）
            │     │       preview != null && !isEmpty →
            │     │         selected = preview.changes（全部选中）
            │     │         await syncService.applyPreviewChanges(c.id, selected, importData)
            │     │         PostProcessor.runAfterDownload(ref)
            │     │       catch → 记录错误，继续下一个
            │     │     最后弹 AppDialog.info 汇总结果
            │     └─ confirmEach（逐个确认）→
            │           for c in candidates:
            │             previewResult = await syncService.downloadAndPreview(c.id)
            │             preview == null → AppDialog.confirm 全量替换
            │             preview.isEmpty → 跳过
            │             AppDialog.confirm 显示该账本汇总（三按钮：跳过剩余/暂不合并/查看详情）
            │               ├─ 跳过剩余 → break
            │               ├─ 暂不合并 → continue
            │               └─ 查看详情并应用 →
            │                    selected = await showSyncPreviewDialog(preview)
            │                    selected == null/empty → continue
            │                    result = await syncService.applyPreviewChanges(...)
            │                    PostProcessor.runAfterDownload(ref)
            │                    AppDialog.info 显示该账本结果
            │             catch → AppDialog.error，继续下一个
            └─ 6. _done = true
```

## 6. 边界条件与潜在风险

### 6.1 启动时序风险

| 风险 | 缓解 |
|------|------|
| `activeCloudConfigProvider` 长时间未就绪 | 不设超时，依赖 FutureProvider 自然完成；若失败则 catch 后静默跳过 |
| `syncServiceProvider` 在 `addPostFrameCallback` 时还是 `LocalOnlySyncService` | 内部增加重试：监听 `syncServiceProvider` 变化，等变为 `TransactionsSyncManager` 后再执行；或简单等待 500ms 后重试一次 |
| `globalNavigatorKey.currentContext` 为 null | 检查 null 后跳过（理论上不会发生，因 ready 后才进 BeeApp） |

### 6.2 并发风险

| 风险 | 缓解 |
|------|------|
| 用户在弹窗期间手动进 `cloud_sync_page` 点下载 | `downloadAndPreview` 内部无锁，但路径 A 的 `_provider!.storage.download` 是幂等读操作，重复拉取最多浪费一次请求，不会数据损坏 |
| 用户在弹窗期间手动上传 | 上传完成后云端版本变化，但本检查已拿到 `SyncPreview`，应用的是当时的快照，不会冲突 |
| `applyPreviewChanges` 期间用户改了本地数据 | `applySyncChanges` 走 `syncId` 批量 update/insert/delete，与用户并发修改可能冲突；建议应用期间禁用主界面交互（弹窗 `barrierDismissible: false` 已部分覆盖） |

### 6.3 性能风险

| 风险 | 缓解 |
|------|------|
| 账本数量多（10+）时 `getStatus` 串行下载耗时长 | 现有 `refreshAllLedgersStatus` 已并行预热状态，本检查复用其缓存；若缓存未命中则串行下载，每个账本约 200-500ms，10 个账本约 2-5 秒，可接受 |
| 大账本 JSON 解析阻塞 UI | `downloadAndPreview` 内部 `jsonDecode` 是同步操作，大账本可能卡顿；若实测卡顿明显，后续可优化为 Isolate 解析（本次不在范围） |

### 6.4 加密兼容性

- 路径 A 已实现 E2EE 装饰器（`EncryptedCloudStorageService`），`downloadAndPreview` 拿到的 `jsonStr` 已是解密后的明文
- 若用户加密密码未输入/不匹配，`download` 会抛 `DecryptionException`，本检查 catch 后弹错误提示并指引用户去加密设置页
- 不需要在 `StartupSyncChecker` 内处理加密逻辑，透明复用

### 6.5 国际化

- 所有用户可见文案走 `app_localizations.dart`，支持中英文
- 账本名直接取 `ledger.name`（用户自命名，已是本地化文本）

## 7. 文件清单

| 操作 | 文件 | 说明 |
|------|------|------|
| 新建 | `lib/cloud/startup_sync_checker.dart` | 核心编排器 + WidgetRefDeps |
| 新建 | `lib/cloud/startup_sync_overlay.dart` | 状态机 + controller + overlay widget |
| 新建 | `test/cloud/startup_sync_checker_test.dart` | 28 个单元测试 |
| 修改 | [lib/app.dart](file:///c:\Develop\project\00_AI\PiggyCount\lib\app.dart) | `_runStartupSyncCheck` + overlay 生命周期管理 |
| 修改 | `lib/l10n/app_*.arb` (4 个文件) | 新增 13 条文案（中/英/韩/繁中） |

## 8. 不做的事

- 不修改 `TransactionsSyncManager` 接口
- 不修改 `showSyncPreviewDialog` UI
- 不修改 `SyncDiffService`
- 不为路径 B 实现预览功能
- 不引入新的状态管理 provider（`StartupSyncChecker` 是一次性编排器，不需要全局 provider 暴露状态）
- 不持久化「上次检查时间」（每次冷启动都检查，符合需求）
- 不做后台轮询 / WebSocket 推送检查
