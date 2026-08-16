# 快照链路附件二进制同步设计（attachment_binary_sync）

## 需求理解

让 WebDAV/S3/Supabase/iCloud 快照链路（Path A）在账本 JSON 之外同步附件二进制：附件按内容寻址作为独立云对象存储，快照清单携带哈希引用，恢复端后台补齐文件。不改动 Cloud 链路与存储接口。

## 关键技术决策

1. **独立内容寻址对象，不内嵌 JSON**：备选方案是 base64 塞进 `ledger_<id>.json`，否决——整个快照体积膨胀 33%+、JSON 解析内存峰值不可控、无法部分重试、无法跨账本去重。采用 `attachments/<sha256>.bin` 独立对象 + 清单引用：
   - 去重语义与 Cloud 链路对齐（server 按 user+sha256 去重），同一张发票附在两笔交易上只传一份；
   - 上传失败只影响单个对象，ledger JSON 的上传不被大文件拖累。
2. **复用 String 存储接口，base64 编码传输**：`CloudStorageService` 无二进制方法；扩接口需改 4 个存储实现 + 加密装饰器 + 加密服务二进制 API，收益仅省 33% 体积。折中：`base64(bytes)` → `encrypt(String)` → 上传。开销为 base64 1.33x × 密文再编码约 1.33x ≈ 1.78x，照片场景（1–5MB）在 WebDAV/S3 可接受。`download` 反向：`decrypt` → `base64解码` → `sha256 校验`。**校验必做**——内容寻址的信任根基是"路径即哈希"。
3. **`localSha256` 独立成列**，不复用 `cloudSha256`（Cloud server 回填的引用，语义属于另一条链路；混用会导致 Path A 写入的哈希被 Cloud 链路误当已上传引用）。维护时机：
   - `attachment_service` 保存附件时同步计算落列（新增文件本来就要读全量字节，无额外 I/O）；
   - 迁移回填只对 `localSha256 IS NULL` 且本地文件存在的行执行，分批（每批 200 条）避免启动卡顿；文件缺失置 null 并 warning（孤儿扫描器已有同类报告机制）。
4. **上传顺序协议**：附件对象先于 ledger JSON（清单引用的对象必须先存在，否则恢复端拿到"永远缺文件"的清单）。单附件上传失败不阻断账本上传——清单里仍带 sha256（恢复端会持续尝试下载），但日志 warning + 上传结果汇总里报告失败数。重复上传去重靠 `exists()`（GET metadata，成本低）。
5. **恢复端后台 drain**：恢复主事务只落元数据（现状）+ 将缺失文件的任务入队 `pendingAttachmentJobs`；事务提交后并发下载（semaphore 4、3 次指数退避、失败回队，对齐 `drainCustomIconQueue` 模式）。**不阻塞**阻塞弹窗关闭——附件下载可能分钟级，交易数据必须先可用；进度通过日志/后续 UI 增强（本期仅日志）。

## 实现步骤（≤5）

1. **DB 迁移**（`lib/data/db.dart`，版本取 sync_gap_closure 之后的下一可用版本）：`transaction_attachments` 加 `local_sha256` TEXT 列；`flutter drift` 重新生成；启动后台一次性回填（`attachment_service` 新增 `backfillLocalSha256()`，分批 + 文件缺失置 null）。
2. **上传侧**（`lib/cloud/transactions_sync_manager.dart`）：新增 `uploadAttachmentObjects(ledgerId)` —— 收集该账本 `localSha256` 非空的附件 → `exists()` 过滤 → base64+encrypt 上传 `attachments/<sha256>.bin`（semaphore 4 + retry）；`uploadCurrentLedger` 与「全部上传」入口在传 ledger JSON **之前**调用。
3. **清单扩展**（`lib/cloud/transactions_json.dart`）：`items[].attachments[]` 每项加 `'sha256': a.localSha256`（非空才写，旧快照兼容）。
4. **恢复侧**（`lib/cloud/transactions_sync_manager.dart`）：`downloadAndRestoreToCurrentLedger` / `importRemoteLedger` 完成元数据导入后，解析清单收集 `{sha256, fileName}` 且本地文件缺失的条目入 `pendingAttachmentJobs`；新增 `drainAttachmentJobs()`：下载 → decrypt → base64 解码 → sha256 校验 → 落盘，失败回队；在下次同步/启动检查时 drain。
5. **验证**：`flutter analyze`；单测（内存版 FakeStorageService）覆盖：同内容去重只传一份、sha256 校验失败拒写、旧快照无 sha256 字段不崩、加密往返；两台 dev 实测验收标准场景。

## 边界条件与风险

- **体积与流量**：1.78x 编码开销 + 首次全量上传可能数百 MB（照片重度用户）。缓解：exists() 去重 + 只传 `localSha256` 非空且对象不存在的；后续可加"仅 Wi-Fi 同步附件"开关（不在本期）。
- **WebDAV 服务器限制**：部分服务器对单文件大小/请求超时有限制（坚果云等）。大文件失败回队重试，不阻断；极端情况附件长期缺失但交易数据完好——降级可接受。
- **清单与对象竞态**：附件 A 上传成功、B 失败，ledger JSON 仍上传（B 在清单中有 sha256 但对象缺失）→ 恢复端 drain 反复失败回队。可接受：恢复端失败任务不影响主流程；上传端日志+结果汇总暴露失败数。
- **删除不同步**：交易删除后其附件对象成为孤儿（其他交易可能仍引用同 sha256，不能顺手删）。本期不 GC；云端配额敏感用户需手动清理（后续"全量对账 GC"立项，需跨账本引用计数）。
- **迁移不可逆**：加列向前兼容（旧版本读多余列不报错），但回填任务一旦执行不能撤销；先在 dev 库演练。
- **与 sync_gap_closure 的发布顺序**：两者都动 `transactions_json.dart` 与指纹相关输入（附件 sha256 若纳入指纹会再漂移一次）。**建议同版本发布**：指纹漂移合并为一次；若必须分开发，本期 sha256 不进指纹（附件不影响交易数据一致性判断，可接受）。
- **iCloud 特殊性**：iCloud Drive 对程序化写入有同步延迟与 `.icloud` 占位文件语义，`exists()` 可能误判。icloud 实现包本期不深度适配，风险记录，实测后补。
