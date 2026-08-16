# 账户元数据同步修复设计（account_metadata_sync_fix）

## 技术决策

1. **元数据合并不依赖交易 diff（修 G1+G2）**：把 `applySyncChanges`（`sync_diff_service.dart:316`）中的分类/账户/标签导入（现 326-336 行）移到 `if (selectedChanges.isEmpty) return` 早退**之前**，空变更时完成元数据合并后返回空 `SyncApplyResult`。UI 侧（`cloud_sync_page.dart:881-883`）把 `preview.isEmpty → continue` 改为：不弹预览框，直接调 `applyPreviewChanges(selectedChanges: const [], importData)` 做纯元数据合并。
   - 理由：`importAccounts` 本身是安全增量 upsert（syncId 优先 → name 回退回填 → 新建，null 字段保持本地原值），即使每个账本都执行一次也是幂等的（账户是 user-global，多账本循环下 N 次合并结果一致）；复用既有导入逻辑，不在 UI 层直接触碰 `DataImportService`。
   - 取舍：不做 computeDiff 账户 diff（G3）——那需要设计账户变更的预览展示与选择语义，而账户合并无破坏性（不删除本地账户），静默合并即可，改动面最小。
2. **用户取消预览时仍不合并元数据**：`cloud_sync_page.dart:892-894` 的 `selected == null || selected.isEmpty → continue` 保持不变。理由：用户明确取消了本次同步操作，应尊重取消语义；核心场景（preview 为空，无框可取消）已由决策 1 覆盖。
3. **指纹纳入账户（修 G4）**：`contentFingerprintFromMap`（`sync_fingerprint.dart`）在交易 canon 之外，对顶层 `accounts` 数组单独规范化：每账户抽取 `syncId/name/type/currency/initialBalance/creditLimit/billingDay/paymentDueDay/bankName/cardLastFour/note/hidden/sortOrder`，缺省值兜底，按 `syncId ?? name` 排序后与交易 canon 一起参与 sha256。
   - 兼容性：本地与云端指纹都是运行时从各自 JSON 内容用同一函数现算（`transactions_sync_manager.dart:412/750/1650`），无存量存储指纹，算法升级无需迁移。
   - 排序必要性：账户导出顺序取决于 `getAllAccounts` 的查询顺序，两端可能不同，必须排序后哈希，否则会误报差异。
4. **不动的东西**：`exportTransactionsJson` 载荷格式（version 保持 7，`accounts` 数组已存在）；`downloadAndPreview`；旧格式（v5-）全量替换路径；`restoreAllRemoteLedgers` 跳过逻辑。

## 实现步骤（≤5）

1. `lib/cloud/sync_diff_service.dart`：`applySyncChanges` 将元数据导入（importCategories/importAccounts/importTags）上移到空变更早退之前；早退改为完成元数据合并后 `return const SyncApplyResult()`。补注释说明「元数据合并不依赖交易 diff」的原因。
2. `lib/pages/cloud/cloud_sync_page.dart`：下载循环中 `preview.isEmpty` 分支改为直接调用 `applyPreviewChanges(selectedChanges: const [], importData)`（不弹框），保留日志。
3. `lib/cloud/sync_fingerprint.dart`：新增账户规范化与排序，并入指纹；更新文档注释（规范化规则补「账户数组排序后参与指纹」）。
4. 测试：扩展 `sync_fingerprint` 测试（仅账户变更 → 指纹不同；账户顺序不同内容同 → 指纹相同）；为 `applySyncChanges` 空变更合并元数据补测试（若无现成测试文件则新建最小用例）。
5. `flutter analyze` + `flutter test`（相关目录）+ `flutter gen-l10n`（如涉及）。

## 追加修复（第二轮）：启动检查器两处跳过点（G5）

真机验证发现：指纹修复后 StartupSyncChecker 已能正确识别「云端有更新」（12 个候选账本），但应用阶段与手动下载按钮存在同样的缺口——

| # | 缺口 | 位置 | 影响 |
|---|------|------|------|
| G5 | `_applyAll`（一键应用）对 `preview.isEmpty` 直接跳过 | `lib/cloud/startup_sync_checker.dart:590-594` | 用户点「全部应用」后纯账户变更仍不落库 |
| G5' | `_confirmEach`（逐个确认）对 `preview.isEmpty` 直接跳过 | `lib/cloud/startup_sync_checker.dart:687-690` | 同上 |

**修复策略（与 cloud_sync_page 决策 1 对齐）**：两处 `preview.isEmpty` 分支改为静默调用 `applyPreviewChanges(selectedChanges: const [], importData)` 完成纯元数据合并：

- `_applyAll`：用户已选择「全部应用」，静默合并元数据符合既有授权；沿用 try/catch 错误处理（失败计 failCount）。
- `_confirmEach`：preview 为空意味着无交易变更，弹逐账本对话框只会展示空列表（无意义）；元数据 upsert 无破坏性（不删除、不覆盖非空本地字段），静默合并与 cloud_sync_page 的决策一致。

**实现步骤（追加）**：

1. 更新 `_applyAll` 跳过分支：空 preview → `applyPreviewChanges(空变更)` + `runAfterDownload()` + `successCount++`（与有变更路径相同的收尾）。
2. 更新 `_confirmEach` 跳过分支：同上（该模式无计数汇总，仅 log）。
3. 测试：在 startup_sync_checker 测试中补 applyAll/confirmEach 两路径的「preview 为空仍合并元数据」用例。

## 边界与风险

- **决策 1 副作用**：交易确有 diff 但用户全不选时（`selected.isEmpty → continue`）元数据也不合并 —— 有意为之（决策 2），用户重新下载即可。
- **指纹升级的一次性「差异」表现**：升级后首次比较，若本地与云端账户本就一致则指纹仍一致；若云端快照是旧代码上传且账户有差异（正是本次要修的场景），状态从误报 inSync 变为 different/cloudNewer —— 这是修正而非回归。direction=unknown（时间戳相等）不弹窗的既有约束不受影响。
- **余额覆盖语义**：`importAccounts` 对已命中账户「仅非空字段覆盖」，云端快照的余额（last-writer-wins）会覆盖本地 —— 快照同步既有语义（account_sync_fix 已记录），不新增风险。
- **旧快照（修复前上传）**：仍只含被交易引用的账户，需 dev2 重新「全部上传」生成含全量账户的新快照后，dev1 下载才能补齐（运维前提，非代码可修）。
- **多账本循环冗余**：账户 user-global，逐账本合并会重复执行 N 次 upsert，幂等无害；账户量级小（几十条），性能可忽略。
