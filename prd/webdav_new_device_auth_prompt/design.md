# WebDAV 新设备同步认证失败修复设计（webdav_new_device_auth_prompt）

## 总体思路

错误从底层到 UI 逐层保真传递：WebDAV 层识别 401/403 → `CloudAuthException` → `enableFromCloud` 包装为 `EnableFromCloudAuthException` → 恢复对话框按认证失败专门引导；同时恢复流程始终用**最新**的同步管理器探测，杜绝旧凭据残留。

## 模块设计

### M1 WebDAV 层认证错误识别（packages/flutter_cloud_sync_webdav）

- `WebDAVStorageService` 新增 `_isUnauthorized(Object e)`：优先读 dio 异常 `response.statusCode`（401/403），无结构化信息时字符串兜底（`401`/`403`/`unauthorized`）。与 `_isNotFound` 同款策略。
- `download` / `list` / `exists` / `getMetadata` / `upload` 捕获异常时先判 404（维持幂等语义），再判 401/403 → 抛 `CloudAuthException('WebDAV 认证失败（账号或密码错误）', e)`，其余维持 `CloudStorageException`。
- `WebDAVProvider.initialize` 的连接验证 `readDir` 失败分支：401/403 → 抛 `CloudAuthException`（外层仍会包装为 `CloudConfigurationException`，但 originalError 保留认证语义；`ensureInitialized` 抛出后调用方可通过异常链识别）。

### M2 enableFromCloud 认证语义透传（lib/data/encryption + lib/domain/encryption）

- `encryption_service.dart` 新增 `EnableFromCloudAuthException`：探测阶段认证失败（区别于密码错误 `ArgumentError`、探测失败 `EnableFromCloudProbeFailedException`、密文损坏）。
- `encryption_service_impl.enableFromCloud` 的两处探测 catch（list 失败 / download 失败）：先判 `CloudAuthException`（含异常链 `originalError`/message 匹配）→ 抛 `EnableFromCloudAuthException`；其余维持现状。

### M3 恢复流程使用最新管理器（lib/pages/cloud/encryption_dialogs.dart）

- `promptPasswordAndActivate` 移除 `syncManager` 参数；内部 `ref.read(syncServiceProvider)` 取当前服务，非 `TransactionsSyncManager` → 走既有 `saltMismatchRawStorageUnavailable` 错误分支。
- 激活成功后的 `reinitializeForEncryption` / `clearStatusCache` 均作用于**当前**管理器实例。
- 新增 `EnableFromCloudAuthException` 分支：弹确认对话框「WebDAV 账号或密码错误」+「去修改配置」按钮 → 跳转云服务页（`CloudServicePage`），返回 `SaltMismatchRecoveryResult.failed`。
- 调用方同步调整：`startup_sync_checker.dart` `WidgetRefDeps.handleSaltMismatch`、`cloud_sync_page.dart` `_handleEncryptionRecovery`（后者改为激活成功后对当前 sync 实例清缓存）。

### M4 启动检查器错误文案分类（lib/cloud/startup_sync_checker.dart）

- getStatus 循环内：`status.diff == SyncDiff.error` 且非哨兵 → 计入 `failedLedgers`（修复静默跳过可能误报「已是最新」，对齐 P1-3）。
- 汇总错误文案：`failedLedgers` 中 message 含 `CloudAuthException`/`401`/`403` 特征 → 「WebDAV 账号或密码错误，请到云服务页检查配置」；否则保留网络/超时提示。

## 数据流（修复后新设备场景）

```
新设备配置 WebDAV（含错误密码）
  → 启动检查 getStatus → 探测下载 401 → CloudAuthException
      路径 a（密文哨兵未触发）：error 状态计入 failedLedgers → 汇总提示认证错误
      路径 b（哨兵已触发）：弹加密密码框 → enableFromCloud → list/download 401
        → EnableFromCloudAuthException → 「账号或密码错误，去修改配置」→ 云服务页改密码
  → 用户改对密码 → provider 重建新管理器 → 再次同步/恢复
  → promptPasswordAndActivate 用最新管理器探测 → 成功提取 salt → 激活 → 同步恢复
```

## 实现步骤

1. M1：webdav 包 `_isUnauthorized` + 各方法抛 `CloudAuthException`（含 provider.initialize）。
2. M2：`EnableFromCloudAuthException` 定义 + `enableFromCloud` 两处探测 catch 分类。
3. M3：`promptPasswordAndActivate` 改签名、内部解析最新管理器、新增认证失败分支与跳转；调整 2 处调用方。
4. M4：启动检查器 error 状态计失败 + 汇总文案分类。
5. 验证：`flutter analyze`；新设备场景手工回归（错误密码 → 认证提示；正确密码 → 激活恢复）。

## 测试要点

- 单测（可行处）：`_isUnauthorized` 结构化/字符串两路判定；`enableFromCloud` 对 `CloudAuthException` 的包装。
- 手工回归：见 requirements 验收标准三条主路径。

## 遗留风险

- 部分 WebDAV 网关把 403 用于配额/封禁而非认证错误，文案会提示「账号或密码错误」——可接受（均需用户到配置页处理）。
- 启动检查器对非哨兵 error 状态改计失败后，瞬时错误也会弹汇总错误（原先静默）——符合 P1-3 设计意图，文案保留重试引导。
