# PiggyCount Cloud 模块 · 职责边界与耦合影响分析

> 范围说明：本文仅做架构与影响范围讨论，**不涉及任何代码改动或具体实现**。
> 分析基于当前仓库 `D:\DevTools\project\PiggyCount`（2026-08-14 现场代码）。
> 结论关键词：**不能直接"干净删除"；改为通用组件（插件式后端）可行，但需先做两次"中性基础设施下沉"。**

---

## 1. 范围界定：Cloud 模块到底包含什么

项目里存在**两层 Cloud**，极易混淆，必须先分清：

| 层 | 位置 | 角色 |
|---|---|---|
| **外部包层** | `packages/flutter_cloud_sync` 及 `_supabase`/`_webdav`/`_icloud`/`_s3`（pubspec.yaml:69-78 以 `path:` 引入） | 真正的同步引擎、传输协议、存储后端实现。**不在本次"主应用 Cloud 模块"可删范围**，且 `domain/encryption`、`app_lock` 等也会引用它 |
| **主应用编排层** | `lib/cloud/`、`lib/pages/cloud/` 及下列几个文件 | 把外部包"接"进应用的胶水、UI 与 Cloud 专属业务 |

本次讨论的"PiggyCount Cloud 模块"指**主应用编排层**，包含：

- `lib/cloud/`（顶层 7 个 + `lib/cloud/sync/` 子目录 15 个，约 22 个文件）
- `lib/pages/cloud/`（11 个页面/对话框）
- `lib/data/encryption/encrypted_cloud_storage.dart`、`encrypted_cloud_provider.dart`
- `lib/providers/cloud_mode_providers.dart`、`sync_providers.dart`、`shared_ledger_providers.dart`

⚠️ **同名陷阱**：存在两个 `sync_providers.dart`：
- `lib/cloud/sync/sync_providers.dart`（~50 行，仅 `syncEngineProvider` 等局部定义）
- `lib/providers/sync_providers.dart`（**核心枢纽，~1100+ 行**，定义 `syncServiceProvider`、`piggycountCloudProviderInstance`、`snapshotSyncCompletedProvider`、`syncEventStreamProvider` 等）

---

## 2. 职责边界：Cloud 模块独立承载的专属逻辑

把 Cloud 模块内部逻辑按能力归类，**判定其是否为"专属"**：

| 能力 | 关键文件 | 专属度 |
|---|---|---|
| PiggyCount Cloud 增量实时同步（引擎编排） | `cloud/sync/sync_engine*.dart`、`sync_coordinator`、`sync_service`、`transactions_sync_manager`、`entity_serializer`、`sync_conflict_resolver`、`sync_events`、`sync_fingerprint` | **专属** |
| 快照同步（S3/WebDAV/Supabase/iCloud） | `transactions_sync_manager` + `encrypted_cloud_*` + 外部包 | **专属** |
| 云端端到端加密装饰 | `encrypted_cloud_provider`、`encrypted_cloud_storage`、`encryption_settings_page`、`encryption_dialogs` | **专属**（仅被 `transactions_sync_manager` 引用，全应用唯一链路） |
| 共享账本 / 成员 / 设备 / 邀请 | `shared_ledger_providers`、`member_*_page`、`devices_page`、`invite_page`、`join_shared_ledger_page` | **概念专属**（多用户实时协作本质是 Cloud 特性） |
| 云服务 / 订阅页 | `cloud_service_page`、`piggycount_cloud_sync_page` | **专属** |
| 启动同步检查 + 2FA | `startup_sync_checker/overlay`、`main.dart` 的 `globalTwoFactorHandler` | **专属** |
| `AppMode` 模式枚举 | `cloud_mode_providers` | **遗留死代码**：`AppMode` 仅剩 `local`（历史 `cloud` 值已删），全应用仅 `main.dart` 使用 |

> 结论：**约 80% 的体量（同步引擎编排、云加密、共享账本 UI、服务/订阅页）是真正的 Cloud 专属逻辑**，删除在语义上"逻辑自洽"。问题不在"逻辑能不能删"，而在"删了之后谁会断"。

---

## 3. 耦合关系（影响范围的核心）

### 3.1 入站耦合（谁依赖 Cloud）—— 按风险分级

**(A) 应用根 / 启动生命周期 —— 硬接线，必须改**
- `lib/app.dart`：直接 import `cloud/sync_service`、`cloud/transactions_sync_manager`、`cloud/sync/sync_engine`、`cloud/startup_sync_checker`、`cloud/startup_sync_overlay`、`providers/sync_providers`(as `sp`)。
  - `_triggerStartupSyncCheck` / `StartupSyncChecker`：启动云端拉取检查（app.dart:119-208）
  - `_setupSyncCompletionToast`：监听 `sp.syncEventStreamProvider` / `sp.snapshotSyncCompletedProvider` 弹同步完成提示（app.dart:264-295）
  - `_refreshLedgersStatusInBackground` / `_triggerInitialCloudSync`：冷启动 eager 触发首同步（app.dart:326-543）
  - **注意：app.dart 不注册 Cloud 具名路由**（Cloud 页面由各入口页直接 push），但深度接线 Cloud *服务*。
- `lib/main.dart`：import `cloud_mode_providers`；注册 `PiggyCountCloudProvider.globalTwoFactorHandler`（main.dart:141-147）；读写 `appModeProvider`。

**(B) 页面入口 —— 仅"可达性"依赖（删页即可解耦）**
- `mine_page`（push `CloudSyncPage`/`CloudServicePage`/`PiggyCountCloudSyncPage`）
- `ledgers_page_new`（push 共享账本相关页；watch `syncServiceProvider` 判断能力）
- `welcome_page`（push `CloudSyncPage`）、`home_page`（listen `sharedResourceRefreshProvider`）

**(C) 本地数据层 —— ⚠️ 最危险的耦合（非 Cloud 范畴却硬依赖 Cloud 文件）**
- `lib/data/repositories/local/local_repository.dart`：**无条件 import `cloud/sync/change_tracker.dart`**，持有 `ChangeTracker?` 字段，60+ 处调用 `changeTracker!.record*Change(...)`（全部 `if (changeTracker != null)` 守卫）。
- `lib/providers/database_providers.dart`：import `change_tracker`，仅 Cloud 后端激活时注入 `ChangeTracker(db)`。
- `lib/data/repositories/local/local_exchange_rate_repository.dart`：import `change_tracker`，持有 `ChangeTracker? Function()`。
- `lib/services/billing/post_processor.dart`：import `cloud/sync/sync_engine`，数据变更后自动上传。

**(D) 核心记账 UI —— ⚠️ 经共享账本信号间接依赖**
- `transfer_form`、`category_selector`、`category_selector_dialog`、`amount_editor_sheet`、`account_selector`、`home_page`、`tag_providers`、`database_providers` 均 `watch`/`listen` `sharedResourceRefreshProvider`（一个 `int` 型 `StateProvider`，仅作"重连/推送后强制 rebuild"的刷新信号）。
- `transfer_form`/`category_selector`/`category_selector_dialog`/`account_selector` 还 import `shared_ledger_providers` + `utils/shared_ledger_picker_filter`，并在 picker 中读取 `db.sharedLedger*`（共享账本镜像表）。`shared_ledger_picker_filter` 对"非共享/非 Editor"场景**优雅降级**到主表（`if (ctx == null || !ctx.isEditorInShared ...) return all;`），运行时不报错。

### 3.2 出站耦合（Cloud 依赖应用的什么）
Cloud 模块**不是"架在本地数据层之上"，而是深入本地数据与仓储层**：
- `lib/data/db.dart`（中央本地库）、`base_repository`、`transaction_repository`
- 共享加密服务接口 `lib/domain/encryption/encryption_service.dart`
- `lib/models/ledger_display_item.dart`、`lib/services/{data_import,system/logger,billing/post_processor,custom_icon,ui/avatar}_service`
- Providers：`database_providers`、`encryption_providers`、`statistics_providers`、`theme_providers` 及 Cloud 内部互相引用
- 外部包 `flutter_cloud_sync`（核心）、`flutter_cloud_sync_icloud` 等

### 3.3 共享 vs 专属逻辑——判定（本文核心结论）

| 类别 | 文件 | 删除 Cloud 时处理 |
|---|---|---|
| **❌ 专属，可一并删** | `lib/cloud/**`（22）、`lib/pages/cloud/**`（11）、`encrypted_cloud_*`（唯一链路） | 直接删，并清理 3.1 的入站引用 |
| **⚠️ 表面在 Cloud 目录、实为中性同步原语** | `cloud/sync/change_tracker.dart` | **不能随 Cloud 删**——`local_repository` 等无条件 import 它。需先**下沉**到中性模块（如 `lib/data/sync/change_tracker.dart`），再让仓储层依赖它。运行时已 `!= null` 守卫，行为天然可降级 |
| **⚠️ 概念专属但被核心 UI 硬引用** | `shared_ledger_providers` + `sharedResourceRefreshProvider` + `db.sharedLedger*` 表 + `shared_ledger_picker_filter` | 共享账本的多用户特性本属 Cloud，但核心记账组件热依赖其刷新信号与 picker。需把"刷新信号"抽成中性 `StateProvider`、把共享账本视为**独立 feature 模块**（自身按能力开关启用/降级），否则核心 UI 编译不过 |
| **✅ 全应用共享，绝不能删** | `aes_gcm_cipher`、`argon2_key_derivation`、`ciphertext_format`、`secure_key_storage`、`encryption_service_impl`、`domain/encryption/encryption_service.dart`、`providers/encryption_providers` | 被 `app_lock_service`（应用锁）与 `password_setup_dialog` 共用；Cloud 的 `encrypted_cloud_*` 只是其上的"传输加密装饰器" |

---

## 4. 可行性评估：删除 vs 改为通用组件

### 4.1 直接删除 —— 可行性：**不可干净删除**

即便语义上 Cloud 逻辑自洽，直接删会造成**编译级断链**（不止运行时）：
1. `local_repository` / `database_providers` / `local_exchange_rate_repository` 无条件 import `change_tracker` → 删后即编译失败。
2. `transfer_form` / 各 selector / `home_page` / `tag_providers` 热依赖 `sharedResourceRefreshProvider` 与 `shared_ledger_providers` → 删后即编译失败。
3. `app.dart` / `main.dart` 在启动同步、2FA、模式处硬接线 Cloud 服务 → 需加能力开关解耦。
4. `post_processor`、`ledger_card`、`profile_card` 直接依赖 `sync_providers` / `sync_engine` → 需注入式解耦。
5. 共享加密原语层必须保留（详见 3.3）。

> "删了会断功能"的根因不是 Cloud 逻辑本身不可替代，而是**两处中性基础设施（change_tracker、共享账本刷新信号）被错误地归类在 Cloud 目录并硬引用**。

### 4.2 改为通用组件（插件式后端）—— 可行性：**可行，且已有地基**

关键利好：**架构当前已具备抽象基础**。
- `lib/cloud/sync_service.dart` 定义了中性接口 `abstract class SyncService`，并已有默认回退 `LocalOnlySyncService`（未配置云时 `uploadCurrentLedger` 抛 `UnsupportedError`，`getStatus` 返回 `notConfigured`）。
- `syncServiceProvider` 已按"有 Cloud 配置→`SyncEngine`/`TransactionsSyncManager`，否则→`LocalOnlySyncService`"分支返回。
- `local_repository` 对 `changeTracker` 全部 `!= null` 守卫——**运行时已是 cloud-optional**。

**建议的泛化路径（分阶段）**：
1. **下沉中性同步原语**：把 `change_tracker.dart` 移到 `lib/data/sync/`，让仓储层依赖中性路径；Cloud 作为"可选后端"在激活时注入它。
2. **下沉共享账本信号**：把 `sharedResourceRefreshProvider`（int ticker）+ `shared_ledger_picker_filter` + `db.sharedLedger*` 表抽成独立 `lib/features/shared_ledger/` 模块；核心记账 UI 依赖该中性模块而非 Cloud。
3. **用 capability provider 解耦 app/main 硬接线**：`app.dart`/`main.dart` 改为监听"是否已配置同步后端"的能力标志，而非直接 import Cloud 类；启动同步、2FA 在无 Cloud 时静默降级。
4. **Cloud 仅保留"后端接入 + 端到端加密装饰 + Cloud 专属页面"**：`lib/cloud/**`、`lib/pages/cloud/**`、`encrypted_cloud_*` 成为可插拔的"PiggyCount Cloud 后端包"，未启用时不影响本地记账/应用锁/共享账本。

### 4.3 影响面与风险矩阵

| 耦合点 | 依赖类型 | 删除 Cloud 影响 | 泛化（下沉+解耦）后影响 |
|---|---|---|---|
| `local_repository` ↔ `change_tracker` | 硬编译（运行时守卫） | 编译失败 | 下沉后零影响 |
| 核心记账 UI ↔ `sharedResourceRefreshProvider` | 硬编译（信号型） | 编译失败 | 抽中性后零影响 |
| `app.dart`/`main.dart` ↔ Cloud 服务 | 硬接线 | 编译失败 | capability 解耦后零影响 |
| `post_processor`/`ledger_card`/`profile_card` ↔ `sync_engine`/`sync_providers` | 硬依赖 | 编译失败 | 注入式/能力标志解耦 |
| 加密原语层 | 共享 | 误删会断应用锁 | **保留**，与 Cloud 解耦 |
| `encrypted_cloud_*` | 专属单链 | 可删 | 归入 Cloud 后端包 |

---

## 5. 结论与建议

1. **"直接删除 Cloud"在当前结构下不可行**——会触发 `local_repository`、`database_providers`、`local_exchange_rate_repository`、以及 `transfer_form` 等核心记账组件的编译断链。根因是 `change_tracker` 与"共享账本刷新信号"两处中性基础设施被错误归类在 Cloud 目录并硬引用。
2. **"改为通用组件（插件式后端）"可行且方向正确**：架构已有 `SyncService` 接口 + `LocalOnlySyncService` 默认回退，`local_repository` 运行时已是 cloud-optional。只需补两处"中性基础设施下沉"（change_tracker、共享账本信号）并用 capability provider 解耦 `app.dart`/`main.dart`。
3. **两条铁律**：(a) 共享加密原语层（aes_gcm/argon2/ciphertext_format/secure_key_storage/encryption_service_impl）绝不可随 Cloud 删——它是应用锁与本地加密的共用底座；(b) Cloud 专属的 `encrypted_cloud_*` 是单链，删除无副作用，可整体归入"后端包"。
4. **建议推进顺序**：先可视化/冻结当前耦合图 → 下沉 change_tracker（最小风险，因运行时已守卫）→ 下沉共享账本信号与 picker filter → 以 capability provider 解耦 app/main → 最后将 `lib/cloud`、`lib/pages/cloud`、`encrypted_cloud_*` 收敛为可插拔 Cloud 后端模块。

（全文为只读调研，未创建或修改任何源代码文件。）
