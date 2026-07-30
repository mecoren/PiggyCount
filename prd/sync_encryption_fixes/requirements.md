# 同步与加密链路修复 需求文档

> 范围：PiggyCount 同步路径 A（S3/WebDAV/Supabase/iCloud）下，针对数据恢复、多设备加密、代码质量、同步透明度等 7 个已识别缺陷的修复。

## 1. 背景与问题清单

近期 E2EE 改造完成并修复多设备 salt 错配后，代码评审发现同步与加密链路仍存在 7 处缺陷，按严重度分级如下：

| 编号 | 严重度 | 问题概要 | 影响面 |
|------|--------|----------|--------|
| 1 | 中 | legacy/different 路径全量替换采用追加而非覆盖，且无去重 | 数据正确性：可能产生重复交易行 |
| 2 | 中 | 多设备 salt 错配时整账本同步失败，未引导用户重输密码 | 多设备可用性：单点失败阻断整个账本 |
| 3 | 中/边界 | enableFromCloud 探测失败静默回退 enable()，可能孤立其他设备 | 多设备一致性：其他设备 salt 失效 |
| 5 | 低 | `_contentFingerprintFromMap` 重复实现两份 | 可维护性：指纹逻辑修复需同步两处 |
| 6 | 低 | 错误状态被缓存 | 健壮性：瞬时错误持续报错 |
| 7 | 低/设计 | applyAll 对 different 账本默认全选覆盖本地，无冲突高亮 | 透明度：用户不知本地改动被覆盖 |

## 2. 用户故事

### US-1：安全恢复不重复
**作为** 一个开启云同步的用户，
**我希望** 在使用「云端恢复到当前账本」时，本地原有交易被云端数据干净覆盖，
**以便** 不会出现同一笔交易被记录两次。

**验收标准（AC-1）：**
- AC-1.1：调用 `downloadAndRestoreToCurrentLedger` 时，先清空目标账本下的所有交易行（保留账本本身、分类、账户、标签、预算等配置）
- AC-1.2：清空 + 导入在同一数据库事务内完成；事务失败时回滚，账本回到操作前状态
- AC-1.3：返回值 `(inserted, deletedDup)` 中 `deletedDup` 反映清空阶段删除的本地独有行数
- AC-1.4：原有「云端无数据返回 (0,0)」「404 返回 (0,0)」行为保持不变
- AC-1.5：现有调用方（`startup_sync_checker._applyAll` 旧格式分支、`cloud_sync_page` 的 restore 按钮等）行为兼容，无需改调用方签名

### US-2：salt 错配引导重输密码
**作为** 一个在多设备间使用相同加密密码的用户，
**我希望** 当某台设备的本地 salt 与云端密文 salt 不一致时，同步流程能提示我重新输入密码，
**以便** 不必面对「整个账本同步失败」的硬错误，而是被引导完成密钥激活后自动重试。

**验收标准（AC-2）：**
- AC-2.1：`EncryptionService.decrypt` 在 salt 不匹配时抛出新异常 `SaltMismatchException`（继承自 `DecryptionException` 以保持 catch 兼容）
- AC-2.2：`EncryptedCloudStorageService.download` 不吞掉 `SaltMismatchException`，原样向上抛出
- AC-2.3：`TransactionsSyncManager.getStatus` 与 `downloadAndRestoreToCurrentLedger` 捕获 `SaltMismatchException` 后，返回 `SyncStatus(diff: SyncDiff.error, message: 'salt_mismatch_need_password')` 而非通用 error，且**不写入** `_statusCache`（避免缓存失效状态）
- AC-2.4：`cloud_sync_page` 与 `startup_sync_checker` 识别 `salt_mismatch_need_password` 标识后，弹出密码输入对话框；用户输入后调用 `verifyPassword` → 失败提示「密码错误」；成功则 `activateKey` + `persistActivatedKey` + `reinitializeForEncryption`，并自动重试原同步操作一次
- AC-2.5：用户取消密码对话框时，不重试、不抛出，仅记录日志；下次同步仍会再次提示
- AC-2.6：旧路径下（加密未开启、密文为 legacy 明文）行为不变

### US-3：探测失败不自动孤立其他设备
**作为** 一个在网络不稳定环境下加入新设备的用户，
**我希望** 当 `enableFromCloud` 探测云端失败时，应用不会静默生成新 salt 全量重加密，
**以便** 不会让我其他设备上原本可解密的密文变成不可解密的孤儿。

**验收标准（AC-3）：**
- AC-3.1：`enableFromCloud` 在 `cloudStorage.list` 抛异常时，**不再自动调用 `enable()`**，改为抛出新异常 `EnableFromCloudProbeFailedException`（携带原始异常作为 cause）
- AC-3.2：`enableFromCloud` 在「云端无任何 BEECRYPT1 密文」（即所有文件为 legacy 明文或无文件）的场景下，行为保持不变（回退 `enable()`，返回 false）—— 因为该场景确实为首设备初始化，不存在孤立其他设备的风险
- AC-3.3：`encryption_settings_page` 捕获 `EnableFromCloudProbeFailedException` 后，弹出确认对话框：「云端探测失败（原因：{cause}）。是否作为首设备初始化新加密？这将生成新 salt 并全量重加密云端数据，可能导致其他设备需要重新输入密码。」
- AC-3.4：用户确认后调用 `enable(password)` + `reEncryptExistingCloudData`，与原首设备流程一致；用户取消则不开启加密，回到设置页
- AC-3.5：接口签名 `Future<bool> enableFromCloud(...)` 保持不变；调用方只需新增对异常的捕获分支

### US-5：指纹计算逻辑去重
**作为** 一个维护同步代码的开发者，
**我希望** 交易内容指纹的计算逻辑只有一份实现，
**以便** 修复指纹 bug 或调整规范化规则时只改一处。

**验收标准（AC-5）：**
- AC-5.1：抽取顶层函数 `String contentFingerprintFromMap(Map<String, dynamic> payload)` 到新文件 `lib/cloud/sync_fingerprint.dart`
- AC-5.2：`TransactionsSyncManager._contentFingerprintFromMap`（line 614）与 `_TransactionSerializer._contentFingerprintFromMap`（line 1138）均改为调用该共享函数
- AC-5.3：指纹计算结果与原有实现完全一致（输入相同 Map，输出相同 SHA256 字符串）
- AC-5.4：现有指纹相关测试全部通过，无新增失败

### US-6：错误状态不缓存
**作为** 一个遇到瞬时网络错误的用户，
**我希望** 下次手动触发同步时能立即重试，
**以便** 不会被上次缓存的错误状态持续阻挡。

**验收标准（AC-6）：**
- AC-6.1：`TransactionsSyncManager.getStatus` 在 catch 分支中**不写入** `_statusCache`（删除 line 522 的 `_statusCache[ledgerId] = status`）
- AC-6.2：异常时仍返回 `SyncStatus(diff: SyncDiff.error, message: e.toString())`，调用方可立即看到错误，但下次调用会重新走完整流程
- AC-6.3：`forceRefresh` 路径行为不变；`refreshCloudFingerprint` 仍会显式清除缓存
- AC-6.4：对 US-2 的 `salt_mismatch_need_password` 状态同样不缓存

### US-7：applyAll 冲突高亮与二次确认
**作为** 一个使用「一键应用全部」合并多个账本的用户，
**我希望** 系统明确告知我哪些账本存在本地独有改动且将被云端覆盖，
**以便** 在确认覆盖前有机会改用「逐个确认」保留本地改动。

**验收标准（AC-7）：**
- AC-7.1：`LedgerCandidate` 增加 `SyncDiff diffType` 字段（候选账本的同步状态）
- AC-7.2：`startup_sync_checker` 在构建 `LedgerCandidate` 列表时填充 `diffType`（来自 `getStatus` 的 `diff`）
- AC-7.3：`startup_sync_overlay.dart` 的 `SummaryView` 中，对 `diffType == SyncDiff.different` 的账本行显示警告图标（如 `Icons.warning_amber`，橙色）+ tooltip「本地有改动将被云端覆盖」；其他 diffType 保持原样
- AC-7.4：`_applyAll` 在执行前扫描候选列表，若存在任一 `diffType == SyncDiff.different` 的账本，弹出二次确认对话框：「将用云端覆盖 N 个账本的本地改动（{账本名列表}），是否继续？」
- AC-7.5：用户确认后继续 applyAll 流程；用户取消则中止 applyAll，回退到 SummaryView 让用户重新选择（含改用「逐个确认」）
- AC-7.6：对 `diffType == SyncDiff.cloudNewer` 或 `localNewer` 的账本不弹确认（单向覆盖语义明确，无冲突）；仅 `different` 触发确认

## 3. 非功能需求

### NFR-1：向后兼容
- 不修改 `SyncService` / `EncryptionService` / `CloudStorageService` 既有方法签名（仅新增异常类型与字段）
- 现有调用方未升级时，行为不退化（例如旧调用方不捕获 `SaltMismatchException`，由于其继承自 `DecryptionException`，原 catch 仍能捕获）

### NFR-2：性能
- US-1 在事务内清空+导入，对 5000+ 交易账本仍需在 2 秒内完成（与原导入相当）
- US-2 的密码对话框与重试不引入额外网络往返（重试复用已下载的密文）

### NFR-3：可测试性
- 每个修复点配套单元测试（mockable 接口）
- US-2/US-3 的 UI 交互可注入 mock 服务进行 widget test

### NFR-4：日志
- 所有新分支（清空阶段、salt 错配降级、探测失败回退、applyAll 确认）通过 `logger.info/warning/error` 输出结构化日志

## 4. 范围外

- 不修改路径 B（PiggyCount Cloud）的同步逻辑
- 不重构 `flutter_cloud_sync` 包内部
- 不调整加密密文格式 `BEECRYPT1:<salt>:<nonce||ciphertext||mac>`
- 不引入新的加密算法或密钥派生参数
- 不修改多设备 salt 提取的主流程（已在前序修复中稳定）

## 5. 风险与边界条件

| 风险 | 缓解措施 |
|------|----------|
| US-1 清空时若导入失败，事务回滚保证账本不被破坏 | 全程包在 `db.transaction` 内 |
| US-2 重试一次仍失败可能死循环 | 设计为「最多重试一次」，再次失败则正常抛错 |
| US-3 用户在网络抖动时取消，导致加密未开启 | 可接受：用户可重试；不强制开启 |
| US-5 重构后指纹变化导致全量重同步 | 抽取为纯函数，行为等价，通过现有测试验证 |
| US-7 二次确认对话框在大量账本下文案过长 | 仅显示前 3 个账本名 +「等 N 个」 |
