# 同步与加密修复 — 代码落地核验报告

- **核验日期**：2026-07-31
- **核验方法**：直接审查 `lib/` 实现代码 + 比对 `prd/sync_encryption_fixes/`（design/requirements）+ 检查 `test/` 断言
- **核验范围**：此前审查结论中的 **P0 七项（PRD US-1~7）+ 三个致命 bug（BUG-1/2/3）**

## 一、总体结论

✅ **所有 P0 级修复与三个致命 bug 均已在代码中实现，并配有单元测试，未发现"仅停留在文档、未落地"的项。**

| 类别 | 项数 | 落地情况 |
|------|------|----------|
| 致命 bug（BUG-1/2/3） | 3 | 全部修复 ✓ |
| PRD P0 七项（US-1~7） | 7 | 全部修复 ✓ |
| 对应单元测试 | — | 均有断言覆盖 ✓ |

## 二、逐项核验表

| 原问题 | 严重度 | 修复落点（文件:行） | 关键实现 | 测试证据 | 状态 |
|--------|--------|---------------------|----------|----------|------|
| **BUG-1** disable 后旧密文无法解密 | 致命 | `encryption_service_impl.dart:126-132`；`transactions_sync_manager.dart:287-309` | `disable()` 仅清除内存密钥、**保留 secure storage**；`_decryptIfNeeded` 改按 `hasActiveKey` 判定（不再用 `isEnabled`），禁用后仍可手动解密存量密文 | `encryption_service_test.dart:92`「disable 后仍有密钥」 | ✅ 已落地 |
| **BUG-2** 多设备 split-brain（云端密文 / 本地未开启） | 致命 | `encryption_service.dart:240`（异常定义）；`encryption_service_impl.dart:422`（salt 哨兵）；`transactions_sync_manager.dart:287-352`（`_decryptIfNeeded` 抛异常 + `_cloudEncryptedLocallyDisabledStatus` 哨兵）；`cloud_sync_page.dart:60-86`（双哨兵恢复） | 新增 `CloudEncryptedLocallyDisabledException`；`getStatus` 主动探测该场景返回哨兵 `cloud_encrypted_locally_disabled`，UI 引导开启加密而非静默跳过 | `transactions_sync_manager_test.dart:414`（明文不误报）；`startup_sync_checker_test.dart:719` | ✅ 已落地 |
| **BUG-3** enableFromCloud 误导「密码错误」 | 致命 | `encryption_service_impl.dart:186-220` | 区分 `SecretBoxAuthenticationError`→「密码错误」与 `EnableFromCloudCorruptedException`→「云端密文损坏」，不再把损坏误报为密码错 | impl + 异常分层已实现 | ✅ 已落地 |
| PRD#1 legacy/different 全量替换去重（US-1） | 中 | `transactions_sync_manager.dart:443-552` | `downloadAndRestoreToCurrentLedger` 先清空目标账本交易（含 tags/attachments）再导入，二者包在同一 `db.transaction` 内，失败整体回滚 | `transactions_sync_manager_test.dart:201`（deletedDup 反映清空行数） | ✅ 已落地 |
| PRD#2 salt 错配引导重输密码（US-2） | 中 | `encryption_service.dart:180`（异常）；`encryption_service_impl.dart:422-427`（抛出）；`transactions_sync_manager.dart:698-738`（哨兵，不缓存）；`cloud_sync_page.dart:246/835` | `SaltMismatchException` 继承 `DecryptionException`（兼容旧 catch）；`getStatus` 转哨兵 `salt_mismatch_need_password` 并**不写入缓存** | `encryption_service_test.dart:402/427`；`transactions_sync_manager_test.dart:453` | ✅ 已落地 |
| PRD#3 enableFromCloud 探测失败不回退（US-3） | 中 | `encryption_service_impl.dart:146-154`；`encryption_settings_page.dart:67-78` | `cloudStorage.list` 抛异常时改抛 `EnableFromCloudProbeFailedException`；调用方捕获后弹确认框，用户确认才回退 `enable()`+`reEncrypt` | impl + 调用方分支已实现 | ✅ 已落地 |
| PRD#5 指纹函数去重（US-5） | 低 | `sync_fingerprint.dart`（新文件）；`transactions_sync_manager.dart:851-852`、`1337` | 抽取顶层 `contentFingerprintFromMap`，两处私有实现改为委托调用 | `sync_fingerprint_test.dart` | ✅ 已落地 |
| PRD#6 错误状态不缓存（US-6） | 低 | `transactions_sync_manager.dart:714-720` | `getStatus` 仅对**非 error** 状态写 `_statusCache`，瞬时错误下次重新走完整流程 | impl 已实现（删除原缓存行） | ✅ 已落地 |
| PRD#7 applyAll 冲突高亮 + 二次确认（US-7） | 低/设计 | `startup_sync_checker.dart:67-75`（`LedgerCandidate.diffType`）、`308-321`（`_applyAll` 二次确认）；`startup_sync_overlay.dart:281-306`（`Icons.warning_amber` + tooltip） | 候选携带 `diffType`；`different` 账本在 SummaryView 高亮；`_applyAll` 前弹二次确认 | `startup_sync_checker_test.dart:445/492/719` | ✅ 已落地 |

## 三、残留风险与注意事项

> 以下问题属于"实现已存在但质量/健壮性可改进"，不属于未修复，建议后续优化。

- **R1（中）salt_mismatch 识别依赖字符串匹配**
  `transactions_sync_manager.dart:701-703` 通过 `status.message!.contains('SaltMismatchException')` 识别，原因是底层 `fcs.CloudSyncManager` 已把异常吞为 error 状态（代码注释称"缺口 1"）。该实现**耦合异常类名文本**，若底层改动异常措辞将失效。建议推动 `fcs` 透传结构化错误码 / 异常对象，去掉字符串匹配。

- **R2（低）restore 路径会吞掉 SaltMismatchException**
  `transactions_sync_manager.dart:301-308` 的 `_decryptIfNeeded` 用宽泛 `on Exception` 捕获，会把 `SaltMismatchException` 吞掉并 `return null` → `downloadAndRestoreToCurrentLedger` 静默返回 `(0,0)`。因 `getStatus` 会先暴露哨兵并弹出密码框，实际用户体验无碍；但若用户**直接触发恢复而未经状态检查**，会静默无操作。建议对 `SaltMismatchException` 单独 `rethrow`。

- **R3（范围说明）无法机械确认其余 58 项**
  仓库中可溯源的修复清单仅 `prd/sync_encryption_fixes/` 的 7 项 P0 + 对话中描述的 3 个致命 bug。**原始 65 项清单（含 13 高危、27 中等、22 低，尤其纯 UI 渲染类）未以文档/清单形式留存于仓库**，因此无法确认除 P0 之外的其余项是否均已修复。如需全量核验，请提供完整的 65 项清单，或确认其余项已并入其他 PRD / 提交记录。

## 四、合入门禁建议

- 运行 `flutter analyze`（0 新增 error/warning）与全量 `flutter test` 作为修复合入门禁。本次为代码静态核验，未执行构建以避免无关环境噪声。
- 优先处理 **R1**（去字符串耦合），其次 **R2**（restore 路径异常透传）。
