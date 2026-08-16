# PiggyCount 云端全量备份与全量覆盖设计文档

> 版本：v1.0  日期：2026-08-16
> 关联需求：`/prd/cloud_backup/requirements.md`

---

## 1. 总体架构

采用**方案 A：独立 CloudBackupService + 复用现有管线**。新增 `lib/cloud/backup/` 模块，`TransactionsSyncManager` 不改动（仅在恢复时复用其公开导入辅助方法）。

```
┌─ cloud_sync_page.dart ─────────────────────────────┐
│  全量同步卡片（现有）                                │
│  云端备份卡片（新增）                                │
│   ├─ 立即备份    ──► showBlockingProgressDialog      │
│   ├─ 从备份恢复  ──► 备份列表 ► 双重5s确认 ► 阻塞进度 │
│   └─ 定时备份开关 + 时间选择                         │
└──────────────┬──────────────────────────────────────┘
               │
     ┌─────────▼──────────┐      ┌──────────────────┐
     │ CloudBackupService │◄─────│ BackupScheduler  │
     │  createBackup      │      │ Timer.periodic   │
     │  listBackups       │      │ (1min, app.dart) │
     │  restoreBackup     │      └──────────────────┘
     └─────────┬──────────┘
               │ 复用
   ┌───────────▼───────────────┬──────────────────────┐
   │ exportTransactionsJson    │ EncryptionService     │
   │ (transactions_json.dart)  │ (E2EE, BEECRYPT1)     │
   │ 导入管线(data_import 等)  │ storage.upload/list   │
   └───────────────────────────┴──────────────────────┘
```

| 组件 | 文件 | 职责 |
|---|---|---|
| `CloudBackupService` | `lib/cloud/backup/cloud_backup_service.dart` | 创建/列举/恢复备份；ZIP 打包解包；附件收集与落盘 |
| `BackupScheduler` | `lib/cloud/backup/backup_scheduler.dart` | 每分钟检查触发条件，调用 `CloudBackupService.createBackup` |
| 备份卡片 UI | `lib/pages/cloud/cloud_sync_page.dart` | 入口交互、进度、状态展示 |
| 备份 providers | `lib/cloud/backup/cloud_backup_providers.dart` | 服务装配、开关/时间/最近状态持久化 provider |

对现有代码的最小侵入（保持单一事实源）：
- `TransactionsSyncManager` 仅新增只读 getter `decoratedStorage()`（返回 E2EE 装饰后的 storage，备份复用同一加密装配）
- `data_import_service.dart` 新增顶层 `restoreLedgerFromJson()`：把 `downloadAndRestoreToCurrentLedger` 中段（P1-1 空快照守卫 + 事务内清空导入）抽为公共函数，同步恢复与备份恢复共用；`_clearLedgerTransactions` 随之迁移

## 2. 备份文件格式（兼容性核心）

### 2.1 ZIP 内部结构（镜像云端同步目录）

```
PiggyCount-2026-08-16.zip
├── ledger_1.json            ← exportTransactionsJson 原始产物，与上传云端的完全同构（v8）
├── ledger_2.json
└── attachments/
    ├── <sha256>.bin         ← 内容寻址，跨账本/跨交易去重后的并集
    └── ...
```

### 2.2 加密与传输（关键设计决策）

**ZIP 容器整体复用附件上传的既有传输路径**：

```
备份:  ZIP bytes → base64Encode → storage.upload(path, data)
                                    └► E2EE 开启时 EncryptedCloudStorageService
                                       透明加密（与 ledger JSON / 附件 bin 同口径）
恢复:  storage.download(path) → (装饰器透明解密) → base64Decode → ZIP bytes
```

- 理由：`CloudStorageService` 仅有 String 传输接口；现有附件二进制上传正是 `base64 → String upload → 装饰器加密`（`transactions_sync_manager.dart` L612-616），备份沿用该口径可实现**字节级加密一致性**，且零接口改动、各路径 A 后端（WebDAV/S3/Supabase/iCloud）全部天然支持
- 未开启加密时存明文 base64，与现有未加密同步行为一致
- 恢复端对单个 `ledger_<id>.json` 内容按 `BEECRYPT1:` 前缀探测密文（与 `enableFromCloud` 探测逻辑一致），探测不到按明文解析——兼容「未加密时期备份 → 之后开启加密」的恢复场景

### 2.3 命名与当日覆盖

- 云端路径：`piggycount-bak/PiggyCount-yyyy-MM-dd.zip`，日期取**本地时区**当日
- WebDAV 上传时自动递归创建 `piggycount-bak/` 目录；S3/Supabase 为前缀语义，无需创建
- `upload` 为 upsert 语义 → 同日再次备份天然覆盖，无需先删后传

## 3. 核心流程

### 3.1 createBackup（手动 / 定时共用）

```
1. repository.getAllLedgers() 取全部本地账本
2. 逐账本 exportTransactionsJson(db, ledgerId) → JSON 字符串
3. 收集附件：汇总各账本交易引用的 localSha256 去重集合，
   从 {应用文档目录}/attachments/<fileName> 定位物理文件（同 sha 任一存在即可，
   镜像 uploadAttachmentObjects 的定位逻辑 L573-607）
4. archive 包内存式 Archive + ZipEncoder 打包（与 attachment_export_import_service
   同一既有模式）：每账本写入 ledger_<id>.json；每个附件写入 attachments/<sha256>.bin
5. base64Encode(ZIP) → storage.upload('piggycount-bak/PiggyCount-<today>.zip')
6. 返回 (账本数, 附件数) 统计
```

- onProgress 回调贯穿始终，手动模式映射为阻塞弹窗状态文案
- 孤儿附件行（本地文件缺失）跳过并 warning，不阻断（对齐现有口径）

### 3.2 listBackups

```
storage.list(path: 'piggycount-bak/')
  → 过滤 ^PiggyCount-\d{4}-\d{2}-\d{2}\.zip$
  → 按日期倒序返回 [{fileName, date, size}]
```

### 3.3 restoreBackup（全量覆盖）

```
1. 双重 showDangerConfirmDialog（各 5s 倒计时，barrierDismissible:false）
   文案明确「将用备份覆盖本地全部账本数据，此操作不可撤销」
2. showBlockingProgressDialog（PopScope canPop:false）
3. 下载 → base64Decode → 解包到临时目录
4. 逐 ledger_<id>.json：
   ├─ BEECRYPT1: 前缀探测 → 需要时 decrypt → parseJsonToImportData
   ├─ 本地存在同 id 账本 → 走与 downloadAndRestoreToCurrentLedger 相同的
   │   整体覆盖导入管线
   └─ 本地不存在 → 走与 downloadRemoteLedger 相同的新建导入管线
   （单账本失败计数不中断，onProgress 汇报 x/n）
5. 附件落盘（镜像 drainAttachmentJobs L675-744 语义，数据源换为 ZIP）：
   遍历恢复后各账本附件行 → localSha256 在 ZIP 内且本地文件缺失
   → sha256 校验一致 → 写入 {文档目录}/attachments/<row.fileName>
6. finally 关闭阻塞弹窗 → 结果弹窗（成功/失败统计）→ 刷新
   ledgerListRefresh / syncStatusRefresh / statsRefresh
```

### 3.4 BackupScheduler（定时触发）

- 挂载：`app.dart` initState 内 `addPostFrameCallback` 后启动，与 `_triggerStartupSyncCheck` 同层；App dispose 时取消 Timer
- `Timer.periodic(Duration(minutes: 1))` 检查，SharedPreferences 持久化：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `backup_auto_enabled` | bool | false | 定时备份开关 |
| `backup_time` | String | `"22:00"` | 每日触发时间（HH:mm） |
| `backup_last_date` | String | — | 最近触发日（yyyy-MM-dd），**无论成败均写入** |

- 触发条件（全部满足）：开关开 && `now ≥ 今日 backup_time` && `backup_last_date ≠ today` && `syncServiceProvider` 为路径 A 已配置（`TransactionsSyncManager` 且非 PiggyCount Cloud）
- 启动补触发：App 在设定时间之后启动且当日未备份 → 首次检查即触发（由上述条件自然覆盖，无需特殊逻辑）
- 执行为**非阻塞**后台任务（auto 类约定），完成后更新 `backup_last_date` 与最近状态（内存 provider + SharedPreferences 简单状态串），失败不重试
- 防并发：service 内部 `bool _running` 互斥，与手动备份共用同一把锁

## 4. UI 设计（cloud_sync_page.dart）

- 位置：全量同步卡片正下方；显示条件与全量同步卡片一致：`canUseCloud && !isPiggyCountCloud`
- 结构：`SectionCard`（默认边框——备份本身是安全操作；「从备份恢复」tile 的标题/说明使用 error 色警示）
  - `AppListTile` 立即备份（`Icons.backup_outlined`）→ 阻塞进度 + `createBackup`
  - `PiggyTokens.cardDivider`
  - `AppListTile` 从备份恢复（`Icons.restore`，error 色文案）→ 备份列表 bottom sheet（日期+大小）→ 双重确认 → 阻塞进度 + `restoreBackup`
  - `PiggySwitchListTile` 定时备份开关；开启时展示当前时间 tile，点击弹 `showTimePicker`
  - 卡片底部 caption：最近备份「yyyy-MM-dd · 成功/失败」或「尚未备份」
- 忙碌联动：新增 `backupBusy / restoreBusy` 标志，与现有 6 个标志互斥联动（任一忙碌时全部入口禁用并显示转圈）
- 列表为空时恢复入口仍可点击 → 弹「云端暂无备份」提示

## 5. l10n 文案（四语言）

`app_en.arb` 新增（zh / zh_TW / ko 同步翻译），共 22 个 key：

`backupCardTitle` / `backupNowTitle` / `backupNowSubtitle` / `backupNoLedgers` / `backupRunningStatus` / `backupPackingProgress(done, total)` / `backupSuccessMessage(fileName)` / `backupFailedAuthMessage` / `backupFailedNetworkMessage` / `restoreFromBackupTitle` / `restoreFromBackupSubtitle` / `backupListDialogTitle` / `backupListEmptyMessage` / `restoreConfirm1Message(date)` / `restoreConfirm2Message` / `restoreRunningStatus` / `restoreLedgerProgress(done, total)` / `restoreResultMessage(success, failed)` / `backupAutoTitle` / `backupAutoSubtitle` / `backupTimeTitle` / `lastBackupCaption(date, ok)`

## 6. 错误处理

| 场景 | 处理 |
|---|---|
| 备份上传 401/403 | `CloudAuthException` → 提示「检查云服务配置」（沿用 WebDAV 层既有识别） |
| 备份网络失败 | 提示「检查网络后重试」；定时场景记录失败状态，当日不重试 |
| 恢复时密文解不开（密码已变更） | 该账本计入 failed，结果弹窗提示；其余账本继续 |
| 恢复时附件 sha256 不匹配 | 跳过该附件并 warning（内容寻址信任根基不可破坏，镜像 L738-744） |
| ZIP 损坏 / 非法文件 | 恢复前尝试解包失败 → 整体报错，不动本地数据 |
| 定时触发时云服务未就绪 | 跳过本次检查，下一分钟重查（未写 last_date，不算当日已备） |

## 7. 测试计划（test/backup/）

- `cloud_backup_service_test.dart`：ZIP 构建（账本+附件入包、内部路径、当日文件名）、同日覆盖（upload 参数断言）、listBackups 过滤与倒序、恢复导入（覆盖/新建/保留三分支）、附件校验落盘、密文/明文混合探测
- `backup_scheduler_test.dart`：触发条件判定矩阵（开关/时间/当日已备/云类型）、成败均写 last_date、互斥锁
- 回归：`flutter analyze` 无新增告警；`flutter gen-l10n` 后全量 `flutter test`

## 8. 已知风险与后续演进

- **内存峰值**：base64 String 上传峰值约为 ZIP 的 2.2 倍；v1 接受，附件量极大用户有 OOM 风险 → 后续演进：CloudStorageService 增加字节/分块接口（WebDAV `_client.write` 已支持 bytes）
- **备份体积**：全量含附件，长期每日一份会占用云端存储 → 后续演进：保留策略（如仅留最近 N 天）
- **定时覆盖时点**：备份取的是触发时刻数据，22:00 后的当日改动不在当日备份中（在次日备份里）——符合「每日一份」语义，文档明示即可
