# BeeCount 同步加密（E2EE）设计文档

> 版本：v1.0  日期：2026-07-27
> 范围：路径 A（S3 / WebDAV / Supabase / iCloud）快照同步
> 不在范围：路径 B（BeeCount Cloud 增量同步，保持不动）

---

## 1. 需求理解

为 BeeCount 的快照同步路径（4 个后端：S3 / WebDAV / Supabase / iCloud）增加端到端加密（E2EE），使云端只能看到密文，无法读取账本内容；用户只需记忆一个密码，多设备间通过相同密码即可解密彼此上传的数据。路径 B（BeeCount Cloud 增量同步）因服务端需做 LWW 合并、共享账本、实时推送，不在本次改造范围。

## 2. 现状分析

### 2.1 两条同步路径

| 路径 | 编排器 | 抽象 | 云端可见内容 | E2EE 适用性 |
|------|--------|------|--------------|-------------|
| A. 快照同步 | `TransactionsSyncManager` | `CloudProvider.storage.upload/download(String)` | 完整 JSON 明文 | ✓ 适用 |
| B. 增量同步 | `sync_engine.dart` | HTTP API（`pushChanges/pullChanges`） | payload 明文（需服务端合并） | ✗ 不适用 |

### 2.2 路径 A 的天然插入点

`TransactionsSyncManager._initialize()` 拿到 `CloudProvider` 之后、传给 `CloudSyncManager` 之前，是天然的装饰器插入点。所有 4 个后端都走 `CloudStorageService.upload/download(String data)`，签名统一。

### 2.3 关键澄清

- `lib/data/repositories/` 下不存在 `SyncRepository` 接口，统一抽象是 `CloudStorageService`（package 内）和 `SyncService`（app 内）
- `_provider!.storage.download/upload/list/delete` 在 `TransactionsSyncManager` 内被直接调用（不仅经由 `CloudSyncManager`），所以装饰器必须包装 `storage` 本身，而非 `CloudSyncManager`

## 3. 关键技术决策

### 3.1 装饰器位置：包装 `CloudProvider.storage`

```
CloudProvider (S3/WebDAV/Supabase/iCloud)
        ↓ wrap
EncryptedCloudProvider
  - storage → EncryptedCloudStorageService(inner.storage, crypto)
  - auth / providerId / initialize / validateConfig / dispose → 透传
        ↓
CloudSyncManager / TransactionsSyncManager
  (完全无感,upload/download 拿到的就是已加解密的 String)
```

**理由**：
- `CloudStorageService` 接口签名不变（6 个方法签名保持）
- `CloudProvider` 接口签名不变（7 个成员保持）
- `TransactionsSyncManager` 内部对 `storage.download/upload/list/delete` 的直接调用全部自动覆盖
- 4 个后端一次全部覆盖，无后端特化逻辑

### 3.2 加密算法：AES-256-GCM + Argon2id

| 用途 | 算法 | 包 | 理由 |
|------|------|-----|------|
| 对称加密 | AES-256-GCM | `cryptography: ^2.7.0` | 业界标准 AEAD，提供机密性 + 完整性；纯 Dart 实现全平台支持；自动走 BackgroundTransformer（Isolate） |
| 密钥派生 | Argon2id | `cryptography: ^2.7.0` | 抗 GPU/ASIC 离线爆破的现代 KDF；memory-hard |
| 密钥安全存储 | — | `flutter_secure_storage: ^9.2.2` | iOS Keychain / Android Keystore，平台级保护 |

### 3.3 密文格式：magic header + salt + payload

```
明文 (legacy)        : { "version": 6, "items": [...] }                      (无 magic)
密文 (encrypted)     : BEECRYPT1:<base64(salt(16))>:<base64(nonce(12) || ciphertext || mac(16))>
```

**设计要点**：
- **magic header `BEECRYPT1:`**：下载时按前缀自动识别密文/明文，向后兼容云端存量数据；未来算法升级走 `BEECRYPT2:`
- **salt 跟随密文存云端（明文，不保密）**：salt 的作用是防彩虹表 + 确保相同密码派生不同 key，本身不是秘密。多设备场景下 B 设备只需密码即可从密文头取 salt 派生 key 解密，无需额外同步机制
- **base64 编码**：保证密文可作字符串传输，与现有 `CloudStorageService.upload(String data)` 签名兼容

### 3.4 密钥与密码管理

| 项 | 存储位置 | key | 内容 |
|----|----------|-----|------|
| 加密密码（用户记忆） | 不存 | — | 只在输入时持有 |
| 256-bit 派生密钥 | flutter_secure_storage | `beecount_enc_key` | 日常加解密直接使用 |
| Argon2id salt | 跟随每条密文存云端 | — | 16B 随机，每次加密可重用或重生成 |
| 校验块（加密的已知明文） | flutter_secure_storage | `beecount_enc_verifier` | `encrypt("BEECOUNT_VERIFIER_v1")`，用于改密时验证旧密码 |
| 加密开关 | shared_preferences | `beecount_enc_enabled` | bool |

**verifier 块用途澄清**：
- 日常加解密：直接用 secure storage 里的 key，无需密码
- 修改密码/验证密码：用输入密码 + salt 派生临时 key → 尝试解 verifier → 成功即密码正确
- 新设备首次：secure storage 无 key → 用户输密码 → 从密文头取 salt → 派生 key → 解密成功后把 key 存入 secure storage

**密码不上云**：云端永远只有密文 + Argon2id 派生参数（salt 在密文头）。

### 3.5 Isolate 加解密

- AES-GCM：`cryptography` 包默认走 `BackgroundTransformer`（自带 Isolate），账本 JSON 通常 < 1MB 无需额外处理
- Argon2id：纯 Dart 实现较慢（~500ms-1s），用 `compute()` 单独跑避免阻塞 UI
- 大文件场景（>1MB）：加一道 `Isolate.run` 显式兜底

## 4. 实现步骤

### 步骤 1：Domain 层（接口与异常）

新增：
- `lib/domain/encryption/encryption_service.dart` — 抽象接口（`enable/disable/encrypt/decrypt/verifyPassword/changePassword/reset`）+ `DecryptionException`、`EncryptionNotConfiguredException`
- `lib/domain/encryption/encryption_settings.dart` — 配置 entity

### 步骤 2：Data 层（算法实现）

新增：
- `lib/data/encryption/ciphertext_format.dart` — magic header + base64 编解码 + 自动识别明文/密文
- `lib/data/encryption/aes_gcm_cipher.dart` — AES-256-GCM 加解密
- `lib/data/encryption/argon2_key_derivation.dart` — Argon2id KDF（含 Isolate 包装）
- `lib/data/encryption/secure_key_storage.dart` — `flutter_secure_storage` 封装
- `lib/data/encryption/encryption_service_impl.dart` — 实现 domain 接口

### 步骤 3：装饰器（核心接入点）

新增：
- `lib/data/encryption/encrypted_cloud_storage.dart` — `CloudStorageService` 装饰器
  - 重写：`upload`（加密 data）、`download`（按 magic 解密或透传）
  - 透传：`delete`、`list`、`exists`、`getMetadata`
- `lib/data/encryption/encrypted_cloud_provider.dart` — `CloudProvider` 装饰器
  - 重写：`storage` getter 返回 `EncryptedCloudStorageService`
  - 透传：`providerId`、`providerName`、`auth`、`initialize`、`validateConfig`、`dispose`

### 步骤 4：DI 与编排器接入

新增：
- `lib/providers/encryption_providers.dart` — Riverpod 注入

修改（约 13 行）：
- `lib/cloud/transactions_sync_manager.dart` — `_initialize()` 中拿到 `_provider` 后条件包装：
  ```dart
  if (encryptionEnabled) {
    _provider = EncryptedCloudProvider(_provider!, encryptionService);
  }
  ```
- `lib/providers/sync_providers.dart`（或 `lib/cloud/sync/sync_providers.dart`）— 构造 `TransactionsSyncManager` 时注入 `EncryptionService`

### 步骤 5：UI 与依赖

新增：
- `lib/pages/cloud/encryption_settings_page.dart` — 密码设置/修改/重置页
- `lib/widgets/encryption/password_setup_dialog.dart` — 密码输入对话框（含二次确认 + 强度提示）

修改：
- `pubspec.yaml` — 新增 `cryptography: ^2.7.0`、`flutter_secure_storage: ^9.2.2`
- `lib/pages/cloud/cloud_sync_page.dart` — 加「同步加密」开关 + 入口（~30 行）
- `lib/l10n/app_zh.arb` / `app_en.arb` — 新增加密相关文案 key

### 步骤 6：测试（与实现并行，TDD）

新增：
- `test/encryption/ciphertext_format_test.dart` — 格式编解码 + magic 识别 + legacy 明文兼容
- `test/encryption/encryption_service_test.dart` — 加解密正确性、错误密码、明文/密文自动识别、密码修改
- `test/encryption/encrypted_cloud_storage_test.dart` — 装饰器 upload/download/list/delete 行为

## 5. 关键流程

### 5.1 开启加密（首次设密码）

```
1. UI 收集 (password, confirmPassword)
2. encryptionService.enable(password)
   - 生成 salt(16B)
   - Argon2id(password, salt) → key(256bit)
   - 加密 "BEECOUNT_VERIFIER_v1" → verifier
   - 存 key + verifier 到 secure storage
   - shared_preferences.beecount_enc_enabled = true
3. 后续 upload 自动走密文格式
4. 云端存量明文会在下次 upload 时被覆盖为密文
```

### 5.2 修改密码

```
1. UI 收集 (oldPassword, newPassword, confirmPassword)
2. encryptionService.verifyPassword(oldPassword) → false 则提示
3. 暂停 TransactionsSyncManager（加状态锁，防止并发同步）
4. cloudStorage.list(path: '') → 列出所有 ledger_*.json
5. for each file:
     plaintext = cloudStorage.download(path)  // 走装饰器自动解密(用旧 key)
     encryptionService.activateKey(newPassword, salt=newSalt)  // 内存中切换
     cloudStorage.upload(path, plaintext)  // 走装饰器自动加密(用新 key)
6. encryptionService.persistNewPassword(newPassword)  // 写 secure storage
7. 恢复 TransactionsSyncManager
```

整个过程在 Isolate 中跑。

### 5.3 关闭加密

采用「**仅停止加密新上传，旧密文保留**」策略：
- `shared_preferences.beecount_enc_enabled = false`
- 后续 upload 走明文（原行为）
- 旧密文下载时仍靠 magic header 自动识别 + 解密（key 仍在 secure storage）

**边界提示**：若用户关闭后又用不同密码重新开启，旧密文将无法解密。UI 应明确提示，或在「重新开启」时检测到旧密文就走一次「旧密码解密 → 新密码加密」迁移（复用改密流程）。

### 5.4 忘记密码重置

```
1. UI 提示「重置将清空云端所有账本备份且不可恢复」
2. 用户二次确认
3. cloudStorage.list(path: '') → 列出所有 ledger_*.json
4. for each file: cloudStorage.delete(path)
5. secure_storage 删除 beecount_enc_key / beecount_enc_verifier
6. shared_preferences.beecount_enc_enabled = false
7. 引导用户重新设密码
```

## 6. 边界条件与潜在风险

| 场景 | 处理 |
|------|------|
| 云端有 legacy 明文 + 新密文混合 | 下载时按 magic header 自动识别，明文直接返回，密文走解密 |
| 解密失败（密码错 / GCM 验证失败） | 抛 `DecryptionException`，上层捕获后弹「密码错误」对话框，**不写本地 DB** |
| 用户忘记密码 | UI 提供「重置并清空云端」入口 |
| 加密/解密中途失败 | 不破坏本地 DB：上传失败→云端保持旧密文；下载失败→不调 `importTransactionsJson` |
| 开启加密后首次上传 | 自动覆盖旧明文为密文 |
| 关闭加密后重新开启（不同密码） | 旧密文无法解密，UI 提示走「重置」或「旧密码迁移」 |
| 改密期间并发同步 | 改密流程开始时暂停 `TransactionsSyncManager`，完成后再恢复 |
| 多设备 salt 一致性 | salt 在密文头，B 设备下载后自动取用，无需额外同步 |
| iCloud 文件大小限制 | 加密后体积增长 < 30%（base64 + overhead），仍在 iCloud 限制内 |
| Dart String 不可归零 | 已知限制，密钥在内存中无法主动清零；通过缩短内存驻留时间缓解 |
| 用户丢失设备 + 忘记密码 | 数据不可恢复（E2EE 本质），UI 须明确告知 |

## 7. 文件清单

### 新增文件（13 个）

**Domain 层**
- `lib/domain/encryption/encryption_service.dart`
- `lib/domain/encryption/encryption_settings.dart`

**Data 层**
- `lib/data/encryption/ciphertext_format.dart`
- `lib/data/encryption/aes_gcm_cipher.dart`
- `lib/data/encryption/argon2_key_derivation.dart`
- `lib/data/encryption/secure_key_storage.dart`
- `lib/data/encryption/encryption_service_impl.dart`
- `lib/data/encryption/encrypted_cloud_storage.dart`
- `lib/data/encryption/encrypted_cloud_provider.dart`

**Providers**
- `lib/providers/encryption_providers.dart`

**UI**
- `lib/pages/cloud/encryption_settings_page.dart`
- `lib/widgets/encryption/password_setup_dialog.dart`

**测试**
- `test/encryption/ciphertext_format_test.dart`
- `test/encryption/encryption_service_test.dart`
- `test/encryption/encrypted_cloud_storage_test.dart`

### 修改文件（5 个）

- `pubspec.yaml` — 新增依赖
- `lib/cloud/transactions_sync_manager.dart` — `_initialize()` 条件包装（~10 行）
- `lib/providers/sync_providers.dart` — 注入 `EncryptionService`（~3 行）
- `lib/pages/cloud/cloud_sync_page.dart` — 加开关 + 入口（~30 行）
- `lib/l10n/app_zh.arb` / `app_en.arb` — 新增文案 key

### 新增依赖

```yaml
cryptography: ^2.7.0          # AES-256-GCM + Argon2id (pure Dart, 全平台)
flutter_secure_storage: ^9.2.2 # 密钥安全存储 (iOS Keychain / Android Keystore)
```

## 8. 不在本次范围

- 路径 B（BeeCount Cloud）加密：服务端需读 payload 做 LWW 合并，架构性约束
- 附件文件加密：附件走独立上传通道，本次仅覆盖账本 JSON
- 密钥导出/导入：用户跨设备迁移仅靠密码 + 云端密文头 salt
