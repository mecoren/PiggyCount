# 快照链路附件二进制同步需求（attachment_binary_sync）

## 需求理解

WebDAV 等快照链路（Path A）目前只同步附件**元数据**（v7/v8 快照 `items[].attachments`），二进制文件本体仅走 PiggyCount Cloud 链路（cloudFileId）。纯快照用户换设备后，附件列表存在但文件指向不存在的本地路径，点击预览失败。本需求让附件二进制也走快照链路，使 Path A 用户换设备附件完整可用。

## 现状盘点（代码级）

| 环节 | 现状 | 位置 |
|---|---|---|
| 附件本地存储 | `{appDocDir}/attachments/<fileName>`，缩略图在临时目录（不同步，可重建） | `sync_engine_attachments.dart:289` |
| 快照元数据 | v7 起已含 fileName/originalName/fileSize/width/height/sortOrder/cloudFileId/cloudSha256 | `transactions_json.dart:226` |
| Cloud 二进制 | `provider.uploadAttachment` 上传，server 按 sha256 去重，回填 cloudFileId/cloudSha256 | `sync_engine_attachments.dart:119` |
| 存储接口 | `CloudStorageService.upload(path, data: String)` **纯字符串**，无二进制方法；4 个实现（WebDAV/S3/Supabase/iCloud）+ 加密装饰器均基于 String | `packages/flutter_cloud_sync/lib/src/core/storage_service.dart:55` |
| 加密层 | `EncryptedCloudStorageService` 对 String 透明加解密（BEECRYPT1 magic header 自动识别） | `encrypted_cloud_storage.dart:20` |

## 需求范围

### R1 附件对象上传（内容寻址）
- 每个附件二进制作为**独立云对象**上传：`attachments/<sha256>.bin`，与 `ledger_<id>.json` 同级。
- 内容寻址去重：相同内容（sha256 相同）只存一份，多笔交易/多账本共享同一对象；上传前 `exists()` 探测，已存在则跳过。
- 经 `EncryptedCloudStorageService` 上传（base64 编码为 String 后走既有 encrypt），加密语义与账本快照一致。

### R2 本地内容哈希维护
- `transaction_attachments` 新增 `localSha256` 列（DB 迁移，版本号取当时下一个可用版本；若 sync_gap_closure 已占 v33 则本需求用 v34）。
- `attachment_service` 写入附件时计算并落列；迁移对既有行回填（读文件算哈希，文件缺失则置 null 并 warning）。
- 不复用 `cloudSha256`：该列语义是 Cloud server 回填的引用，混用会让两条链路互相污染。

### R3 快照清单扩展
- `items[].attachments[]` 每项补 `sha256`（即 localSha256）。
- 上传顺序：先传全部缺失的附件对象，全部成功（或明确跳过）后再传 `ledger_<id>.json` —— 保证清单引用的对象必然存在。

### R4 恢复下载
- 快照恢复（下载恢复/云端账本导入）后：对本地文件不存在的附件，从 `attachments/<sha256>.bin` 下载、校验哈希、落盘到本地 attachments 目录（文件名用清单里的 fileName）。
- 下载在后台并发执行（semaphore 4 + 指数退避 retry，对齐 Cloud 链路 `_uploadOneWithRetry` 模式），**不阻塞**恢复主流程；UI 可展示进度但恢复结果不以附件下载完成为前提。
- 失败的下载进入待重试队列，下次同步触发时 drain（对齐 `drainCustomIconQueue` 回队模式）。

### R5 入口整合
- 「全部上传」= 全账本（JSON + 附件对象）；「单个账本上传」同步只传该账本引用的附件对象。
- 上传/恢复的阻塞弹窗遵循既有 `showBlockingProgressDialog` 规范（memory: 手动同步必须阻塞）。

## 非目标

- **对象 GC**：内容寻址对象被多账本共享，本期不做引用计数删除；孤儿对象（附件已删但 .bin 还在）可接受，后续按「全量对账清理」单独立项。
- **缩略图**：本地临时目录缓存，恢复端自行重建，不同步。
- **Cloud 链路附件**：已稳定运行，不改动。
- **分类自定义图标二进制**：图标走 Cloud 的 category-icons 机制；快照链路图标是否二进制化后续评估（量小但 user-global，语义不同）。

## 验收标准

- dev2 给两笔交易附上同一张图片（同内容）→ 全部上传 → 云端 `attachments/` 下只有 1 个 .bin；dev1 全部恢复后两笔交易均可预览附件，文件字节级一致（sha256 校验通过）。
- 断网中途恢复：交易数据先落地可用，附件后台重试，恢复联网后 drain 补齐。
- 加密开启时，云端 .bin 为密文（无 magic bytes 可识别原图格式）；密码错误的设备无法解出。
- 未同步过附件的旧快照（无 sha256 字段）恢复不报错，附件保持现状（本地缺失）。
- `flutter analyze` 无新增告警。
