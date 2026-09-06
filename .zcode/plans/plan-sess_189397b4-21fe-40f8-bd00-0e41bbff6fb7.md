# 去除 PiggyCountCloud 同步功能（保留 S3/WebDAV）

## 背景结论

PiggyCountCloud（路径 B 实时协同）当前已被 `kPiggyCountCloudEnabled = false` 运行时禁用，本次工作是**删除已死代码**，用户可见行为不变。它与 S3/WebDAV 架构上完全隔离：S3/WebDAV 走 `TransactionsSyncManager`（快照同步，基于通用 `CloudProvider` 接口）；PiggyCountCloud 走 `SyncEngine`（硬编码具体类）。共享账本/邀请/成员/设备/2FA/实时通道全部是 PiggyCountCloud 独占。

**必须保留的共享设施**（已逐一验证）：
- `change_tracker.dart` + `local_changes` 表：Path A 上传成功后调用 `markSnapshotPushed`，`_localChangeEvidence` 冲突检测直接查该表（v41 迁移测试正在维护它）
- `transactions_sync_manager.dart`、`transactions_json.dart`、`startup_sync_checker/overlay.dart`、`sync_fingerprint`、`sync_diff_service`、备份/加密全链路
- `sharedResourceRefreshProvider`（定义在 shared_ledger_providers.dart 但被 15+ 个 Path A widget watch）→ 迁移到 `lib/providers/sync_providers.dart` 保留
- `shared_ledger_picker_filter.dart` 的 `syntheticIdForSyncId` + `accountForTxProvider` 的 SharedLedgerAccounts 反查（历史数据仍能显示账户名）
- `login_page.dart` 的 Supabase 分支、`authServiceProvider`（Supabase 登录仍需要）
- 数据库 schema：**不迁移**，保留 SharedLedger* 表和 isShared/myRole 等列（默认值保证行为单用户化），数据驱动的只读 UI（ledger_card 徽章等）不动

## 实施步骤

### 第 0 步：隔离在途改动
工作区有 24 个文件未提交（S3/WebDAV 条件写优化、v41 迁移测试、l10n 生成物）。先 `git add -A && git commit` 提交为一个独立 commit，避免与本次删除混淆。

### 第 1 步：核心包 packages/flutter_cloud_sync
- **删** `src/providers/piggycount_cloud_provider.dart`（5012 行，唯一内容，含 WS 客户端/2FA/成员/邀请 API）；删 `flutter_cloud_sync.dart` 的 export 行
- **改** `src/config/cloud_service_config.dart`：删 `CloudBackendType.piggycountCloud` 枚举值、4 个配置字段、valid/obfuscatedUrl/序列化分支
- **改** `src/config/cloud_service_store.dart`：删 `_kPiggyCountCloudCfg`、`loadPiggyCountCloud()`、saveAndActivate/saveOnly/activate 的 piggycountCloud 分支。**存量兼容关键**：loadActive 里 `case 'piggycount_cloud'` 删除后由 `default → localStorage` 兜底，老用户激活标记自动回退本地模式；secure storage 残留配置不再读取，无害
- **改** `pubspec.yaml`：删 `http`、`web_socket_channel`、`crypto`、`device_info_plus`、`package_info_plus`（已 grep 确认仅 piggycount 文件使用）及 dev 的 `stream_channel`
- **删测试**：`test/piggycount_*.dart` ×6、`test/providers/piggycount_realtime_client_test.dart`，修剪 `cloud_service_config_valid_test.dart`、`cloud_service_store_test.dart` 中的 piggycount 用例
- S3/WebDAV/Supabase/iCloud 四个兄弟包**零改动**

### 第 2 步：主工程 lib/cloud
- **删** `lib/cloud/sync/` 下 10 个文件：sync_engine.dart + 9 个 part、sync_coordinator.dart、sync_conflict_resolver.dart、sync_events.dart、entity_serializer.dart、sync_providers.dart（整个目录只剩 change_tracker.dart）
- **删** `lib/cloud/cloud_feature_flags.dart`（仅含这一个 flag）
- **改** `provider_factory.dart`：删 piggycountCloud case + import
- **改** `startup_sync_checker.dart:1089`：删 `_isPathA` 的 piggycountCloud case

### 第 3 步：providers 层
- **删** `lib/providers/shared_ledger_providers.dart` 全部 API wrapper；**保留** `sharedResourceRefreshProvider` 定义迁入 `lib/providers/sync_providers.dart`
- **改** `lib/providers/sync_providers.dart`：删 `piggycountCloudProviderInstance`、`piggycountCloudServerVersionProvider`、`reconcileProfileToServer`、`cloudMyProfileProvider`、`remoteLedgersProvider`、SyncEngine 分支（syncServiceProvider 收敛为 TransactionsSyncManager/LocalOnly 二态）、服务端主题/汇率/AI 配置回写监听；保留 authServiceProvider（Supabase）、TransactionsSyncManager 构建、syncGenerationProvider
- **改** `database_providers.dart`：repositoryProvider 的 tracker 注入条件永假 → 直接 `LocalRepository(db)`（changeTracker 参数保留，Path A 的 `repo.changeTracker` 调用点 null 安全）
- **改** `theme_providers.dart`、`currency_providers.dart`：删推送主题/币种到云分支；汇率 server 代理分支删除后直接走公网 fallback（与现状 flag=false 行为一致）
- **删** `lib/services/data/tx_author_service.dart` 及 transaction_editor_page/transfer_form 调用点（createdByUserId 列保留）

### 第 4 步：UI 层
- **删 7 个页面/组件**：piggycount_cloud_sync_page、invite_page、member_list_page、member_stats_page、devices_page、join_shared_ledger_page、login_2fa_challenge_view
- **改** `cloud_service_page.dart`：删「云端协同」tab（三 tab 变两 tab）、配置对话框、帮助对话框、连接测试分支
- **改** `mine_page.dart`：同步状态路由收敛为 CloudSyncPage
- **改** `ledgers_page_new.dart`：删「加入共享账本」按钮、成员/成员统计菜单项；`is SyncEngine` 分支收敛为 TransactionsSyncManager
- **改** `login_page.dart`：删 piggycountCloud 凭据分支（**保留 Supabase 分支**）、_registerDocTopic case
- **改** `profile_card.dart`（删头像上传）、`amount_editor_sheet.dart`（删 tx 作者头像）

### 第 5 步：启动接线
- **改** `main.dart`：删账户去重 ChangeTracker 注入（143-146）、2FA handler 注册（174-184）
- **改** `app.dart`：删 piggycountCloudProviderInstance await、`is SyncEngine` 分发、`_triggerInitialCloudSync`、SyncEngine 事件监听
- **改** `services/export/config_export_service.dart`：删 PiggyCountCloudConfig 类及序列化分支（旧 YAML 的 piggycount_cloud 段解析时自然忽略）

### 第 6 步：l10n
4 个 arb 文件删除 PiggyCountCloud 专属 key（cloudPiggyCountCloud*、cloudTutorial*、cloudRelogin*、cloudCollab*、twofa*、shared*、syncHealth*、cloudSyncHelp*、cloudTabCloudSync），**逐 key grep 引用确认后再删**（shared* 前缀可能有跨场景复用）；跑 `flutter gen-l10n` 重新生成。

### 第 7 步：测试清理
- **删** `test/cloud/sync/` 整个目录（18 文件 + fakes）、`test/sync/` 3 个 apply 测试
- **逐个检查** `test/cloud/` 散点（sync_apply_no_local_changes、attachment_sync、sync_interruption_stress 等）：引用 PiggyCountCloud 类型的删，纯 Path A 的留
- 保留全部 S3/WebDAV/startup_sync_checker/encryption/manager 测试

### 第 8 步：验证闭环
1. `flutter pub get` → `flutter analyze` 零 error（编译器会指出所有遗漏的枚举 case / import，逐一清理）
2. `flutter test`（主工程 + flutter_cloud_sync 包），S3/WebDAV 既有测试全绿
3. grep 终检：`lib/`、`packages/*/lib/` 中 PiggyCountCloud 类型引用清零（历史性注释除外）
4. 提交为单个 commit：`feat(remove): 下线 PiggyCountCloud 实时协同，保留 S3/WebDAV 快照同步`

## 关键风险控制
- **存量用户**：激活类型 'piggycount_cloud' 由 loadActive default 分支回退本地模式，安全
- **Path A 行为不变**：tracker 当前已恒为 null（flag=false），删除后 local_changes 表无新写入、_localChangeEvidence 行为一致；v41 清理迁移继续消化存量行
- **共享账本历史数据**：表和只读展示保留，历史交易的账户/分类名仍可显示

预计删除 50+ 文件、修改 30+ 文件，净减约 1.5 万行。