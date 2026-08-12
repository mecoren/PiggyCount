# 同步代码全面审查修复 - 设计文档

## 一、关键技术决策

### 1.1 Supabase 实时状态机重构（C3/C4/C5/P-M3~P-M5/P-M10）

**问题**：当前实时连接状态完全不可信——构造时快照一次后永不更新、connect 永远返回 connected、subscribe 立即谎报已订阅。

**决策**：放弃自行维护 `_subscribed` 布尔标志，改为透传 Supabase SDK 的 `RealtimeChannel.status` 真实状态；通过每个 channel 的 `onStatus` 回调聚合反映服务级连接状态。

**理由**：
- SDK 的 `RealtimeSubscribeStatus` 枚举（subscribed/closed/timedOut/channelError/waiting）是状态唯一真实来源
- `onStatus` 回调在 socket 建立、断开、重连时均会触发，无需自行轮询
- 避免自行维护状态带来的"状态撒谎"问题

**关键改动**：
- `SupabaseRealtimeChannel.state` getter 直接映射 `_channel.status`
- `subscribe()` 不再设置 `_subscribed`，改为依赖 SDK 状态
- `connect()` 未连接时保持 `connecting`，由 channel `onStatus` 回调升级为 `connected`
- `unsubscribe()` 使用注入的 `SupabaseClient` 而非全局 `Supabase.instance`
- `removeChannel` 先 unsubscribe 成功后再从 map 移除
- `removeAllChannels` 每个 channel 单独捕获异常
- `dispose()` 先 `removeAllChannels` 再关 Controller

### 1.2 冲突检测逻辑修复（C1/C-M5）

**问题**：`_detectConflict` 在 `localVersion <= cloudVersion` 时返回 null（"无冲突"），导致 `syncRecord` 用本地旧数据覆盖云端新数据。

**决策**：调整冲突判定边界——仅当 `localVersion > cloudVersion`（本地确实更新）时返回 null（正常更新）；`localVersion < cloudVersion`（本地落后）时返回 `SyncConflict` 让策略决定；`localVersion == cloudVersion` 时回退到时间戳/内容比较。

**理由**：
- 乐观锁语义下，本地版本落后于云端意味着本地数据已过期，不应直接覆盖
- 让冲突解决策略（last-write-wins/remote-wins/manual）统一处理，而非在检测阶段静默放行

**关键改动**：
- `_detectConflict` 增加 `table` 参数，填充 `SyncConflict.table`
- `localVersion < cloudVersion` 返回 `SyncConflict`
- `manual` 策略增加可选回调 `onManualConflictResolve`

### 1.3 iCloud 原生安全与线程模型（C2/W-M6/W-M7/W-M8）

**问题**：路径遍历漏洞、下载未等待、主线程阻塞、containerURL 数据竞争。

**决策**：引入统一的 `safeURL(for:)` 方法做路径边界校验；下载后轮询 `ubiquitousItemDownloadingStatus` 直到 `.current`；所有 `FileManager` 阻塞 API 派发到后台队列；用 serial queue 保护 `containerURL` 读写。

**理由**：
- `appendingPathComponent` 不解析 `..`，必须用 `standardizedFileURL` + 前缀校验
- `startDownloadingUbiquitousItem` 是触发式异步 API，必须等待下载完成
- `url(forUbiquityContainerIdentifier:)` 首次调用可能阻塞主线程
- Swift 中普通 `var` 属性的并发读写是未定义行为

**关键改动**：
- 新增 `safeURL(for:) -> URL?` 方法，6 处路径拼接统一替换
- 新增 `downloadAndWaitIfNeeded(_:completion:)` 方法
- `isICloudAvailable`/`getAccountInfo` 派发到 `DispatchQueue.global(qos: .userInitiated)`
- `containerURL` 改为通过 `containerQueue.sync` 访问的私有属性

### 1.4 网络重试机制复用（S-M3/C-M1/C-M13）

**问题**：S3/Supabase/WebDAV 网络请求无重试；离线队列重试无退避；`RetryHelper` 用 `runtimeType` 无法匹配子类。

**决策**：S3 幂等操作（GET/HEAD/DELETE/List）包裹 `RetryHelper.execute`；离线队列使用 `RetryConfig.network`；`RetryHelper._shouldRetryException` 改用 `is` 检查（通过 `Type` 比较 + 父类遍历）。

**理由**：
- 项目已有 `RetryHelper` 和 `RetryConfig`（含指数退避），直接复用避免重复造轮
- `runtimeType` 返回精确运行时类型不匹配子类，违反替换原则
- PUT 操作非幂等不重试，避免重复写入

**关键改动**：
- S3 `_listObjectsV2Detailed`、`getObject`、`headObject`、`deleteObject` 包裹重试
- `processOfflineQueue` 的 `_executeOperation` 包裹 `RetryHelper.execute`
- `RetryHelper._shouldRetryException` 改为遍历继承链匹配

### 1.5 WebDAV 错误判断统一（W-M10/W-M2/W-M4）

**问题**：6 处依赖 `e.toString().contains('404')` 字符串匹配，不同服务器差异大。

**决策**：新增 `_isNotFound(Object e)` 助手方法，优先基于 `webdav.WebDavException.statusCode` 判断，字符串匹配仅作兜底；所有 404 判断统一调用该方法。

**理由**：
- `webdav_client` 包暴露了 `WebDavException` 含 `statusCode`，应优先使用结构化信息
- 字符串匹配在不同服务器（Nextcloud/ownCloud/群晖/坚果云）上不可靠

### 1.6 异常处理统一策略

**问题**：多处静默吞异常无日志、异常类型泄漏、强制解包。

**决策**：
- 所有 catch 块至少记录日志（使用项目 logger 或 `dev.log`）
- Supabase `AuthService` 所有方法捕获 `AuthException` 转换为 `CloudAuthException`
- `res.user!` 改为空判断 + 明确异常
- `file.path!` 改为安全回退
- S3 `S3PermissionDeniedException` 增加 `originalException` 参数

## 二、实现步骤

### 步骤 1：修复 Supabase 模块（18 个问题）

**文件**：`supabase_realtime_service.dart`、`supabase_database_service.dart`、`supabase_auth_service.dart`、`supabase_provider.dart`、`supabase_storage_service.dart`

**改动要点**：
1. 重构 `SupabaseRealtimeChannel`：移除 `_subscribed`，注入 `SupabaseClient`，`state` 映射 SDK 状态
2. 重构 `SupabaseRealtimeService`：`connect` 保持 connecting、channel `onStatus` 回调更新状态、`removeChannel`/`removeAllChannels` 错误隔离、`dispose` 先取消订阅
3. `SupabaseProvider.dispose`：调用 realtime dispose、重置静态字段、anonKey 改实例字段
4. `SupabaseDatabaseService`：`batchUpdate` 改用 RPC 事务、删除 `rawQuery` 裸 SQL（改 queryName + params）、合并 `insertBatch`/`batchInsert`、修复 limit+offset 双重分页
5. `SupabaseAuthService`：空判断替代 `res.user!`、捕获 `AuthException` 转 `CloudAuthException`
6. `SupabaseStorageService`：`_getMetadata`/`_deleteMetadata` 加日志、`getMetadata` 统一返回 null 语义
7. filter `split('=')` 改用 `indexOf` 切分并校验

### 步骤 2：修复 WebDAV + iCloud 模块（16 个问题）

**文件**：`webdav_storage_service.dart`、`webdav_provider.dart`、`icloud_auth_service.dart`、`icloud_provider.dart`、`ICloudManager.swift`、`FlutterCloudSyncIcloudPlugin.swift`

**改动要点**：
1. WebDAV：新增 `_isNotFound` 助手方法统一 404 判断、修复 `list` 返回相对路径、`getMetadata` 安全解包、`upload` 临时文件+MOVE 原子写、`initialize` 限定 404 才 mkdir、`dispose` 关闭 client
2. iCloud Dart：`_ensureInitialized` 改 Future 缓存消除竞态、`dispose` 调用 authService.dispose
3. iCloud 原生：新增 `safeURL(for:)` 方法 6 处替换、新增 `downloadAndWaitIfNeeded`、`isICloudAvailable`/`getAccountInfo` 后台队列、`containerURL` serial queue 保护、`ISO8601DateFormatter` 提升为属性、`listFiles` 加载 metadata、错误码契约统一 `NOT_FOUND`

### 步骤 3：修复 S3 模块（16 个问题）

**文件**：`s3_client.dart`、`s3_provider.dart`、`s3_storage_service.dart`、`s3_endpoint.dart`、`s3_exceptions.dart`、`s3_auth_service.dart`

**改动要点**：
1. `s3_client.dart`：XML 解析失败抛异常、`initialize` 前释放旧 client、幂等操作包裹 `RetryHelper`、移除死代码（`headObject` 不可达 rethrow、`_handleError` 后不可达 return）、`_handleError` 404 分支修正、`dispose` 增加 `_disposed` 标志
2. `s3_storage_service.dart`：`_buildKey` 拒绝 `..`、`downloadFile` 临时文件原子写、`getMetadata` 路径末尾斜杠处理
3. `s3_endpoint.dart`：端口范围校验（0-65535）
4. `s3_exceptions.dart`：`S3PermissionDeniedException` 增加 `originalException`
5. `s3_auth_service.dart`：提取 `_buildUser` 方法、修正 `isAuthenticated` 注释、移除未使用方法
6. `s3_provider.dart`：`initialize` 用 `maxKeys: 1` 测试连接

### 步骤 4：修复核心包与应用层（22 个问题）

**文件**：`database_sync_manager.dart`、`cloud_sync_manager.dart`、`cloud_service_config.dart`、`cloud_service_store.dart`、`provider_factory.dart`、`retry_helper.dart`、`auth_service.dart`、`sync_status.dart`、`database_service.dart`、`sync_providers.dart`、`tag_providers.dart`

**改动要点**：
1. `database_sync_manager.dart`：修复 `_detectConflict` 边界（`<` 返回冲突、增加 table 参数）、`_parseEventType` 未知返回 null、`subscribeToTable` 过滤器格式修正、`dispose` 改 async 先取消订阅、`manual` 策略增加回调、`processOfflineQueue` 包裹 `RetryHelper`
2. `cloud_sync_manager.dart`：metadata 合并顺序调整（用户值在前、保留字段在后）
3. `cloud_service_config.dart`：`fromJson` 用 `firstWhereOrNull` + 默认值、S3 `obfuscatedUrl` 统一脱敏
4. `cloud_service_store.dart`：所有 catch 加日志
5. `provider_factory.dart`：iCloud 分支加日志
6. `retry_helper.dart`：`_shouldRetryException` 改继承链遍历、文档说明只重试 Exception
7. `auth_service.dart`：`NoopAuthService.authStateChanges` 改广播流
8. `sync_status.dart`：`copyWith` 增加 sentinel 清空支持（可选，视调用方需求）
9. `database_service.dart`：`DatabaseEvent` 默认时间戳改 `DateTime.now()`
10. `sync_providers.dart`：`_autoSyncInProgress` 改按 config.id 跟踪、`authServiceProvider` 加日志、Profile Future 加 try-catch
11. `tag_providers.dart`：`batchTransactionTagsProvider` 加 `ref.watch(tagListRefreshProvider)`

### 步骤 5：验证

1. 运行 `flutter analyze` 确认无 error/warning
2. 逐模块核对修复点与问题清单一一对应
3. 检查新增复杂逻辑的中文注释
4. 确认未触碰排除范围内的文件

## 三、预期边界条件与潜在风险

### 3.1 高风险改动

| 改动 | 风险 | 缓解措施 |
|------|------|---------|
| `_detectConflict` 边界调整 | 原本"无冲突"的同步现在可能触发冲突解决，行为变化大 | 确保冲突解决策略（last-write-wins 默认）能正确处理新增的冲突场景 |
| `rawQuery` 签名变更 | 调用方需适配新签名（queryName + params） | 全局搜索调用方，逐一适配；若无调用方则直接删除 |
| Supabase 实时状态机重构 | channel `onStatus` 回调时序与预期不符 | 保留 `connecting` 中间态，避免状态跳跃 |
| iCloud `safeURL` 路径校验 | 现有合法路径被误拒 | 校验逻辑基于 `standardizedFileURL` + 前缀匹配，仅拒绝真正逃逸的路径 |
| WebDAV `list` 返回相对路径 | 下游依赖绝对路径的代码会 break | 全局搜索 `list()` 调用方，确认均通过 `_buildPath` 重新拼接 |

### 3.2 中风险改动

| 改动 | 风险 | 缓解措施 |
|------|------|---------|
| `batchUpdate` 改 RPC | 需要数据库侧有对应 RPC 函数 | 保留原循环实现作为 fallback，RPC 失败时回退并记录警告 |
| S3 幂等操作加重试 | 重试可能放大服务端负载 | 限制最大重试次数 3 次、指数退避（1s/2s/4s） |
| iCloud 原生线程模型调整 | serial queue 可能引入死锁 | 仅保护 `containerURL` 读写，不在锁内执行 IO |
| `processOfflineQueue` 加退避 | 队列处理变慢 | 退避仅针对失败操作，成功操作立即继续 |

### 3.3 低风险改动

- 死代码移除、注释修正、异常链补充、输入校验、格式化器复用——均为局部改动，不影响运行时行为
- `NoopAuthService` 改广播流——仅影响测试与本地模式，向后兼容
- `tag_providers` 加 watch——仅使 provider 在标签变更时刷新，符合预期

### 3.4 兼容性约束

1. **公开 API**：除 `rawQuery` 签名调整外，其余公开 API 签名不变
2. **iOS 部署版本**：Swift 改动不使用新 API，保持最低部署版本不变
3. **数据格式**：不改变本地存储与云端数据格式，无需迁移
4. **配置格式**：`CloudServiceConfig` JSON 格式不变，旧配置可正常解析（`firstWhereOrNull` + 默认值兼容未知枚举）

## 四、问题清单完整索引

详见同目录 `requirements.md` 中的分类与编号。所有 72 个问题均在本设计文档的"实现步骤"中有对应修复点。

### 编号映射

- **C1-C9**：Critical 问题（9 个）
- **S-M1~S-M3**：S3 Major 问题（3 个）
- **P-M1~P-M10**：Supabase Major 问题（10 个）
- **W-M1~W-M10**：WebDAV+iCloud Major 问题（10 个）
- **C-M1~C-M13**：核心+应用层 Major 问题（13 个）
- **Minor**：27 个，按类别在实现步骤中合并处理
