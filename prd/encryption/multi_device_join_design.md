# PiggyCount 同步加密 - 多设备加入流程 设计文档

> 版本：v1.0  日期：2026-07-27
> 范围：路径 A（S3 / WebDAV / Supabase / iCloud）快照同步
> 关联需求：`/prd/encryption/multi_device_join_requirements.md`
> 补充于：`/prd/encryption/design.md`（原始 E2EE 设计）的 3.4 / 5.1 节

---

## 1. 需求理解

原始 E2EE 设计文档 3.4 节明确规定："新设备首次：secure storage 无 key → 用户输密码 → **从密文头取 salt** → 派生 key → 解密成功后把 key 存入 secure storage"。但 `EncryptionServiceImpl.enable(password)` 实现时偏离了设计，总是生成新 salt，导致设备 B 用相同密码也无法解密设备 A 加密的云端数据。

本次改造补齐设计文档原本规定的新设备加入路径，不引入新机制，只是把漏掉的实现补回来。

## 2. 现状分析

### 2.1 当前 enable 流程的问题

[encryption_service_impl.dart:70-97](../../lib/data/encryption/encryption_service_impl.dart#L70-L97)：

```dart
Future<void> enable({required String password}) async {
  _validatePassword(password);
  final salt = await Argon2KeyDerivation.generateSalt();  // ← 总是生成新的
  final key = await keyDerivation.deriveKey(password: password, salt: salt);
  final verifier = await cipher.encrypt(...);
  await storage.saveKey(key);
  await storage.saveSalt(salt);
  await storage.saveVerifier(verifier);
  _activeKey = key;
  _activeSalt = salt;
  await prefs.setBool(_enabledKey, true);
}
```

问题：`enable` 既不知道云端有没有密文，也没有 `CloudStorageService` 入参，无法提取云端 salt。

### 2.2 现有可复用的原语

| 原语 | 位置 | 用途 |
|------|------|------|
| `CiphertextFormat.decode` | [ciphertext_format.dart:63](../../lib/data/encryption/ciphertext_format.dart#L63) | 从密文解析出 salt + encryptedBytes |
| `CiphertextFormat.isEncrypted` | [ciphertext_format.dart:27](../../lib/data/encryption/ciphertext_format.dart#L27) | 判断字符串是否为 BEECRYPT1 密文 |
| `Argon2KeyDerivation.deriveKey` | argon2_key_derivation.dart | password + salt → key |
| `AesGcmCipher.decrypt` | [aes_gcm_cipher.dart:62](../../lib/data/encryption/aes_gcm_cipher.dart#L62) | 解密 nonce‖ct‖mac，GCM 验证失败抛 `SecretBoxAuthenticationError` |
| `SecureKeyStorage.saveKey/saveSalt/saveVerifier` | [secure_key_storage.dart](../../lib/data/encryption/secure_key_storage.dart) | 持久化到 Keychain/Keystore |

无需新增算法原语，只需在 `EncryptionServiceImpl` 中编排这些已有原语。

### 2.3 TransactionsSyncManager 的 raw storage 访问

[transactions_sync_manager.dart:110-139](../../lib/cloud/transactions_sync_manager.dart#L110-L139) 的 `reEncryptCloudAndReinit` 已经展示了"取未装饰的 raw storage"模式：

```dart
final rawStorage = _provider?.storage;
```

但 `_provider` 是私有的，UI 层无法直接访问。需要 `TransactionsSyncManager` 暴露一个公开方法或 getter，或者在 `EncryptionServiceImpl.enableFromCloud` 中由 UI 层传入 `CloudStorageService` 实例。

## 3. 关键技术决策

### 3.1 方案选择：从密文头提取 salt（不引入独立 salt 文件）

**决策**：采用原始设计文档的方案——从云端密文头提取 salt，**不**新增独立的 salt 文件。

**对比方案 B（独立 salt 文件 `beecrypt_salt.bin`）**：

| 维度 | 方案 A（从密文头取） | 方案 B（独立 salt 文件） |
|------|---------------------|------------------------|
| 云端文件数 | 不变 | +1 |
| 与原始设计一致性 | ✓ 完全一致 | ✗ 偏离设计 3.4/6/8 |
| 改密后状态管理 | 自动跟随密文 | 需额外同步更新 salt 文件，否则与密文头不一致 |
| 实现复杂度 | 中（需下载一个密文） | 低（直接下载 salt 文件） |
| salt 文件丢失风险 | 无（salt 在每条密文里） | 有（salt 文件损坏/误删则多设备流程失效） |
| 4 后端兼容性 | 无新代码 | 需确认 4 后端都能正确上传/下载 salt 文件 |

**结论**：方案 A 更符合原始设计，无额外状态管理负担，无新单点故障。方案 B 的"简单"是表象，长期维护成本更高。

### 3.2 接口设计：新增 enableFromCloud，不改 enable 签名

**决策**：在 `EncryptionService` 抽象接口新增 `enableFromCloud` 方法，保持 `enable` 签名不变。

```dart
abstract class EncryptionService {
  // 现有方法签名全部不变
  Future<void> enable({required String password});
  
  // 新增：新设备加入流程
  /// 从云端已有密文提取 salt，配合用户密码派生 key 并验证。
  /// 若云端无 BEECRYPT1 密文，回退到 [enable] 逻辑（首设备场景）。
  /// 
  /// 抛出：
  /// - [ArgumentError]：密码错误（GCM 验证失败）或密码无效
  /// - 网络/云存储异常：透传
  Future<void> enableFromCloud({
    required String password,
    required CloudStorageService cloudStorage,
  });
  
  // ... 其他方法不变
}
```

**理由**：
- `enable` 现有调用方（测试、潜在的其他入口）不受影响
- `enableFromCloud` 内部在"无密文"时复用 `enable` 逻辑，避免重复代码
- UI 层只需把"设置密码"按钮的调用从 `enable` 改为 `enableFromCloud`，由方法内部自动判断场景

### 3.3 UI 层 raw storage 获取

**决策**：在 `TransactionsSyncManager` 新增公开 getter `rawStorage`，返回未装饰的 `CloudStorageService?`。

```dart
class TransactionsSyncManager implements SyncService {
  /// 当前未装饰的 raw storage（用于 enableFromCloud 探测云端密文）
  /// 调用前应先触发 _ensureInitialized（UI 层通过任意 sync 调用预热）
  CloudStorageService? get rawStorage {
    if (_provider == null) return null;
    // _provider 可能是 EncryptedCloudProvider，需要取 inner.storage
    // 但 enableFromCloud 需要的是"能下载原始密文字符串"的 storage
    // EncryptedCloudStorageService.download 会自动调 decrypt，
    // 而 enableFromCloud 需要的是密文本身 → 必须取 inner.storage
    ...
  }
}
```

**关键澄清**：`enableFromCloud` 需要下载**密文字符串**（`BEECRYPT1:...`）来提取 salt。如果传入的是 `EncryptedCloudStorageService`，它的 `download` 会自动 decrypt 返回明文，无法提取 salt。因此必须传入**未装饰的 raw storage**。

实现方式：`_provider` 是 `EncryptedCloudProvider` 时，取 `inner.storage`；是原生 provider 时，取 `_provider.storage`。

为避免在 `TransactionsSyncManager` 中 import `EncryptedCloudProvider` 造成耦合，新增一个 `rawStorage` getter 在 `_initialize` 时缓存原始 storage 引用：

```dart
CloudStorageService? _rawStorage;

Future<void> _initialize() async {
  final services = await fcs.createCloudServices(config);
  _provider = services.provider;
  _rawStorage = _provider?.storage;  // ← 装饰前缓存
  if (_provider == null) return;
  
  if (encryptionService != null) {
    final enabled = await encryptionService!.isEnabled;
    if (enabled) {
      _provider = EncryptedCloudProvider(...);  // 装饰 _provider，但不影响 _rawStorage
    }
  }
  ...
}

/// 未装饰的原始 storage，供 enableFromCloud 探测云端密文使用
CloudStorageService? get rawStorage => _rawStorage;
```

### 3.4 密码验证策略：解密整条密文 vs 解密 verifier

**决策**：用"尝试解密整条密文"验证密码，不依赖 verifier。

**理由**：
- 云端密文本身就有 GCM MAC，解密失败即密码错误，无需额外 verifier
- verifier 存在本地 secure storage，新设备加入前本地没有 verifier，无法用它验证
- 解密成功后，再用派生的 key 加密 `BEECOUNT_VERIFIER_v1` 生成新 verifier 存入本地（供后续 `verifyPassword` / `changePassword` 使用）

### 3.5 多密文 salt 不一致的处理

**已知限制**：若用户在设备 A 改过密码（`changePassword` 生成新 salt），云端可能存在两种 salt 的密文（旧密文未重加密）。`enableFromCloud` 取第一个密文的 salt，可能导致部分密文无法解密。

**处理策略**：
- 取第一个 BEECRYPT1 密文的 salt（简单可控）
- 若后续解密其他密文失败，`decrypt` 会抛 `DecryptionException`，UI 引导走"重置加密"
- 长期方案：补齐 `changePassword` 的全量重加密流程（独立改造，不在本次范围）

## 4. 实现步骤

### 步骤 1：Domain 层新增接口方法

修改 [lib/domain/encryption/encryption_service.dart](../../lib/domain/encryption/encryption_service.dart)：
- 在 `EncryptionService` 抽象类中新增 `enableFromCloud` 方法签名（含详细文档注释）

### 步骤 2：Data 层实现 enableFromCloud

修改 [lib/data/encryption/encryption_service_impl.dart](../../lib/data/encryption/encryption_service_impl.dart)：

```dart
@override
Future<void> enableFromCloud({
  required String password,
  required CloudStorageService cloudStorage,
}) async {
  _validatePassword(password);
  
  // 1. 探测云端是否有 BEECRYPT1 密文
  final List<CloudFile> files;
  try {
    files = await cloudStorage.list(path: '');
  } catch (e) {
    // 探测失败 → 回退到首设备流程
    logger?.warning('Encryption', '云端探测失败，回退到 enable: $e');
    await enable(password: password);
    return;
  }
  
  // 2. 找第一个 ledger_*.json 且为密文的文件
  String? encryptedFileName;
  for (final f in files) {
    if (!f.name.startsWith('ledger_') || !f.name.endsWith('.json')) continue;
    final raw = await cloudStorage.download(path: f.name);
    if (raw != null && CiphertextFormat.isEncrypted(raw)) {
      encryptedFileName = f.name;
      break;
    }
  }
  
  // 3. 无密文 → 回退到 enable
  if (encryptedFileName == null) {
    await enable(password: password);
    return;
  }
  
  // 4. 提取 salt + 派生 key + 验证
  final ciphertext = (await cloudStorage.download(path: encryptedFileName))!;
  final decoded = CiphertextFormat.decode(ciphertext);
  final key = await keyDerivation.deriveKey(password: password, salt: decoded.salt);
  
  try {
    await cipher.decrypt(encryptedBytes: decoded.encryptedBytes, key: key);
  } catch (_) {
    throw ArgumentError('密码错误，无法加入加密');
  }
  
  // 5. 验证通过 → 持久化
  final verifier = await cipher.encrypt(
    plaintext: utf8.encode(_verifierPlaintext),
    key: key,
  );
  await storage.saveKey(key);
  await storage.saveSalt(decoded.salt);
  await storage.saveVerifier(verifier);
  
  // 6. 激活 + 标记
  _activeKey = key;
  _activeSalt = decoded.salt;
  final prefs = await _getPrefs();
  await prefs.setBool(_enabledKey, true);
}
```

**注意**：步骤 2 中 `download` 被调用两次（一次为 `isEncrypted` 判断，一次为 `decode`）。可优化为下载一次缓存到变量。实际实现时合并：

```dart
String? ciphertextContent;
for (final f in files) {
  if (!f.name.startsWith('ledger_') || !f.name.endsWith('.json')) continue;
  final raw = await cloudStorage.download(path: f.name);
  if (raw != null && CiphertextFormat.isEncrypted(raw)) {
    ciphertextContent = raw;
    break;
  }
}
```

### 步骤 3：TransactionsSyncManager 暴露 rawStorage

修改 [lib/cloud/transactions_sync_manager.dart](../../lib/cloud/transactions_sync_manager.dart)：

- 新增私有字段 `CloudStorageService? _rawStorage;`
- 在 `_initialize()` 中装饰前缓存：`_rawStorage = _provider?.storage;`
- 新增公开 getter：`CloudStorageService? get rawStorage => _rawStorage;`
- `reinitializeForEncryption` 中清空：`_rawStorage = null;`（已包含在 `_provider = null` 逻辑中，但显式清空更清晰）

### 步骤 4：UI 层切换调用

修改 [lib/pages/cloud/encryption_settings_page.dart](../../lib/pages/cloud/encryption_settings_page.dart) 的 `_onSetPassword()`：

```dart
final service = ref.read(encryptionServiceProvider);
final sync = ref.read(sync_p.syncServiceProvider);

if (sync is TransactionsSyncManager) {
  // 确保 _provider 已初始化（rawStorage 才可用）
  await sync.ensureInitialized();
  final rawStorage = sync.rawStorage;
  if (rawStorage != null) {
    await service.enableFromCloud(
      password: result.password,
      cloudStorage: rawStorage,
    );
  } else {
    // provider 不可用（iCloud 未登录等）→ 走首设备流程
    await service.enable(password: result.password);
  }
} else {
  // 非 TransactionsSyncManager（路径 B）→ 不应到此页（UI 已过滤）
  await service.enable(password: result.password);
}

// 后续流程不变：reinitializeForEncryption + 刷新 tick
if (sync is TransactionsSyncManager) {
  await sync.reinitializeForEncryption();
}
```

**需新增 `ensureInitialized` 公开方法**（包装 `_ensureInitialized`）：
```dart
Future<void> ensureInitialized() => _ensureInitialized();
```

### 步骤 5：测试

新增 `test/encryption/encryption_service_multi_device_test.dart`，覆盖 TC-M1 ~ TC-M8。

测试策略：用 mock `CloudStorageService` 模拟云端文件列表和下载内容，验证 `enableFromCloud` 在各场景下的行为。

## 5. 关键流程

### 5.1 新设备加入流程（核心流程）

```
用户在设备 B 点击"设置密码" → 输入 password
    ↓
UI 取 TransactionsSyncManager.rawStorage
    ↓
调用 encryptionService.enableFromCloud(password, rawStorage)
    ↓
enableFromCloud:
  1. list(path:'') → 列出云端文件
     ├─ 失败 → 回退 enable(password) [首设备流程]
     └─ 成功 → 继续
  2. 遍历文件，download 第一个 BEECRYPT1 密文
     ├─ 全是明文/无文件 → 回退 enable(password) [首设备流程]
     └─ 找到密文 → 继续
  3. CiphertextFormat.decode → 提取 salt
  4. Argon2id(password, salt) → key
  5. AesGcmCipher.decrypt(encryptedBytes, key) 验证密码
     ├─ 失败 → throw ArgumentError('密码错误')
     └─ 成功 → 继续
  6. encrypt('BEECOUNT_VERIFIER_v1', key) → verifier
  7. saveKey(key) + saveSalt(salt) + saveVerifier(verifier)
  8. _activeKey = key; _activeSalt = salt; enabled = true
    ↓
UI 调 sync.reinitializeForEncryption() → 装饰器挂载
    ↓
UI 刷新 encryptionEnabledTickProvider
    ↓
下次 getStatus → 走加密装饰器 → 正常返回同步状态
```

### 5.2 首设备开启流程（不变）

```
云端无密文 → enableFromCloud 内部回退 enable(password)
  → 生成新 salt → 派生 key → 存 secure storage → enabled = true
```

与改造前完全一致。

### 5.3 错误处理流程

```
enableFromCloud 抛异常
    ├─ ArgumentError('密码错误') → UI 弹错误对话框
    │   "密码错误，无法加入加密。请确认输入的是其他设备设置过的密码。"
    ├─ 网络异常 → UI 弹错误对话框
    │   "加入加密失败：<原始错误>"
    └─ 探测失败（已内部回退）→ 用户无感，走首设备流程
```

## 6. 边界条件与潜在风险

| 场景 | 处理 |
|------|------|
| 云端完全为空（首次使用） | `list` 返回空 → 回退 `enable` |
| 云端只有 legacy 明文 | 遍历后无密文 → 回退 `enable` |
| 云端有 1 个密文 + N 个明文 | 取该密文的 salt，正常加入 |
| 多个密文 salt 不一致（改密后未重加密） | 取第一个密文的 salt；其他密文解密会失败，UI 引导重置 |
| 密码错误 | GCM 验证失败 → `ArgumentError`，不写 secure storage |
| 网络在 list 后断开（download 失败） | 透传异常，UI 提示失败，不写 secure storage |
| 用户在 enableFromCloud 中途取消 | `_busy` 标志位防重入；无副作用（验证前不写存储） |
| iCloud 未登录（_provider 为 null） | UI 层判断 `rawStorage == null` → 走 `enable` |
| `enable` 已被调用过（重复开启） | UI 层 `isEnabled` 判断已隐藏"设置密码"入口，不会重复触发 |
| 探测增加开启延迟 | UI 已有 `_busy` 加载指示器，用户可见"处理中" |
| `_rawStorage` 在 `reinitializeForEncryption` 后失效 | getter 返回 null，下次 `_initialize` 后恢复；UI 调用前先 `ensureInitialized` |

## 7. 文件清单

### 修改文件（4 个）

| 文件 | 改动 |
|------|------|
| `lib/domain/encryption/encryption_service.dart` | 新增 `enableFromCloud` 抽象方法签名（~15 行文档+签名） |
| `lib/data/encryption/encryption_service_impl.dart` | 实现 `enableFromCloud`（~50 行） |
| `lib/cloud/transactions_sync_manager.dart` | 新增 `_rawStorage` 字段 + `rawStorage` getter + `ensureInitialized` 方法（~10 行） |
| `lib/pages/cloud/encryption_settings_page.dart` | `_onSetPassword` 改调 `enableFromCloud`（~15 行） |

### 新增文件（1 个）

| 文件 | 内容 |
|------|------|
| `test/encryption/encryption_service_multi_device_test.dart` | TC-M1 ~ TC-M8 单元测试 |

### 不修改的文件

- `ciphertext_format.dart` — 已有 `decode` / `isEncrypted`，无需改动
- `aes_gcm_cipher.dart` — 已有 `decrypt`，无需改动
- `argon2_key_derivation.dart` — 已有 `deriveKey`，无需改动
- `secure_key_storage.dart` — 已有 `saveKey/saveSalt/saveVerifier`，无需改动
- `encrypted_cloud_storage.dart` / `encrypted_cloud_provider.dart` — 装饰器逻辑不变
- `pubspec.yaml` — 无新依赖
- `app_zh.arb` / `app_en.arb` — 复用现有"密码错误"文案，必要时新增 1 个 key

## 8. 不在本次范围

- `changePassword` 的全量重加密流程（混合 salt 问题的根本解决，独立改造）
- 独立 salt 文件方案（已评估否决，见 3.1）
- 路径 B（PiggyCount Cloud）加密
- 附件加密
- 密钥导出/导入
