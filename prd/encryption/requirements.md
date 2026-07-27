# BeeCount 同步加密（E2EE）需求文档

> 版本：v1.0  日期：2026-07-27
> 关联设计：`/prd/encryption/design.md`

---

## 1. 背景与目标

### 1.1 背景

BeeCount 当前的快照同步路径（S3 / WebDAV / Supabase / iCloud）将账本 JSON 以明文形式存储在云端。用户对云端存储敏感财务数据的隐私顾虑成为采用的障碍。

### 1.2 目标

- **机密性**：云端只能看到密文，无法读取账本内容
- **端到端**：密钥仅存在于用户设备，服务端无法解密
- **多设备友好**：用户只需记忆一个密码即可在多设备间同步
- **向后兼容**：不破坏云端存量明文数据，支持明文/密文混合状态
- **零侵入**：不修改 `CloudStorageService` / `CloudProvider` / `SyncService` 接口签名

### 1.3 非目标

- 不覆盖路径 B（BeeCount Cloud 增量同步）
- 不加密附件文件
- 不提供密钥导出/导入功能

## 2. 用户故事

### US-1：首次开启加密

**作为**一个注重隐私的 BeeCount 用户，
**我希望**在同步设置里开启端到端加密并设置一个密码，
**以便**我上传到云端的账本数据无法被服务提供商读取。

**验收标准**：
- 在 `cloud_sync_page` 可见「同步加密」开关
- 首次开启时弹密码设置对话框，需输入密码 + 二次确认
- 密码强度有可视化提示（长度 ≥ 8、含字母数字等）
- 开启后所有后续上传自动转为密文格式
- 开启后立即触发一次全量上传，覆盖云端存量明文
- 开启后下载云端明文仍可正确识别和读取（向后兼容）

### US-2：多设备解密

**作为**已在 A 设备开启加密的用户，
**我希望**在 B 设备输入相同密码即可解密云端数据，
**以便**无缝跨设备同步。

**验收标准**：
- B 设备首次解密时弹出密码输入对话框
- 输入正确密码后，所有账本可正常下载和读取
- 解密成功后密钥缓存到 B 设备 secure storage，后续无需重复输入
- 输入错误密码时明确提示「密码错误」，不写入本地 DB

### US-3：修改密码

**作为**已开启加密的用户，
**我希望**修改加密密码，
**以便**定期更换密码提升安全性。

**验收标准**：
- 在加密设置页提供「修改密码」入口
- 需先验证旧密码，再输入新密码 + 二次确认
- 修改过程中自动重新加密云端所有 `ledger_*.json` 文件
- 修改过程中暂停同步任务，防止并发冲突
- 修改完成后恢复同步
- 修改失败时云端保持旧密文，不破坏数据

### US-4：关闭加密

**作为**已开启加密的用户，
**我希望**能关闭加密，
**以便**在不需要时回到明文同步。

**验收标准**：
- 关闭开关后立即停止对新上传内容加密
- 云端存量密文保留，下载时靠 magic header 自动解密（key 仍在 secure storage）
- 关闭后重新开启时，若密码与之前相同，旧密文仍可解密
- 关闭后重新开启时，若密码不同，UI 明确提示旧密文将无法解密

### US-5：忘记密码重置

**作为**忘记加密密码的用户，
**我希望**能重置加密并清空云端备份，
**以便**重新开始使用同步功能。

**验收标准**：
- 在加密设置页提供「重置加密」入口
- 重置前必须二次确认，明确告知「将清空云端所有账本备份且不可恢复」
- 重置操作：删除云端所有 `ledger_*.json` → 清除 secure storage → 关闭加密开关
- 重置后引导用户重新设密码
- 本地 DB 不受影响

### US-6：解密失败处理

**作为**用户，
**当**下载的数据无法解密时，
**我希望**得到清晰的错误提示，
**以便**我知道如何处理（重输密码或重置）。

**验收标准**：
- 解密失败时弹出错误对话框，明确提示「密码错误或数据损坏」
- 不写入本地 DB
- 对话框提供两个选项：「重输密码」、「重置加密」

## 3. 功能需求

### FR-1：加密服务接口

提供抽象接口 `EncryptionService`，包含：
- `Future<bool> isEnabled` — 加密是否开启
- `Future<void> enable(String password)` — 开启加密
- `Future<void> disable()` — 关闭加密
- `Future<bool> verifyPassword(String password)` — 验证密码
- `Future<void> changePassword(String oldPassword, String newPassword)` — 修改密码
- `Future<void> reset()` — 重置（清空密钥和云端数据）
- `Future<String?> encrypt(String plaintext)` — 加密（未开启返回原文）
- `Future<String?> decrypt(String ciphertext)` — 解密（识别明文/密文）

### FR-2：密文格式

- 密文必须以 `BEECRYPT1:` 开头作为 magic header
- 格式：`BEECRYPT1:<base64(salt(16))>:<base64(nonce(12) || ciphertext || mac(16))>`
- 下载时按 magic header 自动识别密文/明文
- 明文（无 magic header）原样返回，保证向后兼容

### FR-3：装饰器

- `EncryptedCloudStorageService` 实现 `CloudStorageService` 接口（6 个方法）
  - 重写 `upload`：加密 `data` 后调用内部 storage
  - 重写 `download`：调用内部 storage 后按 magic 解密
  - 透传 `delete`、`list`、`exists`、`getMetadata`
- `EncryptedCloudProvider` 实现 `CloudProvider` 接口（7 个成员）
  - 重写 `storage` getter 返回 `EncryptedCloudStorageService`
  - 透传 `providerId`、`providerName`、`auth`、`initialize`、`validateConfig`、`dispose`

### FR-4：编排器接入

- `TransactionsSyncManager._initialize()` 在拿到 `CloudProvider` 后、传给 `CloudSyncManager` 前，按 `encryptionEnabled` 条件包装
- 包装对 `CloudSyncManager` 和 `TransactionsSyncManager` 内部直接调用 `_provider.storage.*` 完全透明

### FR-5：UI 集成

- 在 `cloud_sync_page` 现有同步设置区域增加「同步加密」开关
- 提供「修改密码」、「重置加密」入口
- 首次开启加密弹密码设置对话框（密码 + 二次确认 + 强度提示）
- 解密失败弹错误对话框，提供「重输密码」和「重置加密」选项

## 4. 非功能需求

### NFR-1：安全性

- 使用 AES-256-GCM 对称加密（提供机密性 + 完整性）
- 使用 Argon2id 派生密钥（memory-hard，抗 GPU/ASIC 爆破）
- 密钥仅存储在平台 secure storage（iOS Keychain / Android Keystore）
- 密码不上云
- salt 可上云（salt 不是秘密，跟随密文头存储）

### NFR-2：性能

- AES-GCM 加解密通过 Isolate 执行，不阻塞 UI
- Argon2id 派生通过 `compute()` 执行，避免 UI 卡顿
- 单次加解密延迟 < 200ms（账本 < 1MB 场景）

### NFR-3：兼容性

- 不破坏 `CloudStorageService` / `CloudProvider` / `SyncService` 接口
- 不破坏云端存量明文数据
- 支持明文/密文混合状态
- 4 个后端（S3 / WebDAV / Supabase / iCloud）一次全部覆盖

### NFR-4：可测试性

- 加解密逻辑可独立测试（不依赖真实云存储）
- 装饰器可注入 mock 内部 storage 测试
- 密文格式编解码可单元测试

## 5. 测试需求

### 5.1 单元测试

- `ciphertext_format_test`：
  - 密文格式编解码正确性
  - magic header 识别
  - legacy 明文（无 magic）原样返回
  - 异常输入处理（空字符串、格式错误）

- `encryption_service_test`：
  - 加解密正确性（encrypt → decrypt 还原原文）
  - 错误密码解密失败
  - 明文/密文自动识别
  - 密码修改流程
  - enable / disable / reset 流程

- `encrypted_cloud_storage_test`：
  - upload 时 data 被加密
  - download 时按 magic 解密
  - download legacy 明文原样返回
  - delete / list / exists / getMetadata 透传

### 5.2 集成测试（可选）

- 完整流程：开启加密 → 上传 → 下载 → 解密 → 数据一致
- 多设备模拟：A 设备加密上传 → B 设备密码解密

## 6. 依赖

### 新增依赖

```yaml
cryptography: ^2.7.0          # AES-256-GCM + Argon2id (pure Dart, 全平台)
flutter_secure_storage: ^9.2.2 # 密钥安全存储 (iOS Keychain / Android Keystore)
```

### 平台配置

- iOS：`flutter_secure_storage` 自动使用 Keychain，无需额外配置
- Android：`flutter_secure_storage` 自动使用 Keystore，需在 `android/app/build.gradle` 确认 minSdkVersion ≥ 18（项目已满足）

## 7. 风险与缓解

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| 用户忘记密码导致数据永久丢失 | 高 | UI 明确告知风险 + 提供「重置并清空云端」入口 |
| 改密期间并发同步导致状态不一致 | 中 | 改密流程开始时暂停 `TransactionsSyncManager` |
| 关闭后用不同密码重新开启，旧密文无法解密 | 中 | UI 明确提示 + 提供「旧密码迁移」流程 |
| Argon2id 在低端设备派生较慢 | 低 | 用 `compute()` 在 Isolate 执行，UI 显示进度 |
| Dart String 不可归零，密钥可能被内存转储 | 低 | 已知限制，缩短内存驻留时间缓解 |
| iCloud 文件大小限制 | 低 | 加密后体积增长 < 30%，仍在限制内 |

## 8. 验收检查清单

- [ ] 单元测试覆盖率达 90%+（加密相关模块）
- [ ] 4 个后端（S3 / WebDAV / Supabase / iCloud）均验证加密生效
- [ ] 云端存量明文可正常下载和读取
- [ ] 多设备密码解密流程通过
- [ ] 修改密码流程通过（含并发暂停）
- [ ] 关闭加密后旧密文仍可解密
- [ ] 忘记密码重置流程通过
- [ ] 解密失败错误处理正确
- [ ] UI 文案中英文齐全（`app_zh.arb` / `app_en.arb`）
- [ ] `CloudStorageService` / `CloudProvider` / `SyncService` 接口签名未变
