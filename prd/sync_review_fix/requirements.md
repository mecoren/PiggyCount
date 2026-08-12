# 同步代码全面审查修复 - 需求文档

## 一、需求理解

对 PiggyCount 项目中所有非 PiggyCount Cloud 的同步相关代码进行全面审查后，识别出 72 个潜在异常、错误或性能问题，需一次性全部修复，以提升同步机制的数据一致性、稳定性、安全性与可维护性。

## 二、修复范围

### 模块分布

| 模块 | 文件数 | Critical | Major | Minor | 小计 |
|------|--------|----------|-------|-------|------|
| S3 同步 | 8 | 0 | 3 | 13 | 16 |
| Supabase 同步 | 5 | 7 | 10 | 1 | 18 |
| WebDAV + iCloud 同步 | 9 | 1 | 10 | 5 | 16 |
| 核心包 + 应用层 | 12 | 1 | 13 | 8 | 22 |
| **合计** | **34** | **9** | **36** | **27** | **72** |

### 排除范围

明确排除以下 PiggyCount Cloud 同步模块：
- `lib/cloud/sync/` 目录及其所有子文件
- `lib/cloud/sync_service.dart`、`transactions_sync_manager.dart`、`startup_sync_checker.dart`、`startup_sync_overlay.dart`、`sync_diff_service.dart`、`sync_fingerprint.dart`、`transactions_json.dart`
- `packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart`

## 三、问题分类与修复目标

### 3.1 数据一致性（12 个问题）

- **C1**：`_detectConflict` 在本地版本低于云端时返回 null，导致旧数据覆盖新数据（最严重）
- **C6**：`batchUpdate` 逐条更新非原子，无 user_id 过滤
- **C-M2**：`_parseEventType` 未知事件默认归类为 insert
- **C-M3**：`subscribeToTable` 过滤器字符串拼接格式错误
- **C-M6**：`upload` 元数据合并顺序允许覆盖保留字段
- **S-M1**：XML 解析失败静默返回空列表
- **P-M2**：`insertBatch` 与 `batchInsert` 重复且不注入 user_id
- **P-M6**：limit+offset 双重分页
- **W-M3**：WebDAV `list` 返回的 CloudFile.path 错误
- **W-M5**：WebDAV `upload` 非原子写 + 元数据断裂
- **W-M6**：iCloud `downloadFile` 未等待云端下载完成
- **C-M5**：`manual` 冲突策略仅抛异常，无回调机制

**修复目标**：消除数据丢失、数据覆盖、数据重复风险，保证同步操作的原子性与一致性。

### 3.2 安全（4 个问题）

- **C2**：iCloud 原生路径遍历漏洞（`..` 可逃逸容器目录）
- **C7**：`rawQuery` SQL 注入面
- **P-M1**：静态字段长期保存 anonKey 不清理
- **P-M9**（合并到安全）：filter `split('=')` 无校验

**修复目标**：消除路径遍历、SQL 注入、凭证泄露等安全漏洞。

### 3.3 实时订阅与状态机（8 个问题）

- **C3**：实时连接状态仅构造时快照一次
- **C4**：`connect()` 永远返回 connected
- **C5**：`subscribe()` 立即标记 `_subscribed=true`
- **P-M3**：`removeChannel` 先移除再 unsubscribe
- **P-M4**：`removeAllChannels` 无错误隔离
- **P-M5**：`unsubscribe` 用全局 instance 而非注入 client
- **P-M10**：`RealtimeService.dispose` 不取消订阅
- **C-M4**：`database_sync_manager.dispose` 不取消订阅

**修复目标**：使实时连接状态真实反映底层 socket 状态，消除订阅泄漏。

### 3.4 资源管理与泄漏（9 个问题）

- **C8**：Supabase `dispose()` 不清理 realtime/静态状态
- **S-M2**：S3 `initialize` 重复调用未释放旧 client
- **W-M9**：`ICloudProvider.dispose` 未释放 authService
- **W-M8**：iCloud `containerURL` 数据竞争
- **C9**：`signIn`/`signUp` 强制解包 `res.user!`
- 以及多处 dispose 不完整、HTTP 连接未关闭

**修复目标**：保证所有资源（HTTP 连接、StreamController、WebSocket 订阅、原生句柄）在 dispose 时完整释放。

### 3.5 错误处理（15 个问题）

- 异常吞没（S3 XML、Supabase metadata、WebDAV 配置、iCloud 原生）
- 异常类型泄漏（Supabase AuthException 未包装）
- 强制解包（`res.user!`、`file.path!`）
- 脆弱错误判断（WebDAV 字符串匹配 404）

**修复目标**：统一异常处理策略，关键路径加日志，异常链完整保留。

### 3.6 网络可靠性（4 个问题）

- **S-M3**：S3 所有网络请求无重试机制
- **C-M1**：`processOfflineQueue` 重试无退避延迟
- **C-M13**：`RetryHelper` 用 `runtimeType` 比较无法匹配子类
- **W-M2**：WebDAV `initialize` readDir 失败回退过宽

**修复目标**：复用已有 `RetryHelper`，对幂等操作引入指数退避重试。

### 3.7 性能（5 个问题）

- **W-M7**：iCloud 主线程阻塞
- iCloud `ISO8601DateFormatter` 循环重复创建
- S3 `initialize` 全量 listObjects
- S3 大文件全量加载内存
- `NoopAuthService` 返回单订阅流

**修复目标**：消除主线程阻塞、不必要的 CPU/内存开销。

### 3.8 代码质量与设计（15 个问题）

- 死代码/不可达代码（S3 `headObject`、`_handleError` 后的 return）
- 异常信息丢失（`S3PermissionDeniedException` 无 originalException）
- 输入校验缺失（端口范围、路径末尾斜杠）
- 接口契约不一致（iCloud 错误码、`DatabaseEvent` 时间戳、S3 obfuscatedUrl）
- 状态管理（`tag_providers` 未 watch 刷新、全局 `_autoSyncInProgress`）
- 重复代码（`CloudUser` 重复构建、`insertBatch`/`batchInsert`）

**修复目标**：消除死代码与重复代码，统一接口契约，提升可维护性。

## 四、验收标准

1. `flutter analyze` 无 error、无 warning
2. 所有 72 个问题对应的代码位置均已修改
3. 修改不破坏现有接口契约（公开 API 签名不变，除非问题本身要求变更）
4. 新增的复杂逻辑（≥3 层嵌套或 >15 行）添加中文注释说明"为什么"
5. 所有代码标识符使用英文
6. 关键修复点附简要变更说明

## 五、约束条件

1. 不修改 PiggyCount Cloud 同步模块代码
2. 不主动提交 Git
3. 保持现有公开 API 兼容（除非问题修复本身要求变更，如 `rawQuery` 签名调整）
4. iOS 原生 Swift 代码修改需保证向后兼容（最低部署版本不变）
