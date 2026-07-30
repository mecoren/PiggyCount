# PiggyCount 同步加密 - 多设备加入流程 需求文档

> 版本：v1.0  日期：2026-07-27
> 关联设计：`/prd/encryption/multi_device_join_design.md`
> 补充于：`/prd/encryption/requirements.md`（原始 E2EE 需求）的 US-2

---

## 1. 背景与目标

### 1.1 背景

原始 E2EE 需求文档 US-2「多设备解密」规定了 B 设备输入相同密码即可解密云端数据的流程，原始设计文档 3.4/6/8 节也明确指出"新设备首次：从密文头取 salt → 派生 key → 解密成功后把 key 存入 secure storage"。

但实际实现中，`EncryptionServiceImpl.enable(password)` **总是生成新的随机 salt**，忽略了云端已有密文中的 salt。这导致：

- 设备 A 开启加密（生成 `salt_A`，密文头含 `salt_A`）
- 设备 B 用相同密码"设置密码" → 生成新的 `salt_B` → 派生不同的 `key_B`
- 设备 B 解密云端密文时，`_activeSalt`（`salt_B`）与密文头 salt（`salt_A`）不匹配
- 抛出 `DecryptionException: 密文 salt 与当前密钥不匹配，可能需要重新输入密码`
- `getStatus` 捕获异常后返回错误状态（`localCount: 0`）

### 1.2 目标

- **补齐新设备加入流程**：实现原始设计 3.4 规定的"从密文头取 salt"路径
- **不破坏首设备流程**：云端无密文时仍走原 `enable` 逻辑
- **密码校验**：新设备加入时通过尝试解密验证密码正确性
- **零接口破坏**：不修改现有 `enable` 签名，新增独立方法

### 1.3 非目标

- 不引入独立的 salt 文件（如 `beecrypt_salt.bin`）——salt 已在密文头，无需额外同步机制
- 不修改 `CloudStorageService` / `CloudProvider` / `SyncService` 接口
- 不处理"改密后云端旧密文未重加密"的混合 salt 场景（属于 changePassword 流程的独立改造）
- 不覆盖路径 B（PiggyCount Cloud 增量同步）

## 2. 用户故事

### US-M1：新设备加入现有加密

**作为**已在设备 A 开启 E2EE 的用户，
**我希望**在设备 B 输入相同密码即可加入并解密云端数据，
**以便**无缝跨设备同步。

**验收标准**：
- 设备 B 进入加密设置页，点击"设置密码"
- App 自动探测云端是否已有 BEECRYPT1 密文
- 若云端已有密文：弹密码输入对话框（仅一次密码 + 二次确认，文案提示"输入其他设备设置过的密码"）
- 输入正确密码后：
  - 从云端密文头提取 salt
  - 用 password + salt 派生 key
  - 尝试解密该密文验证密码正确性
  - 验证通过 → 把 key + salt + verifier 存入本地 secure storage，标记 enabled
  - 后续同步可正常加解密
- 输入错误密码 → 明确提示"密码错误，无法加入"，不写入 secure storage

### US-M2：首设备开启加密（兼容场景）

**作为**首次使用 E2EE 的用户，
**我希望**云端无密文时仍能正常开启加密，
**以便**我作为第一台设备开始使用。

**验收标准**：
- App 探测云端无 BEECRYPT1 密文（或云端完全为空）
- 走原 `enable(password)` 流程：生成新 salt → 派生 key → 存 secure storage
- 行为与当前完全一致，不引入回归

### US-M3：探测失败回退

**作为**用户，
**当**云端探测因网络/权限失败时，
**我希望**不被阻塞，能继续设置密码，
**以便**网络恢复后再次尝试。

**验收标准**：
- 探测云端时网络失败/权限错误 → 回退到原 `enable` 流程（生成新 salt）
- UI 不阻塞，不抛致命错误
- 日志记录探测失败原因（便于排查）
- 若用户实际是"新设备加入"场景但探测失败，下次同步仍会因 salt 不匹配报错，用户可走"重置加密"流程恢复

### US-M4：多设备加入后立即同步

**作为**刚在设备 B 加入加密的用户，
**我希望**加入成功后立即触发一次同步状态刷新，
**以便**看到正确的同步状态而非错误占位。

**验收标准**：
- `enableFromCloud` 成功后，调用 `reinitializeForEncryption` 让装饰器挂载
- 清空 `TransactionsSyncManager` 的状态缓存
- 下次 `getStatus` 调用走正常的加密装饰器路径，返回真实同步状态

## 3. 功能需求

### FR-M1：EncryptionService 新增 enableFromCloud 方法

新增抽象方法：

```dart
Future<void> enableFromCloud({
  required String password,
  required CloudStorageService cloudStorage,
});
```

行为契约：
- 列出云端 `path: ''` 下所有文件
- 找到第一个 `ledger_*.json` 且内容以 `BEECRYPT1:` 开头的文件
  - 若多个密文 salt 不一致（混合 salt 场景），取第一个即可（属于已知限制，见 US-M3 备注）
  - 若全部是 legacy 明文 → 视为"无密文"，回退到 `enable` 逻辑
- 下载该密文 → `CiphertextFormat.decode` 提取 salt
- `Argon2KeyDerivation.deriveKey(password, salt)` → 临时 key
- 尝试解密该密文（用 `AesGcmCipher.decrypt`）
  - 成功 → 密码正确，继续
  - GCM 验证失败 → 抛 `ArgumentError('密码错误，无法加入加密')`
- 加密 verifier（`BEECOUNT_VERIFIER_v1`）→ 持久化 key + salt + verifier 到 secure storage
- 激活内存中的 key + salt
- 标记 `piggycount_enc_enabled = true`

异常：
- `ArgumentError`：密码为空/过短/解密验证失败
- `StateError`：云端无密文且调用方未回退（实现内部应自动回退，不抛此异常）
- 网络/云存储异常：透传给调用方

### FR-M2：UI 流程分支

修改 `encryption_settings_page.dart` 的 `_onSetPassword()`：

```
1. 收集密码（PasswordSetupDialog）
2. 获取当前 sync 服务（TransactionsSyncManager）
3. 取其 raw storage（未装饰的 _provider.storage）
   - 若 _provider 未初始化，先调 _ensureInitialized
4. 调用 service.enableFromCloud(password, rawStorage)
   - 方法内部自动判断云端是否有密文，无则回退到 enable 逻辑
5. 调用 sync.reinitializeForEncryption() 让装饰器挂载
6. 刷新加密状态 tick
```

边界处理：
- `_provider` 不可用（如 iCloud 未登录）→ 直接调 `enable(password)`（无云端可探测，视为首设备）
- `enableFromCloud` 内部已处理"无密文回退"，UI 层不需要额外分支

### FR-M3：错误处理与文案

| 场景 | 行为 | 文案 |
|------|------|------|
| 密码错误（GCM 验证失败） | 不写 secure storage，弹错误对话框 | "密码错误，无法加入加密。请确认输入的是其他设备设置过的密码。" |
| 云端无密文（首设备） | 静默回退到 enable，正常开启 | "加密已开启" |
| 探测失败（网络/权限） | 回退到 enable，日志记录 | "加密已开启"（用户无感） |
| 云端有密文但下载失败 | 抛异常给 UI，弹错误对话框 | "加入加密失败：<原始错误>" |

## 4. 非功能需求

### NFR-M1：安全性

- 密码不上云
- salt 从云端密文头明文提取（salt 不是秘密）
- 临时 key 派生后立即用于解密验证，不持久化直到验证通过
- 验证失败时不写任何 secure storage

### NFR-M2：兼容性

- 不修改 `EncryptionService.enable` 现有签名（向后兼容）
- 不修改 `CloudStorageService` / `CloudProvider` / `SyncService` 接口
- 不破坏现有首设备开启流程
- 现有所有加密相关测试（101 个）保持通过

### NFR-M3：性能

- 列出云端文件 + 下载一个密文：通常 < 2 秒（取决于后端）
- Argon2id 派生：通过 `compute()` 在 Isolate 执行，不阻塞 UI
- AES-GCM 解密验证：通过 BackgroundTransformer 在 Isolate 执行
- UI 显示加载指示器，避免用户重复点击

### NFR-M4：可测试性

- `enableFromCloud` 可注入 mock `CloudStorageService` 测试
- 多设备流程可通过模拟 A 设备加密上传 → B 设备加入 的单元测试覆盖
- 不依赖真实云存储

## 5. 测试需求

### 5.1 单元测试（新增）

`test/encryption/encryption_service_multi_device_test.dart`：

- **TC-M1**：首设备场景 — 云端无文件 → `enableFromCloud` 回退到 enable，生成新 salt，enabled=true
- **TC-M2**：首设备场景 — 云端只有 legacy 明文 → `enableFromCloud` 回退到 enable
- **TC-M3**：新设备加入 — 云端有 BEECRYPT1 密文 + 正确密码 → 提取 salt，派生 key，验证通过，secure storage 写入，enabled=true
- **TC-M4**：新设备加入 — 云端有 BEECRYPT1 密文 + 错误密码 → 抛 ArgumentError，secure storage 未写入
- **TC-M5**：新设备加入后 — 同一密码派生的 key 可解密云端所有同 salt 密文
- **TC-M6**：新设备加入后 — verifier 可通过 `verifyPassword` 验证
- **TC-M7**：网络失败 — `list` 抛异常 → `enableFromCloud` 透传异常（UI 层回退）
- **TC-M8**：下载失败 — `list` 成功但 `download` 抛异常 → 透传异常

### 5.2 回归测试

- 现有 101 个加密相关测试全部通过
- 现有 `enable(password)` 行为不变

## 6. 风险与缓解

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| 改密后云端旧密文未重加密，混合 salt 场景下新设备取到旧 salt | 中 | 取第一个密文的 salt；若解密失败提示用户走"重置加密"。长期方案是补齐 changePassword 的重加密流程（独立改造） |
| 云端探测增加开启加密的延迟 | 低 | 通常 < 2 秒，UI 显示加载指示器；探测失败时静默回退不阻塞 |
| 用户误以为"设置密码"是首设备开启，实际加入了已有加密 | 低 | 对话框文案明确提示"输入其他设备设置过的密码"（当检测到云端有密文时） |
| 多个密文 salt 不一致导致新设备只能解密部分文件 | 中 | 限制：要求用户先在设备 A 完成 changePassword 重加密流程后再加入新设备；UI 在解密失败时引导走"重置" |

## 7. 验收检查清单

- [ ] TC-M1 ~ TC-M8 全部通过
- [ ] 现有 101 个加密测试无回归
- [ ] 真机验证：设备 A 开启加密 → 设备 B 输入相同密码 → 同步状态正常显示
- [ ] 真机验证：设备 B 输入错误密码 → 提示"密码错误"，不写入 secure storage
- [ ] 真机验证：云端无密文时设备 A 开启加密 → 行为与改造前一致
- [ ] `EncryptionService.enable` 签名未变
- [ ] `CloudStorageService` / `CloudProvider` / `SyncService` 接口签名未变
- [ ] `flutter analyze` 无 issue
