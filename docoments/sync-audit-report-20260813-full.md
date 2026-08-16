# PiggyCount 同步功能代码全面检查报告（第二轮全量审查）

> 审计日期：2026-08-13
> 审计范围：**除 PiggyCount Cloud 增量同步引擎以外的全部同步相关代码**
> 审计方式：分模块精读 + 行号交叉核验 + 上一轮修复逐项复核
> 审计约束：**只读，未修改任何源代码**
> 关联文档：`docoments/sync-audit-report.md`（第一轮审计 + 13 项修复记录）

---

## 1. 审查范围与边界

### 纳入审查（路径 A 快照同步 + 框架层 + 状态/触发/UI）

| 模块 | 文件 |
|---|---|
| 同步管理器 | `lib/cloud/transactions_sync_manager.dart`（1492 行） |
| 序列化 | `lib/cloud/transactions_json.dart`、`lib/cloud/sync_fingerprint.dart` |
| Diff/合并 | `lib/cloud/sync_diff_service.dart`、`lib/cloud/sync_service.dart` |
| 启动检查 | `lib/cloud/startup_sync_checker.dart`、`lib/cloud/startup_sync_overlay.dart` |
| 状态装配 | `lib/providers/sync_providers.dart`（路径 A 部分） |
| 自动触发 | `lib/services/billing/post_processor.dart` |
| 加密云层 | `lib/data/encryption/encrypted_cloud_provider.dart`、`encrypted_cloud_storage.dart` |
| 导入服务 | `lib/services/data_import_service.dart`（同步导入路径） |
| UI 层 | `lib/pages/cloud/cloud_sync_page.dart`、`sync_preview_dialog.dart`、`encryption_dialogs.dart`、`cloud_service_page.dart`（配置保存部分） |
| 应用胶水 | `lib/app.dart`（启动检查/toast/后台刷新）、`lib/main.dart`（孤儿文件 GC） |
| 框架核心包 | `packages/flutter_cloud_sync/`（manager/core/config/utils，除 piggycount provider） |
| 后端包 | `packages/flutter_cloud_sync_{s3,webdav,supabase,icloud}/` |

### 明确排除（PiggyCount Cloud 增量引擎，用户指定）

- `lib/cloud/sync/` 全部（SyncEngine、change_tracker、sync_coordinator、sync_events 等）
- `packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart`
- `lib/pages/cloud/piggycount_cloud_sync_page.dart`、`devices_page.dart`
- DB 层 `sync_changes` 表、`syncId` 列（引擎专用字段，仅检查路径 A 是否误用——未发现误用）

### 严重度定义

- **P0**：数据丢失 / 安全泄漏（需紧急修复）
- **P1**：功能严重缺陷，导致同步失败或静默数据风险
- **P2**：数据一致性 / 健壮性缺陷
- **P3**：性能 / 改进建议

---

## 2. 上一轮 13 项修复核验结论

上一轮（`docoments/sync-audit-report.md` §5）声明修复 13 项，本次逐项复核：

| 编号 | 修复内容 | 核验结果 |
|---|---|---|
| P1-2 | S3 查询串空格编码 `%20` 与签名一致 | ✅ 正确。`s3_client.dart:558-570` 手动 `Uri.encodeComponent` 构造查询串；签名侧 `s3_signature.dart:100-105` 经 `uri.queryParameters` 解码后重新编码，两侧逐字节一致；新增回归测试断言 `%20` 非 `+`。**补充验证**：continuation-token 含 `+` 时（`%2B` 编码）两侧同样一致，无残留不一致路径 |
| P1-3 | 启动检查错误吞并 → 全失败报错 | ⚠️ **部分修复**。全失败场景已正确报错（`startup_sync_checker.dart:330-336`）；但**部分失败**（部分账本失败 + 部分有候选）时失败账本仍被静默忽略（详见新问题 A-6） |
| P1-4 | 启动检查网络超时 | ⚠️ **修复引入新风险**：`.timeout()` 不取消底层 Future，超时后下载/恢复操作仍可能在后台写库（详见新问题 A-2）；且无整体总时限 |
| P1-1 | 空快照拒绝覆盖 | ✅ 正确但覆盖不完整：仅防护"远端为空"极端场景，**远端为较旧非空快照时仍会清空覆盖本地较新数据**（原 P1-1 的差异比对/确认建议未落实，见新问题 A-1） |
| P2-1 | 指纹纳入 4 个字段 | ✅ 正确。字段名与 `transactions_json.dart:170-173` 序列化一致（已核实），修复有效；但**顶层元数据仍不参与指纹**（见新问题 A-4） |
| P2-3 | 恢复路径 `recordChanges: false` | ✅ 正确。两处下载导入均已显式传 `false` |
| P2-6 | count 空安全 | ✅ 正确。`(localMap['count'] as num?)?.toInt() ?? 0` |
| P2-7 | WebDAV 强制 HTTPS | ✅ 正确。`webdav_provider.dart:71-78` 拒绝非 https/davs；错误信息不含凭据。小瑕疵：无 scheme 的地址（如 `example.com/dav`）报"当前为 ://"，文案可优化 |
| P2-8 | Supabase batchDelete 用户过滤 | ✅ 正确。接口 + 实现均加 `autoFilterByUser`（默认 true），与 delete/update 一致 |
| P2-9 | retry 排除 404 | ✅ 正确。`retry_helper.dart:224-227` 显式排除 `CloudFileNotFoundException` |
| P2-4 | 凭据明文迁移安全存储 | ✅ 正确。`cloud_service_store.dart` 全量迁移 `flutter_secure_storage`（Android EncryptedSharedPreferences），含迁移/降级路径；降级回明文仅为"安全存储不可用"的兜底 |
| P3-1 | 指纹金额数值排序 | ✅ 正确。`double.tryParse` 数值比较 |
| P3-3 | retry jitter | ✅ 正确。0~25% 随机 jitter |

**未修复的遗留项**（上一轮声明暂缓/未做，本轮确认仍存在）：
- P2-5：`_computeLocalUpdatedAt` 仍用 `max(happenedAt)` 代替真实最后修改时间（需 schema 迁移）
- P2-2：`downloadRemoteLedger` 复用同名账本不清空直接追加导入（**本轮升级为 P1，见 A-3**）
- P3-2：异常类不保存 StackTrace
- P3-5：无冲突合并 UI（仅 LWW）
- R1：salt_mismatch 识别靠字符串 `contains('SaltMismatchException')`（见 A-5）
- R2：`_decryptIfNeeded` 宽泛 `on Exception` 吞掉 SaltMismatchException（见 A-5）

---

## 3. 新发现问题清单（应用层）

### P1 — 重要

#### A-1 自动上传无防抖/无串行化，并发上传存在"旧快照覆盖新快照"竞态
- **位置**：`lib/services/billing/post_processor.dart:126-135`（及 `_doSyncC`/`_doSyncR` 两份拷贝）+ `lib/cloud/transactions_sync_manager.dart:391-476`（`uploadCurrentLedger` 无并发控制）
- **类型**：数据一致性 / 并发竞态
- **代码事实**：每笔交易保存都触发 `Future(() => sync.uploadCurrentLedger(...))`，**无防抖、无 in-flight 去重、无串行队列**。用户连续记 N 笔账 → N 个并发上传任务，各自先 `exportTransactionsJson`（在任务执行时点导出快照）再网络上传。上传完成顺序不确定。
- **潜在影响**：任务 A（导出时只有 3 笔，网络慢）可能比任务 B（导出时已有 5 笔，网络快）**后完成** → 云端最终被 3 笔的旧快照覆盖，5 笔中的 2 笔丢失（直到下次手动同步才恢复）。这是快照同步 LWW 的经典竞态，PiggyCount Cloud 引擎有 2 秒防抖 + local_changes 队列，**路径 A 完全没有**。
- **改进建议**：
  1. 为每个 ledger 维护串行上传队列（或 in-flight Future 复用：上传中再触发则等待/合并）；
  2. 上传前重读最新数据（把"导出"推迟到真正发送前）；
  3. 至少加 1-2 秒防抖（与引擎的 2 秒防抖对齐）。

#### A-2 启动检查 `.timeout()` 不取消底层操作，超时后数据仍可能在后台落地
- **位置**：`lib/cloud/startup_sync_checker.dart:417-461`、`522-566`、`615-623`（`_applyTimeout` 30s 包裹 `downloadAndPreview` / `downloadAndRestoreToCurrentLedger` / `applyPreviewChanges`）
- **类型**：数据一致性 / 错误处理
- **代码事实**：`Future.timeout()` 只让等待方超时，**不取消原 Future**。`downloadAndRestoreToCurrentLedger` 内部是"清空本地 + 导入"事务，超时后仍可能继续执行并提交。
- **潜在影响**：
  1. UI 报"账本合并失败"，但本地数据实际已被清空+导入（或正在写入）；
  2. `_applyAll` 超时后立即处理下一个账本 → **两个账本的写事务并发执行**（DB 层虽有锁，但用户感知与数据最终态不可预测）；
  3. 用户看到失败后重试 → 同一账本可能被二次处理。
- **改进建议**：
  1. 引入可取消的同步操作（取消标志/`CancelableOperation`），或
  2. 超时后**不继续下一个账本**，等待原操作真正结束（串行化 apply）；
  3. 超时场景提示"正在后台继续处理，请稍后查看结果"。

#### A-3 `downloadRemoteLedger` 复用同名账本不清空即追加导入 → 重复交易
- **位置**：`lib/cloud/transactions_sync_manager.dart:1196-1199` + `1258-1261`（`reuseExistingByName` 分支直接 `importTransactionsJson`）
- **类型**：数据一致性 / 重复数据
- **代码事实**：与 `downloadAndRestoreToCurrentLedger`（先清空再导入，US-1 修复）不同，此路径复用同名本地账本 ID 后**直接 insert**。`importTransactions`（`data_import_service.dart:819-840`）是纯 `TransactionsCompanion.insert`，无 upsert/去重；`transactions` 表 `syncId` **无唯一约束**（`db.dart:28` 仅普通索引）。
- **潜在影响**：从云端下载"与本地同名"的账本（如恢复所有远程账本、云端有同名账本）时，同源 JSON 的 syncId 与本地已有交易相同 → **插入重复交易行**，明细翻倍、统计错乱；若导入的本地账本恰好非空且用户以为"覆盖"，实际是"追加"。
- **改进建议**：
  1. 明确语义：复用同名账本 = 覆盖（先清空）还是合并（按 syncId upsert），并在 UI 区分；
  2. 若为合并，`importTransactions` 增加按 syncId 去重（insert 前 SELECT 已存在 syncId）；
  3. 为 `transactions.syncId` 增加唯一索引（需先清理历史重复数据）。

#### A-4 指纹忽略顶层元数据，账本名/币种/分类/账户/标签变更永不触发自动上传
- **位置**：`lib/cloud/sync_fingerprint.dart:25-26`（仅迭代 `items`）+ `lib/cloud/transactions_json.dart:324-336`（顶层含 ledgerName/currency/accounts/categories/tags）
- **类型**：数据一致性 / 脏检测漏报
- **代码事实**：`contentFingerprintFromMap` 只对 `items` 计算；顶层 `accounts/categories/tags/ledgerName/currency/monthStartDay` 变更不影响指纹 → `getStatus` 判定 inSync → 不提示、不自动上传。
- **潜在影响**：用户重命名账本/分类/账户、改账本币种、调整标签后，这些改动**永远不会自动同步**（仅手动上传才生效）；另一设备恢复时反而会用旧元数据覆盖本地（`data_import_service.dart:233-241` 的 `updateLedger` 用云端 ledgerName/currency 覆盖本地）——**元数据两端持续不一致且无任何提示**。
- **改进建议**：将顶层元数据规范化后纳入指纹（如 `ledgerName|currency|monthStartDay|sorted(accounts)|sorted(categories)|sorted(tags)` 参与哈希）；或至少在文档中明确"元数据不参与自动同步"，并在 UI 提示手动上传。

#### A-5 salt_mismatch 识别依赖异常类名字符串 + 恢复路径吞异常（R1/R2 遗留）
- **位置**：`lib/cloud/transactions_sync_manager.dart:762-764`（`message.contains('SaltMismatchException')`）、`788-799`（`on SaltMismatchException` 死代码）、`317-324`（`_decryptIfNeeded` 宽泛 `on Exception` 吞掉）、`lib/cloud/startup_sync_checker.dart:466-472`、`572-590`（对应死代码分支）
- **类型**：错误处理 / 死代码
- **代码事实**：
  - `fcs.CloudSyncManager.getStatus`（`cloud_sync_manager.dart:432-438`）catch-all 转 `SyncState.error`，`SaltMismatchException` 不会向上抛 → `transactions_sync_manager.dart:788` 与 `startup_sync_checker.dart:466/572` 的 `on SaltMismatchException` 分支**实际不可达**（死代码）；
  - 生效路径是字符串匹配 `contains('SaltMismatchException')`，底层一旦改变异常措辞即失效；
  - `_decryptIfNeeded` 的 `on Exception catch` 会把 `SaltMismatchException` 吞成 `null` → `downloadAndRestoreToCurrentLedger` 静默返回 `(0,0)`，用户点"下载"无任何反应。
- **潜在影响**：恢复路径的 salt 错配静默无操作；字符串耦合脆弱（底层措辞变动即回归）。
- **改进建议**：
  1. fcs 层透传结构化错误码/异常对象（去掉字符串匹配）；
  2. `_decryptIfNeeded` 对 `SaltMismatchException` 单独 `rethrow`，恢复路径让 UI 弹密码框；
  3. 删除死代码分支或改为兜底。

#### A-6 P1-3 修复不完整：部分账本失败仍被静默忽略
- **位置**：`lib/cloud/startup_sync_checker.dart:327-342`
- **类型**：错误处理 / 状态误报
- **代码事实**：`failedLedgers` 仅在 `candidates.isEmpty` 时检查；若 3 个账本中 2 个 getStatus 失败、1 个有更新 → 只展示 1 个候选，2 个失败账本无任何提示。
- **潜在影响**：用户以为"只有 1 个账本有更新"，其余 2 个账本的云端更新被静默跳过；网络抖动时尤其常见。
- **改进建议**：汇总视图展示"N 个账本检查失败（网络/超时），已跳过"的提示；失败账本进入"可重试/手动检查"状态。

#### A-7 `applySyncChanges` 主表更新失败/删除失败静默吞掉，UI 显示"已应用"实为 0
- **位置**：`lib/cloud/sync_diff_service.dart:457-461`（主表批量更新失败 `syncIdToTxId = {}` 后继续）、`503-512`（批量删除失败仅记日志）、`514-521`（单条删除失败仅记日志）
- **类型**：错误处理 / 状态误报
- **代码事实**：失败被降级为日志，`SyncApplyResult` 计数为 0，`startup_sync_checker`/`cloud_sync_page` 按返回计数提示"已应用 N 条"。
- **潜在影响**：DB 锁冲突/约束失败时用户看到"合并完成"（0 条变更），实际没应用；下次启动检查再次提示 → 用户反复操作无感知。更糟：**部分应用**（主表成功、tag 失败）后数据处于中间态（tag 缺失），无任何失败提示。
- **改进建议**：`applySyncChanges` 返回失败明细（failedCount + 原因），UI 明确提示"部分失败：N 条主表更新失败、M 条 tag 更新失败"；失败应可重试且幂等。

### P2 — 中等

#### A-8 `applySyncChanges` 无条件导入云端分类/账户/标签元数据（仅 deleted 变更也导入）
- **位置**：`lib/cloud/sync_diff_service.dart:327-336`
- **类型**：副作用 / 数据污染
- **代码事实**：`applySyncChanges` 开头无条件执行 `importCategories`/`importAccounts`/`importTags`——即使 `selectedChanges` 全部是 deleted 类型。
- **潜在影响**：用户只勾选"删除云端已删交易"，本地却创建了云端账本的全部分类/账户/标签 → 出现"幽灵"账户（可能影响账户页展示与统计口径）与未用分类。
- **改进建议**：仅当存在 added/modified 变更时才导入对应元数据；或按选中变更实际引用的分类/账户/标签子集导入。

#### A-9 账户/分类重命名跨设备不同步 → 幽灵账户 + 反复 modified
- **位置**：`lib/services/data_import_service.dart:275-365`（`importAccounts` 仅按 name 匹配，不处理 rename）、`368-465`（`importCategories` 无 syncId 锚定）、`lib/cloud/sync_diff_service.dart:243-260`（按账户名比较）
- **类型**：数据一致性
- **代码事实**：设备 A 重命名账户"钱包"→"现金"并上传；设备 B diff 看到账户名差异 → modified；apply 时 `importAccounts` 发现"现金"不存在 → **新建**账户"现金"，交易挂到新账户；旧账户"钱包"残留（有历史交易）。分类同理（导出 JSON 的分类**不带 syncId**，只能按 name 匹配）。
- **潜在影响**：跨设备 rename 产生幽灵账户/分类，历史统计分裂；且 rename 后每次 diff 都报 modified（本地账户名始终与云端不一致→ apply 又新建…直到云端覆盖），diff 列表长期出现"账户: 钱包 → 现金"。
- **改进建议**：账户/分类导出增加 syncId（与标签一致），导入按 syncId 锚定并 rename 本地实体（带名字冲突保护，参考 `importTags` 的实现）；`_compareTx` 的账户比较改为按 syncId 解析后的本地名。

#### A-10 转账交易账户解析失败被静默丢弃 + `importAccounts` 吞异常返回空映射
- **位置**：`lib/services/data_import_service.dart:736-749`（转账 from/to 账户解析不到 → `failed++` 丢弃整条交易）、`360-362`/`460-462`（`importAccounts`/`importCategories` catch 吞异常）
- **类型**：数据一致性 / 静默丢失
- **代码事实**：`importAccounts` 任一步抛异常 → 整个 catch 吞掉并返回**空映射**（已创建的账户不在返回值中）；随后 `importTransactions` 中所有转账交易因 `accountNameToId[...] == null` 被 `continue` 丢弃（`failed++` 仅计数）。
- **潜在影响**：批量恢复/apply 时若账户导入阶段出一次 DB 异常，**该批所有转账交易静默丢失**（非转账交易以 accountId=null 插入，转账直接被丢弃），用户只看到"已应用 N 条"且不知道丢了什么。`ImportResult.failed` 从未在 UI 层展示。
- **改进建议**：
  1. `importAccounts`/`importCategories` 失败时向上抛或返回部分结果（不要吞成空映射）；
  2. 账户解析失败时创建缺失账户（按名称兜底创建，参考标签的 `createTag` 兜底）；
  3. UI 展示 `ImportResult.failed` 计数。

#### A-11 `syncServiceProvider` 重建泄漏（配置保存/登出后旧实例无 dispose）
- **位置**：`lib/providers/sync_providers.dart:521-557`（path A 分支仅 `onDispose` 取消表监听）+ `lib/pages/cloud/cloud_sync_page.dart:956-959`（登出 invalidate）
- **类型**：资源泄漏
- **代码事实**：`CloudSyncManager`（`cloud_sync_manager.dart`）**无 dispose 方法**；`syncServiceProvider` 重建（登出/配置切换 invalidate）时，旧 `TransactionsSyncManager` 持有的 CloudSyncManager、底层 provider（HTTP client、连接池、缓存 Map）**全部无法释放**。
- **潜在影响**：每次登出/切换云配置泄漏一个完整同步栈；反复操作后内存与连接持续增长。
- **改进建议**：为 `CloudSyncManager`/`TransactionsSyncManager` 增加 `dispose()`（释放 provider、清空缓存），`syncServiceProvider` 的 `onDispose` 中调用。

#### A-12 自动上传失败无重试/无离线队列
- **位置**：`lib/services/billing/post_processor.dart:126-135`
- **类型**：网络可靠性
- **代码事实**：上传失败仅 `logger.error`，无重试、无离线累积、无 connectivity 恢复触发（引擎有 local_changes 队列 + connectivity 监听，路径 A 无）。
- **潜在影响**：用户离线记账 10 笔 → 上传全部失败 → 联网后**不会自动补传**（除非再记一笔或手动上传），云端长期缺失。
- **改进建议**：失败后保留"待上传"标记，监听 connectivity 恢复（复用 `connectivity_plus`）自动重传；或复用 `RetryHelper` 指数退避。

#### A-13 启动检查逐账本串行 + 无整体总时限
- **位置**：`lib/cloud/startup_sync_checker.dart:249-316`
- **类型**：性能 / 可用性
- **代码事实**：N 个账本串行 `getStatus`，每个上限 20s → 10 账本最坏 200s；overlay 全程阻断交互；无整体超时降级。
- **潜在影响**：多账本用户启动被长时间阻断（已有 P1-4 修复缓解单次挂起，但总时长未限制）；P3-6 建议的并行化未落实。
- **改进建议**：账本间并行 getStatus（限并发 4-6）；增加总时限（如 45s），超时降级为"后台继续检查，先进入 App"。

#### A-14 本地"最后更新时间"用 `max(happenedAt)` 近似（P2-5 遗留）
- **位置**：`lib/cloud/transactions_sync_manager.dart:374-389`
- **类型**：同步方向判断精度
- **代码事实**：`_computeLocalUpdatedAt` = `max(最近写入时间, MAX(happened_at))`。编辑历史交易（不改 happenedAt）不反映；预排未来日期交易抬高该值。
- **潜在影响**：`fcs.CloudSyncManager.getStatus` 的方向判断（`cloud_sync_manager.dart:385-391`）可能误判"本地较新/较旧"，与指纹比较叠加时产生错误 diff 方向。
- **改进建议**：新增 `updated_at` 列（schema 迁移），或账本级 `last_modified` 时间戳；迁移期可用"MAX(写入时间) + MAX(happenedAt)"混合启发式。

#### A-15 `refreshAllLedgersStatus` 无超时 + 与启动检查并行重复打云
- **位置**：`lib/cloud/transactions_sync_manager.dart:1136-1154`、`lib/app.dart:112/120/352-364`
- **类型**：性能 / 资源
- **代码事实**：启动时 `_refreshLedgersStatusInBackground`（路径 A → `refreshAllLedgersStatus`）与 `_triggerStartupSyncCheck` 并行执行，两路都逐账本 `getStatus`（若 `_statusCache` 未命中则双倍网络请求 + 双倍 `exportTransactionsJson` 全表导出）。
- **潜在影响**：大账本（万级交易）启动时 export JSON 两次，CPU/IO 双倍；网络请求双倍。
- **改进建议**：后台刷新与启动检查合并为一路（启动检查优先）；`getStatus` 内部导出加内存缓存/去重。

### P3 — 建议

| 编号 | 位置 | 类型 | 建议 |
|---|---|---|---|
| A-16 | `restoreAllRemoteLedgers`（`transactions_sync_manager.dart:1393-1428`） | 性能 | 每个远程账本先 download 一次取 name/currency，`downloadRemoteLedger` 内部**再 download 一次**（同一文件两次全量下载）；且 `Future.wait` 无并发限制。建议把已下载内容传入 `downloadRemoteLedger`，并限制并发（如 3-4） |
| A-17 | `_ensureInitialized`（`transactions_sync_manager.dart:203-229`） | 健壮性 | 初始化失败（网络/配置错误）后每次调用都重试完整初始化，无退避；建议失败退避 30s+ 或标记降级 |
| A-18 | `post_processor.dart` 三份相同实现（`_doSync`/`_doSyncC`/`_doSyncR`） | 代码质量 | 逻辑完全重复，后续修改需同步三处；建议收敛为单函数 |
| A-19 | `parseJsonToImportData`（`transactions_json.dart:352-465`） | 健壮性 | `acc['name'] as String`、`it['type'] as String`、`(it['amount'] as num)`、`DateTime.parse` 等强转对旧版/损坏 JSON 直接崩溃，错误堆栈不友好；建议按 version 做字段兼容校验或 try/catch 转友好错误 |
| A-20 | `_TransactionSerializer.deserialize`（`transactions_sync_manager.dart:1456-1459`） | 健壮性 | `json['ledgerId'] as int` 强转：老 JSON 无 ledgerId 时崩溃（当前 `manager.download()` 未被激活路径调用，属潜伏风险） |
| A-21 | `promptPasswordAndActivate`（`encryption_dialogs.dart:71-75`） | 健壮性 | `enableFromCloud` 无超时守卫，网络挂起时密码对话框卡在加载态；建议加 20s 超时 |
| A-22 | `_compareTx` 不比较附件（`sync_diff_service.dart:203-308`） | 一致性 | 附件增删不产生 diff → 附件变更不会经 diff 模式跨设备同步（仅全量替换才带附件元数据） |
| A-23 | 标签名含逗号（`transactions_json.dart:208`） | 一致性 | tags 以逗号拼接，标签名含逗号时导入拆分错误；建议限制标签名含逗号或改用转义/数组 |
| A-24 | 启动检查 `HasUpdatesState` completer（`startup_sync_overlay.dart:134-136`） | 健壮性 | overlay 被外部 detach 时 completer 永不 complete，checker 协程悬挂（进程退出时无害） |
| A-25 | 启动时后台刷新与启动检查双路导出（同 A-15） | 性能 | — |

---

## 4. 同步机制专题分析（按审查维度汇总）

### 4.1 同步触发条件
- 自动上传：仅 `post_processor` 在数据变更后触发（受 `auto_sync` 开关控制），**无防抖/串行**（A-1）、**失败无重试**（A-12）、离线无队列。
- 启动触发：双路并行（后台刷新 + 启动检查，A-15）；启动检查只跑一次，失败不自动重试。
- 手动触发：cloud_sync_page 上传/下载按钮（有 busy 状态互斥，OK）；下载走 diff 预览，旧格式走确认对话框（OK）。
- 状态刷新：`syncStatusRefreshProvider`/`syncStatusRefreshByLedgerProvider` tick 机制合理；`snapshotSyncCompletedProvider` 仅自动上传路径 bump（手动路径自带弹窗，OK）。

### 4.2 数据一致性
- **LWW 硬覆盖是快照同步的固有风险**：`downloadAndRestoreToCurrentLedger` 清空+导入（A-1 场景 + A-3 追加路径 + 元数据覆盖 A-4），除"空快照"外无任何保护；建议至少在上传/下载前做指纹+时间双比对并提示。
- 指纹已覆盖 items 全字段（含 override/多币种/账单标记），但顶层元数据缺失（A-4）。
- diff apply 存在静默部分失败（A-7）、无条件元数据导入（A-8）、转账静默丢弃（A-10）。

### 4.3 网络请求处理
- 框架层 `RetryHelper`（指数退避 + jitter + 404 排除）已就位；但**应用层上传/下载路径未接入 RetryHelper**（`TransactionsSyncManager` 直接调用 manager/storage，无重试），超时守卫仅启动检查有（且有不取消问题 A-2）。
- WebDAV HTTPS 已强制（P2-7 ✅）；S3 签名编码已修复（P1-2 ✅）。

### 4.4 同步冲突解决策略
- 路径 A 仅 LWW（最近上传/下载胜）+ diff 预览合并（v6+ 按 syncId 逐条选择）。无三方合并、无冲突 UI（P3-5 暂缓）。
- `different` 状态的账本在 applyAll 前有二次确认（US-7 ✅），但旧格式（v5-）账本走全量替换无逐账本确认。

### 4.5 同步状态管理
- `getStatus` 缓存 TTL 60s（m-03 ✅）、error 不缓存（US-6 ✅）、近期上传 15s 窗口（CDN 延迟 ✅）。
- salt_mismatch/cloud_encrypted 哨兵机制正确，但识别依赖字符串匹配（A-5）。
- 状态刷新链（bump tick → FutureProvider 重跑）正确；`transactions` 表 watch 兜底 stats 刷新（✅）。

### 4.6 异常捕获与处理
- 主要问题集中在**静默吞掉**：`importAccounts`/`importCategories` 吞异常（A-10）、`applySyncChanges` 吞失败（A-7）、`_decryptIfNeeded` 吞 SaltMismatch（A-5）、`post_processor` 上传失败仅日志（A-12）。
- 错误提示面：启动检查已改善（全失败报错 ✅），部分失败仍缺失（A-6）。

---

## 5. 测试覆盖缺口

- 无 `post_processor` 并发上传竞态测试（A-1）
- 无 timeout 超时后继续写库的行为测试（A-2）
- 无 `downloadRemoteLedger` 同名账本重复导入测试（A-3）
- 无元数据变更触发脏检测测试（A-4）
- 无 `applySyncChanges` 部分失败/仅 deleted 变更的元数据导入测试（A-8/A-7）
- 无账户 rename 跨设备场景测试（A-9）
- 无 `restoreAllRemoteLedgers` 并发与双下载测试（A-16）
- 框架包：`cloud_sync_manager` 状态机/缓存 TTL 测试未见（可补）

---

## 6. 优先级修复建议

1. **立即（P1）**：A-1（上传串行化/防抖，数据丢失风险）、A-2（超时不取消，落地不一致）、A-3（重复导入，去重/唯一索引）、A-7（apply 失败可见化）。
2. **近期（P2）**：A-4（元数据指纹）、A-5（去字符串耦合）、A-6（部分失败提示）、A-8（按需导入元数据）、A-9（账户/分类 syncId 锚定）、A-10（导入失败不吞）、A-11（dispose 链）、A-12（失败重试）。
3. **框架层**：`CloudSyncManager.dispose`、fcs 错误码结构化透传（配合 A-5）。
4. **性能**：A-13（并行化+总时限）、A-15（双路合并）、A-16（双下载）。

---

## 7. 框架包问题清单（flutter_cloud_sync 核心包）

> 注：`DatabaseSyncManager` 相关项（F-1/F-3/F-5/F-6/F-8/F-9）为**框架潜伏路径**——当前主应用快照同步走 Storage 而非 Database，未激活；但一旦启用即触发，且是"离线队列"设计承诺的核心实现。

### P1 — 重要

#### F-1 【框架潜伏】配置迁移破坏应用导出/导入：`config_export_service` 直读/直写 SharedPreferences
- **位置**：`lib/services/export/config_export_service.dart:1289/1309/1330/1359`（导出直读 `prefs.getString('cloud_s3_cfg')` 等）+ `2283/2298/2315/2331`（导入直写 `prefs.setString`）+ `packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart:28-48`（迁移删除明文键）
- **类型**：数据一致性 / 安全（**激活路径**）
- **代码事实**：P2-4 迁移在首次 `_readCfg` 时把 `cloud_*_cfg` 键从 SharedPreferences **删除**并迁入 secure storage。但配置导出服务仍直读 prefs：
  - **导出**：迁移后这些键已不存在 → 导出的 YAML **永远丢失 S3/WebDAV/Supabase/PiggyCount Cloud 全部云配置**（含 URL/用户名，用户换机恢复后云同步静默失配）；
  - **导入**：`prefs.setString` 把含 `s3SecretKey`/`webdavPassword` 的明文 JSON 写回 SharedPreferences（直到下次 `loadActive` 迁移才清除，期间明文落地）。
- **潜在影响**：配置备份/恢复（换机迁移核心场景）功能被 P2-4 修复**直接打断**；导入瞬时明文凭据。
- **改进建议**：导出/导入统一走 `CloudServiceStore`（`loadS3()/loadWebdav()/...` 与 `saveOnly()`），禁止业务层直接触碰 prefs 键；`saveOnly` 需要支持"导出用"的只读访问。

#### F-2 【框架潜伏】`syncRecord` 冲突检测 LWW 语义倒置：云端较新记录被本地旧数据静默覆盖
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:596-615`（`_detectConflict`）、`303-308`（fall-through 更新）
- **类型**：数据一致性
- **代码事实**：时间戳分支只对 `localUpdated.isAfter(cloudUpdated)` 返回冲突；`cloudUpdated > localUpdated` 时返回 null（无冲突）→ 后续用**更旧的本地数据覆盖更新的云端数据**。版本相等、时间戳缺失/不可解析同样无冲突直接覆盖。
- **潜在影响**：一旦 Database 同步被启用，A 设备在线更新的记录会被 B 设备离线旧数据静默覆盖，LWW"新者胜"语义在此路径完全失效。
- **改进建议**：补 `cloudUpdated.isAfter(localUpdated)` 分支（lastWriteWins 应回写本地或按策略处理）；update 加版本乐观锁（`version = cloudVersion` 条件）防 TOCTOU。

#### F-3 【框架潜伏】`processOfflineQueue` 重试耗尽后静默丢弃离线操作
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:381-390`
- **类型**：数据一致性
- **代码事实**：`retryCount >= maxRetryAttempts` 时仅 `logger.error`，操作既不进 `failedOperations` 也不回队列，直接从内存队列消失。
- **潜在影响**：服务端持续不可用时，离线期间的新增/修改在被尝试 N+1 次后**静默丢失**，无任何上报。
- **改进建议**：超限操作转入持久化死信队列或通过回调上报（`onOperationDropped`），由上层提示用户。

### P2 — 中等

#### F-4 `getStatus` 直接信任 metadata['fingerprint']，内容被外部改写后误报 synced
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/cloud_sync_manager.dart:300-318`（**激活路径**）
- **类型**：数据一致性
- **代码事实**：metadata 有 fingerprint 时直接作为 `cloudFingerprint` 参与比对，不下载校验内容。若云端对象被非框架工具改写（S3 控制台、旧版本无 metadata 上传、CDN 陈旧副本），metadata 指纹与内容脱钩。
- **潜在影响**：本地与云端实际分叉却显示"已同步"，分叉长期不被发现。
- **改进建议**：metadata 指纹与内容长度/ETag 绑定校验；`forceRefresh` 时可选回退下载校验。

#### F-5 【框架潜伏】离线队列仅存内存，进程被杀后离线编辑全部丢失
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:191, 339-343`
- **类型**：数据一致性
- **代码事实**：`_offlineQueue` 是纯内存 `Queue`，无持久化。
- **潜在影响**：移动端进程被杀（后台回收）后离线操作静默消失，"离线不丢"承诺失效。
- **改进建议**：队列持久化（操作 JSON 落盘），启动时恢复；或提供可注入的持久化接口。

#### F-6 【框架潜伏】`processOfflineQueue` 无重入保护：并发调用重复执行
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:358-365`
- **类型**：资源管理
- **代码事实**：入口不检查进行中状态，两个并发调用各自 `removeFirst()` 同一批操作。
- **潜在影响**：insert 重复执行 → 云端重复记录。
- **改进建议**：入口 `if (_status == syncing) return 0;` 或复用进行中 Future。

#### F-7 `_readCfg` 迁移与 `_writeCfg` 并发竞态：旧明文可复活覆盖新配置
- **位置**：`packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart:28-68`（**激活路径**）
- **类型**：资源管理 / 逻辑错误
- **代码事实**：`_readCfg`（读 secure 未命中 → 读 prefs 旧值 → 回写 secure）与 `_writeCfg`（写 secure → 删 prefs）交错时，旧明文可能后写覆盖新值。
- **潜在影响**：启动 loadActive 与设置页保存并发时，最新配置被旧配置覆盖且无报错。
- **改进建议**：单键级异步互斥（single-flight），或删除 prefs 前校验 secure 值一致（compare-and-swap）。

#### F-8 `_writeCfg` 静默降级明文 + 迁移后换机恢复场景配置不可读
- **位置**：`packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart:52-68`（**激活路径**）
- **类型**：安全 / 健壮性
- **代码事实**：①secure 写入失败（keystore 损坏等）静默明文落 prefs，仅 debugPrint；②EncryptedSharedPreferences 密钥绑定设备，Android 备份恢复/重装后密文不可解密 → `loadActive` 静默回退 local，但 `_kActiveType` 仍指向原云类型。
- **潜在影响**：凭据明文持久化无人知晓；换机恢复后云配置整体消失、UI 与真实状态脱节。
- **改进建议**：降级暴露可观察信号；`loadActive` 回退前探测"secure 不可读但有 active_type"并明确提示。

#### F-9 【框架潜伏】`syncRecord` 无乐观锁（TOCTOU）
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:267-308`
- **类型**：数据一致性
- **代码事实**：`getById` 与 `update` 之间云端记录被并发修改时，后提交者用过期快照整体覆盖。
- **改进建议**：update 带 `expectedVersion` 乐观锁，冲突重读重判。

#### F-10 【框架潜伏】dispose 后 `_updateStatus` 向已关闭 StreamController.add 抛 StateError
- **位置**：`packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:197-198, 707-713, 745-749`
- **类型**：资源管理
- **代码事实**：`dispose()` 关闭 controller 后，迟到的连接回调仍 `add` → broadcast controller 关闭后 add 抛 `StateError`（Error 类，try/catch 常捕获不到）→ 崩溃。
- **改进建议**：`_updateStatus` 前检查 `isClosed`；dispose 置 `_disposed` 标志并在各入口快速失败。

### P3 — 建议

| 编号 | 位置 | 类型 | 建议 |
|---|---|---|---|
| F-11 | `cloud_sync_manager.dart:263-278` | 性能 | `getStatus` 每次全量 serialize + 主 isolate sha256（激活路径：`transactions_sync_manager.dart:754` 恒传 `forceRefresh:true`），大账本卡顿；建议指纹计算移入 isolate 或缓存本地指纹 |
| F-12 | `cloud_sync_manager.dart:128, 310-315` | 一致性 | `uploadedAt` 写**无时区本地时间**（覆盖主应用传入的 UTC 时间），跨时区设备方向判断错误（UTC+8 上传在 UTC-5 解读为"云端较新数小时"）；应统一 `.toUtc().toIso8601String()` |
| F-13 | `cloud_sync_manager.dart:437-441` | 安全 | error message 拼接原始异常 `toString()`（可能含完整 URL/凭据端点），UI 与日志暴露；应按异常类型脱敏 |
| F-14 | `cloud_sync_manager.dart:249-256` | 状态管理 | `notAuthenticated` 状态被缓存 30s，登录后 UI 延迟显示；应与 error 同策略不入缓存 |
| F-15 | `database_sync_manager.dart:470-478, 717-721` | 逻辑错误 | `subscribeToTable` filter 字符串拼接无转义（`"`/`,`）、bool 用 `eq.true`（应为 `is.true`）；含特殊字符/布尔过滤订阅失效 |
| F-16 | retry_helper 修复 | 测试覆盖 | 404 排除与 jitter 修复**无测试覆盖**；且 `CloudSyncManager`/`DatabaseSyncManager`/各 provider 均未接入 RetryHelper（同步路径实际无重试，S3 自研 `_retry` 无 jitter） |

### 核心包已声明修复核验结论

1. **retry_helper（404 排除 + jitter）** ✅ 逻辑正确；⚠️ 无测试覆盖 + 框架自身未接入（修复影响面有限）。
2. **cloud_service_store 凭据迁移** ⚠️ 主流程正确；❌ **迁移不完整**：`config_export_service` 直读/直写 prefs 未同步改造（F-1，P1）；另有两处并发/降级瑕疵（F-7/F-8）。
3. **batchDelete autoFilterByUser** ✅ 正确且完整落地（含接口契约）。

---

## 8. 后端包问题清单（Supabase / iCloud）

### P1 — 重要

#### S-1 SupabaseProvider 配置切换（url/anonKey 变更）静默失效，且登出旧项目会话
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_provider.dart:90-114`（+123-138 兜底 catch）
- **类型**：网络 / 状态管理（逻辑错误）
- **代码事实**：`configChanged` 时先 `signOut()` 再 `Supabase.initialize(url: 新url, anonKey: 新key)`；但 supabase_flutter 2.17.1 SDK 对重复 `initialize` **不抛异常直接返回旧实例**（`supabase.dart:104-107` "Skipping reinitialization"）→ 新 url/anonKey 被静默忽略，`_currentUrl/_currentAnonKey` 却写入新值；catch 中的 `'already initialized'` 字符串匹配永远不命中。该流程在 `cloud_service_page.dart:1559/1885` 配置测试与 `provider_factory.dart:43` 反复触发。
- **潜在影响**：用户修改 Supabase 项目地址/anonKey 后"测试连接"显示成功但实际连旧项目；旧项目会话已被 signOut → "配置已保存但同步未登录/写错地方"的静默数据错位。
- **改进建议**：初始化前探测 SDK 全局实例是否已用不同参数初始化，不同则 `Supabase.instance.dispose()` 后重新 initialize（或使用 SDK 命名多客户端）；移除字符串匹配兜底；静态标记随 dispose 复位。

### P2 — 中等

#### S-2 `exists()`/`getMetadata()`/`list()` 受 storage list 默认 limit=100 限制，超限静默漏报
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_storage_service.dart:132-134, 169-174, 200-210`（**激活路径**）
- **类型**：数据一致性 / 性能
- **代码事实**：三个方法都依赖 `list(path: dirname)` 目录枚举；storage_client 2.8.0 `SearchOptions.limit` 默认 **100**，代码未传 searchOptions。用户目录对象数 >100 时：`list` 丢尾部文件、`exists`/`getMetadata` 对实际存在的文件返回 false/null。
- **潜在影响**：`TransactionsSyncManager.getRemoteLedgers`（`transactions_sync_manager.dart:997`）在用户云端文件超 100 个时**静默缺失远端账本**；`exists` 误判 false 可能触发调用方"覆盖上传"等危险操作。
- **改进建议**：显式传 `ListOptions` 并分页循环；`exists`/`getMetadata` 改用 head/info 精确 API。

#### S-3 Realtime 过滤器格式错配：生产者输出 `column=op.value`，解析器按 `column=value` 解析
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_realtime_service.dart:148-162`（`_parseEqFilter`）+ `packages/flutter_cloud_sync/lib/src/manager/database_sync_manager.dart:475-478`
- **类型**：数据一致性（框架潜伏——realtime 未在激活路径接线）
- **代码事实**：`database_sync_manager` 构造 `'ledger_id=eq."abc"'`；`_parseEqFilter` 在第一个 `=` 切分得 value=`eq."abc"`，再包成 `PostgresChangeFilter(eq, ledger_id, 'eq."abc"')`，最终发给服务端 `ledger_id=eq.eq."abc"`（已对照 realtime_client 2.13.0 `PostgresChangeFilter.toString()`）。过滤条件非法 → 订阅"看似成功"但事件静默不送达。
- **改进建议**：解析 `=` 后的 `op.` 前缀（eq./neq./in.(...)），或调用方直接传结构化 filter；加单测。

#### S-4 `removeChannel` finally 语义与注释（P-M3）相反：unsubscribe 失败缓存仍被清除
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_realtime_service.dart:266-273`
- **类型**：资源管理 / 状态管理（框架潜伏）
- **代码事实**：注释声称"先 unsubscribe 成功后再从缓存移除"，代码却是 `try { await unsubscribe(); } finally { _channels.remove(...); }`——**无论成败都移除**；而 realtime_client 2.13 `channel()` 每次新建 channel（不按 topic 复用）→ 失败后重试 `channel(name)` 会得到新包装并重复 subscribe，同一 topic 两份订阅 → 重复事件。
- **改进建议**：仅成功后才移除缓存；失败保留缓存并抛出，调用方按原引用重试。

#### S-5 `getById` 缺 user_id 过滤（本次"一致过滤"目标唯一漏网之鱼）
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_database_service.dart:211-215`
- **类型**：安全（框架潜伏）
- **代码事实**：`getById` 仅 `select().eq('id', id)`，无 `eq('user_id', user.id)`，接口也无 autoFilterByUser 参数；其余所有查询/写方法均强制用户过滤。
- **潜在影响**：RLS 缺失/漏洞时任意登录用户可凭 id 读他人记录。
- **改进建议**：与 delete/update 一致补 autoFilterByUser（接口同步更新）。

#### S-6 iCloud Auth：方法通道失败被当作"不可用"→ `refreshStatus` 误发登出事件
- **位置**：`packages/flutter_cloud_sync_icloud/lib/src/icloud_auth_service.dart:43-65, 79-94` + `icloud_method_channel.dart:11-25`
- **类型**：异常处理 / 状态管理
- **代码事实**：`_doInitialize` catch 静默吞异常置 `_currentUser=null`；`refreshStatus` 无 try/catch；`isICloudAvailable` 对所有异常（插件未注册/超时）返回 false → 瞬态故障表现为"用户登出"信号，UI 登录态抖动。
- **改进建议**：区分"明确不可用"与"探测失败"；探测失败保留原状态并记录 error。

#### S-7 iCloud Auth：`signOut()` 与进行中初始化竞态，用户"复活"
- **位置**：`packages/flutter_cloud_sync_icloud/lib/src/icloud_auth_service.dart:38-64, 119-124`
- **类型**：逻辑错误
- **代码事实**：`signOut()` 不重置 `_initFuture`；signOut 发生在 `_doInitialize` 的 await 期间时，初始化完成回写把 `_currentUser` 重新置非 null。
- **改进建议**：epoch/generation 计数，初始化回调校验 epoch 后再回写。

#### S-8 连接状态真实性缺陷 + dispose 后状态回调触发已关闭 StreamController
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_realtime_service.dart:203-217, 305-343, 350-353`
- **类型**：状态管理 / 异常处理（框架潜伏）
- **代码事实**：连接状态仅在构造时打快照；`disconnect()` 注释称 SDK 无显式 disconnect（已核实 realtime_client 2.13.0 有 `disconnect()`，未调用）；`dispose()` 关闭 controller 后迟到的 channel 回调 `_updateConnectionState` → `add` 抛 StateError。
- **改进建议**：主动 `_client.realtime.disconnect()`；`_updateConnectionState` 加 `isClosed` 守卫；dispose 后置空 `onStatusChange`。

### P3 — 建议

| 编号 | 位置 | 类型 | 建议 |
|---|---|---|---|
| S-9 | `supabase_storage_service.dart:263-321` | 异常处理 | 元数据表读写失败全部静默降级（含 RLS 拒绝/网络错误），且与主文件上传非原子 → 指纹缺失时 getStatus 每次全量下载；应区分"表不存在"（降级）与"真实错误"（抛出） |
| S-10 | `supabase_database_service.dart:61-66, 98-103, 132-137, 190-195` | 异常处理 | `single()` 无匹配行 PGRST116 被包装为普通失败，调用方无法区分"不存在/无权"与故障；应映射 `CloudFileNotFoundException` |
| S-11 | `icloud_storage_service.dart:55-63` + `ICloudManager.swift:224-275` | 性能 | 全量快照 base64（+33%）整体走 MethodChannel，无大小上限/超时；大账本内存峰值高、主 isolate 卡顿；建议拆分/临时文件传参/gzip |
| S-12 | `ICloudManager.swift:133-143` | 安全 | diagnostics 输出 `ubiquityIdentityToken` 描述与容器绝对路径；应只输出布尔值 |
| S-13 | `ICloudManager.swift:600-627` | 一致性 | metadata 旁路文件读写不经 NSFileCoordinator，与主文件操作并发不一致；建议纳入协调器或指纹内嵌主文件 |
| S-14 | `supabase_provider.dart:158-171` | 资源泄漏 | `dispose()` 中途 `disconnect()` 抛异常会跳过后续清理；应用 try/finally 确保全部执行 |
| S-15 | `ICloudManager.swift:414-457`（待确认） | 一致性 | `listFiles` 依赖本地目录枚举，iCloud"仅云端未下载"条目可能不出现（受 iOS 版本/优化存储影响）；建议 NSMetadataQuery 兜底，真机验证 |

### Supabase/iCloud 已声明修复核验结论

1. **batchDelete autoFilterByUser** ✅ 正确落地（含接口契约）；但**同目标下 `getById` 漏网**（S-5）。
2. **P-M6（query limit/offset range 修复）** ✅ 核算正确。
3. **P-M3（removeChannel 先退订再移除）** ❌ **未正确落地**——finally 语义与注释相反（S-4）。
4. **C3/C4/C5（连接状态真实化）** ⚠️ 部分落地：状态改为由 subscribe 回调驱动（✅），但 `disconnect()` 未主动断 socket、dispose 后无 isClosed 守卫（S-8）。

---

## 9. S3 / WebDAV 包问题清单

### P2 — 中等

#### W-1 WebDAV `initialize` 重复调用不释放旧 dio client
- **位置**：`packages/flutter_cloud_sync_webdav/lib/src/webdav_provider.dart:80-87`
- **类型**：资源泄漏
- **代码事实**：`_client = webdav.newClient(...)` 直接覆盖旧引用，未先 `_client?.c.close()`（对比 S3Provider 的 S-M2 修复已处理同问题）。配置切换/测试连接（`cloud_service_page` 反复触发 `createCloudServices` → `initialize`）时旧 HTTP 连接泄漏。
- **改进建议**：initialize 开头释放旧 client（与 S3Provider 一致）。

#### W-2 WebDAV/S3 初始化与错误路径可能回显含凭据的 URL
- **位置**：`webdav_provider.dart:107-108`（`'Failed to initialize WebDAV: $e'`）、`s3_provider.dart:102-105`（`'Failed to initialize S3: $e'`）
- **类型**：安全
- **代码事实**：`$e` 可能含 endpoint/URL 全文；若用户配置 `https://user:pass@host/dav` 形式，错误信息（会展示到 UI/日志）含明文凭据。
- **改进建议**：错误回显前对 URL 脱敏（复用 `obfuscatedUrl()` 模式）。

### P3 — 建议

| 编号 | 位置 | 类型 | 建议 |
|---|---|---|---|
| W-3 | `s3_auth_service.dart:43-45` | 健壮性 | `authStateChanges` 返回单订阅流 `Stream.value(...)`（与 NoopAuthService 的 `asBroadcastStream` 不一致）；若两处同时 listen 会抛"已监听"异常。当前 `lib/` 无监听者（潜伏），建议改 broadcast |
| W-4 | `s3_client.dart:92-115` | 性能 | S3 `_retry` 指数退避无 jitter（F-16 关联）；多设备同时失败时重试风暴 |
| W-5 | `s3_storage_service.dart:178-195` | 性能 | `download()` 全量 `getObject` + `utf8.decode` 无大小上限；超大快照内存峰值高。建议加大小上限或流式 |
| W-6 | `webdav_storage_service.dart:283-324` | 异常处理 | 元数据旁路文件读写失败静默降级（与 Supabase S-9 同模式）；指纹丢失时 getStatus 退化为全量下载，属自愈但排障困难 |
| W-7 | `webdav_provider.dart:73-78` | UX | 无 scheme 的地址报"当前为 ://"，文案不友好；且 `davs` scheme 是否被 webdav_client 支持未验证 |

### S3 / WebDAV 已声明修复核验结论

1. **P1-2 S3 查询串编码** ✅ 正确（`s3_client.dart:558-570` 手动 encodeComponent + `uri.replace(query:)`，签名侧 `s3_signature.dart:100-105` 解码重编码一致；回归测试断言 `%20`）。
2. **P2-7 WebDAV HTTPS 强制** ✅ 正确（`webdav_provider.dart:71-78`），错误信息不含凭据（W-2 为残留边角）。
3. **S-M2 S3 initialize 释放旧 client** ✅ 正确（`s3_provider.dart:73`）；⚠️ WebDAV 同问题未处理（W-1）。
4. **W-M2/W-M5 等（404 判定、原子上传、元数据侧车文件）** ✅ 已正确落地（本次复核）。

---

## 10. 问题统计与优先级汇总

### 10.1 统计

| 层级 | P1（重要） | P2（中等） | P3（建议） | 小计 |
|---|---|---|---|---|
| 应用层（lib/） | 4（A-1/A-2/A-3/A-7） | 11（A-4~A-6, A-8~A-15） | 10（A-16~A-25） | 25 |
| 核心包（flutter_cloud_sync） | 3（F-1/F-2/F-3） | 7（F-4~F-10） | 6（F-11~F-16） | 16 |
| Supabase / iCloud 包 | 1（S-1） | 7（S-2~S-8） | 7（S-9~S-15） | 15 |
| S3 / WebDAV 包 | 0 | 2（W-1/W-2） | 5（W-3~W-7） | 7 |
| **合计** | **8** | **27** | **28** | **63** |

> 注：其中 **框架潜伏项 11 个**（F-2/F-3/F-5/F-6/F-9/F-10/F-15、S-3/S-4/S-5/S-8/S-10）——`DatabaseSyncManager`/`SupabaseRealtimeService` 当前未被快照同步激活路径调用，一旦启用即触发；**激活路径项 52 个**。

### 10.2 按审查维度分布

| 维度 | 主要问题 |
|---|---|
| 同步触发条件 | A-1（无防抖/串行）、A-12（无重试/离线队列）、A-15（启动双路重复） |
| 数据一致性 | A-3（重复导入）、A-4（元数据指纹缺失）、A-9（rename 幽灵实体）、A-10（转账静默丢弃）、F-2（LWW 倒置）、F-4（metadata 指纹信任）、F-5（队列不持久） |
| 网络请求处理 | A-2（timeout 不取消）、F-16（框架未接入 RetryHelper）、S-2（list limit=100）、S-1（SDK 重复初始化） |
| 冲突解决 | A-3/A-7（LWW + 静默失败）、P3-5 暂缓（无冲突 UI）、F-2/F-9（乐观锁缺失） |
| 状态管理 | A-6（部分失败误报）、F-14（notAuthenticated 缓存）、S-6/S-7（iCloud 登出竞态）、S-8（连接状态失真） |
| 异常处理 | A-5（字符串耦合+吞异常）、A-7（apply 静默失败）、A-10（导入吞异常）、F-13（错误信息泄露）、S-9/S-10 |
| 安全 | F-1（导入回写明文）、F-7/F-8（凭据迁移竞态/降级）、S-12（诊断泄露）、W-2（URL 回显） |
| 资源管理 | A-11（provider 重建泄漏）、F-10/S-8（dispose 后 StateError）、W-1（WebDAV 重初始化泄漏） |
| 性能 | A-13/A-15/A-16（串行/双路/双下载）、F-11（主 isolate 哈希）、S-11（base64 大包） |

### 10.3 优先级修复建议

1. **立即（P1，激活路径）**：
   - A-1 自动上传串行化/防抖（并发覆盖 → 数据丢失）
   - A-2 timeout 不取消底层操作（失败报错但数据已落地）
   - A-3 `downloadRemoteLedger` 复用账本去重（重复交易）
   - A-7 apply 失败可见化（静默 0 条）
   - F-1 `config_export_service` 改走 `CloudServiceStore`（迁移后导出丢配置/导入回写明文）
   - S-1 Supabase 配置切换（SDK 重复 initialize 静默失效）
2. **近期（P2）**：
   - A-4 元数据纳入指纹；A-5 去字符串耦合；A-6 部分失败提示；A-8 按需导入元数据；A-9 账户/分类 syncId 锚定；A-10 导入失败不吞；A-11 dispose 链；A-12 失败重试
   - F-4 指纹与内容绑定校验；F-7 迁移竞态；S-2 list 分页；S-6/S-7 iCloud 登出状态
3. **框架层（潜伏项，启用前必修）**：F-2 LWW 倒置、F-3 队列丢弃、F-5 队列持久化、S-3 filter 错配、S-4 P-M3 未落地、S-5 getById 过滤
4. **性能**：F-11（isolate 哈希）、A-13/A-15/A-16、S-11（iCloud 大包）

---

## 11. 总体结论

本次审查在上一轮 13 项修复的基础上，共确认 **63 个问题**（P1×8、P2×27、P3×28），其中 52 个位于当前激活路径。主要结论：

1. **上轮 13 项修复 10 项正确落地**（P1-1/P1-2/P2-1/P2-3/P2-6/P2-7/P2-8/P2-9/P2-4/P3-1/P3-3 等），但发现 **3 处修复引入或遗漏的新问题**：P2-4 凭据迁移破坏了 `config_export_service` 导出/导入（F-1，P1）；P1-4 超时修复不取消底层操作（A-2，P1）；P1-3 部分失败仍被吞（A-6，P2）；另有 P-M3（S-4）注释与实现相反、未正确落地。
2. **最严重的数据风险在应用层自动上传路径**：快照同步无防抖/无串行（A-1）+ 恢复路径无去重（A-3）+ apply 静默失败（A-7）组合下，用户在弱网/快速连续记账场景有实际数据丢失或重复风险。
3. **框架层 DatabaseSyncManager 隐患最集中**（LWW 倒置、队列丢弃、无持久化），当前虽未激活，但一旦接入即是 P0/P1 级缺陷，强烈建议在启用前完成 F-2/F-3/F-5 修复。
4. **凭据安全链存在断裂**：secure storage 迁移本身正确，但导出/导入旁路（F-1）、降级明文（F-8）、迁移竞态（F-7）使整链仍不完全闭合。
5. **测试缺口**：无并发上传、timeout 行为、重复导入、元数据脏检测、部分失败可见性的测试；框架修复（retry_helper）无测试覆盖。
