# 附件对象上传并发去重设计（attachment_upload_dedupe）

## 需求理解

在 `TransactionsSyncManager` 的附件上传路径上，为「同一 sha256」增加**进程内 in-flight 去重**，消除多路并发 PUT 同一 `attachments/<sha256>.bin` 的竞态；同时不改变串行重试与单账本内并发度。**零协议改动、零数据模型改动。**

## 现状盘点（代码级）

| 环节 | 现状 | 位置 |
|---|---|---|
| 上传入口 | `uploadAttachmentObjects({required int ledgerId})`，每账本一次；`uploadAllLedgers` 按账本顺序 `await` | `lib/cloud/transactions_sync_manager.dart:1640` / `:1555` |
| 账本内去重 | 构建 `filesBySha`（sha → 本地候选文件名），再 `Future.wait` 遍历 + `_Semaphore(4)` | `:1676-1682` / `:1710-1711` |
| 云端存在性探测 | `_remoteAttachmentNames(provider)`（会话缓存 TTL 60s）→ `remoteHas(sha)` | `:1613-1632` |
| 上传 | `provider.storage.uploadBinaryOrFallback(...)`（E2EE 装饰器内 base64 + encrypt） | `:1742` |
| 成功后登记 | `_markAttachmentUploaded(sha)` 仅在该调用**成功返回后**执行，且缓存为 `null` 时是空操作 | `:1636-1638` |

**缺口**：跨调用的去重只有「成功后写会话缓存」这一层，**没有 in-flight 保护**。因此当两路 `uploadAttachmentObjects` 在时间上重叠（不同账本，或手动全量上传与后台自动同步交叠）时，两边都会在对方写入缓存之前判定 `remoteHas == false`，于是并发 PUT 同一对象；服务端在目标被另一路 rename 占用时（Windows 上）抛 `WinError 5`，失败路随后走 `_atomicPublish` 外层 catch 自清理临时对象（`packages/flutter_cloud_sync_webdav/lib/src/webdav_storage_service.dart:505-512`），即审计里那 1 次 DELETE。

## 关键技术决策

1. **在管理器内加 `Map<String, Future<void>> _attachmentUploadInflight`（键 = sha256）**，把「判定需传 → 上传落定」整段纳入保护；上传前后配对，`finally` 移除条目。
   - 备选「给存储层 MOVE 失败加竞态容错」：**否决**（理由见决策 4）。
2. **后来者 `await` 同一 Future，而不是直接跳过**：保持调用方 `(uploaded, skipped, failed)` 计数语义简单——等待者按首路结果记账；直接跳过会让「首路失败」在等待路被静默丢弃。
3. **失败不写入缓存、等待者一并拿到失败**：不制造「失败也算已完成」的假成功，保证下一轮同步仍会重试（R2）。
4. **不改存储层 MOVE 竞态语义**：曾考虑把 Windows `WinError 5` 纳入 `_isOverwriteUnsupported`，让其走「换名覆盖」路径——**否决**。竞态根因在**并发本身**，服务端绕行只会把竞态挪到换名步骤；且会改变覆盖能力探测的既有语义（见 `webdav_storage_service.dart:978` 对 423 Locked 的有意排除）。客户端单点收敛更小、更可控。

## 实现步骤（≤5）

1. `lib/cloud/transactions_sync_manager.dart` 新增私有字段（含中文注释，说明用途）：

   ```dart
   /// sha256 → 正在进行中的附件对象上传。
   /// 用于合并「同一 sha 的并发上传」：后来者 await 首路的 Future，
   /// 避免对同一内容寻址对象重复 PUT（WebDAV 上会触发 MOVE 覆盖竞态）。
   final Map<String, Future<void>> _attachmentUploadInflight = {};
   ```

2. 抽出 `Future<void> _uploadAttachmentOnce({required provider, required String sha, required String srcPath})`，承载「in-flight 去重 + 实际 `uploadBinaryOrFallback` + 成功后 `_markAttachmentUploaded`」；内部 `try/finally` 从 `_attachmentUploadInflight` 移除。

3. 改 `uploadAttachmentObjects` 中 `Future.wait` 的回调：命中 `_attachmentUploadInflight[sha]` 则 `await` 它并按其结果计入 `skipped`/`failed`；否则登记新 Future 后调用 `_uploadAttachmentOnce`。

4. 补「等待合并」日志（R3），例如 `附件对象上传合并(同 sha 并发): <sha8>`。

5. 验证：新增单测 `test/cloud/attachment_upload_dedupe_test.dart`（内存版 FakeStorageService，覆盖验收 1–3）；`flutter analyze`；复跑一轮 WebDAV 全量上传 + `wd_audit.py` 确认 DELETE = 0（验收 4）。

## 边界条件与风险

- **Future 生命周期**：`finally` 必须移除条目，异常路径不得泄漏，否则该 sha 后续会被永久「合并」而不真正上传。
- **等待者计数归属**：等待者建议计入 `skipped`（对象由首路完成）并在日志区分，避免 `uploaded` 被重复计数导致汇总虚高。
- **内存索引规模**：仅存「进行中」的 sha，条目数 ≤ 并发池大小，无累积。
- **首路失败传播**：等待者拿到异常 → `failed++`（与现状「该 sha 本轮失败」一致），不改变用户可感知行为。
- **与 `_attachmentNameCache` TTL 的关系**：in-flight 保护严格强于 TTL 缓存；TTL 过期后若对象已成功上传，缓存已含该名（`_markAttachmentUploaded`），仍不会重复传。
- **契约安全**：`attachments/<sha256>.bin` 命名、清单 `sha256`、E2EE、快照格式版本（15）均不变，无迁移、无兼容风险。

## 实施记录（2026-10-17）

- **代码**：`_attachmentUploadInflight`（[transactions_sync_manager.dart:166](../../lib/cloud/transactions_sync_manager.dart#L166)）按 sha256 登记在途 Future；`_uploadAttachmentOnce`（[:1659](../../lib/cloud/transactions_sync_manager.dart#L1659)）先同步登记再读文件，`finally` 用 identity 守卫移除（旧 Future 不会误删同 sha 的新一轮上传）；`uploadAttachmentObjects` 回调（[:1793](../../lib/cloud/transactions_sync_manager.dart#L1793)）命中在途则 `await` 并计 `skipped`，首路失败异常传播给全部等待者计 `failed`，不同 sha 仍走 `_Semaphore(4)`。
- **可观测（R3）**：合并路径输出 `附件对象上传合并(同 sha 并发): <sha8>`；测试缝 `attachmentUploadMergedCountForTest`（[:170](../../lib/cloud/transactions_sync_manager.dart#L170)）供并发时序断言。
- **测试**：新增 [attachment_upload_dedupe_test.dart](../../test/cloud/attachment_upload_dedupe_test.dart#L117) 3 例（R1 并发合并、R2 首路失败传播 + 下一轮重试、R2 不同 sha 并发度保持）；与既有 `attachment_sync_test.dart` 合计 23 例全绿。
- **门禁**：`flutter analyze --fatal-infos` → `No issues found!`。全量 `flutter test`：2591 过 / 1 跳过 / 1 失败；唯一失败为 `custom_field_stats_perf_test.dart`（4 万行聚合）在并行负载下 6688ms 超过 5s 阈值，单独复跑 162ms 通过 —— 判定为并行负载抖动，非本批回归。
- **未执行（不宣称达标）**：验收 4 的 WebDAV 双端复跑未执行 —— 当前环境 `adb devices` 无设备、无运行中的双端 App / 本地服务会话，无法产出 `wd_audit.py` 的 `DELETE = 0` 证据。留待有模拟器环境时按 `requirements.md` 验收 4 复跑。
