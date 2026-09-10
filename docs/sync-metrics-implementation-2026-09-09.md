# 同步监控机制实施记录（审计 P0-1 / P1-3 / P1-6 落地）

- **实施日期**: 2026-09-09
- **对应问题**: `docs/s3-webdav-sync-audit-2026-09-08.md` §三 P0-1（同步成功率零测量）、P1-3（软失败无计数出口）、P1-6（槽位补删仅内存）；方案源头 `docs/sync-normalization-audit-2026-09-07.md` §五
- **回归验证**: `flutter analyze` 0 error / 0 warning（661 条 info 为既有基线）；全库 `flutter test test/` **1064 项全过**（含新增 sync_metrics_service 15 项、v43 迁移 2 项）；受影响包（icloud/supabase/s3/webdav）本轮未改动

---

## 一、v43 数据库迁移（db.dart schemaVersion 42 → 43）

| 表 | 用途 | 关键列 |
|---|---|---|
| `sync_op_log` | 同步操作结构化指标（P0-1 存储） | ts(默认当前时间, 建索引 idx_sync_op_log_ts) / backend / scenario / outcome / errorClass / ledgerId / attempts / durationMs |
| `stale_remote_slots` | 换名收尾补删登记（P1-6 持久化，主键 path） | path / createdAt |

onUpgrade（v42→v43：`migrator.createTable` 两表 + ts 索引）与 onCreate（新装库 `createAll` + 同款索引）双路径同构——对齐项目内 v32/v35/v39 的既有纪律。迁移冒烟测试 `test/data/migration_v43_sync_metrics_test.dart` 覆盖两条路径。

## 二、SyncMetricsService（新文件 lib/cloud/sync_metrics_service.dart）

- **场景枚举**（99.9% 分母口径）：snapshotUpload / snapshotRestore / startupCheck / attachmentFill / cloudBackup / remoteDiscovery，label 稳定落库；
- **结果四态**：success / failed / **soft_fail**（P1-3 核心：操作成功但数据未收敛，独立于 failed 可查）/ **conflict**（并发保护拦截，**不计入成功率分母**——它是三层防护正确工作的证据，算失败会把双设备正常并发误报为质量问题）；
- **成功率口径**：`success / (success + failed + soft_fail)`；窗口为空返回 null（UI 显示「暂无数据」而非 0%）；
- **API**：record（fire-and-forget 吞错）/ summarize（窗口 + 按后端分组聚合）/ topErrorClasses（Top 失败归因）/ cleanupExpired（30 天滚动清理）/ exportJson（诊断导出，仅结构化字段）/ classifyError（六类错误归因：precondition → auth → timeout → gateway → dataCorruption → unknown，全链路单点口径）；
- **隐私合规**（PRIVACY.md 零遥测承诺）：纯本地测量、不上云、不自动外发、不落用户内容（账本名/凭据/堆栈一概不进表）。

## 三、埋点接线（全部为纯旁路，metrics 未注入或落库失败均 no-op）

| 位置 | 场景 / 出口 |
|---|---|
| TSM `_uploadCurrentLedgerCore` | snapshotUpload 四态：M7 拦截 → conflict；条件写 412 → conflict；verified=false → **soft_fail**；成功 → success（含 duration/ledgerId）；其余异常 → failed（排除 CloudConflictException 重复计数） |
| TSM `drainAttachmentJobs` | attachmentFill 逐任务：ok → success(attempts=3)；objectMissing → **soft_fail**；transientFailure → failed(attempts=3) |
| TSM `_downloadAndRestoreToCurrentLedger` | snapshotRestore：成功 / 密钥缺失(failed,auth) / 密文损坏(failed,data_corruption) / 网关 404 兜底不计 / 真实失败 → failed |
| TSM `importRemoteLedger` | snapshotRestore：导入成功 → success（带 newLedgerId）；任意异常 → failed |
| TSM `discoverRemoteLedgers` | remoteDiscovery：整轮成功 / 失败 |
| CloudBackupService `createBackup` / `restoreBackup` | cloudBackup / snapshotRestore：备份成功失败；恢复整体成功、**单账本失败 → soft_fail**（保留 P1-3 的部分收敛语义）、整体失败 → failed；metricsBackend 由 provider 从激活配置注入分组键 |

Provider 装配（`sync_providers.dart` / `cloud_backup_providers.dart`）：`syncMetricsServiceProvider` 共享单实例注入 TSM 与备份服务，健康卡/诊断导出同源；上传成功后 `metrics.cleanupExpired()` 与 local_changes 清理同批（滚动窗口近零成本）。顺手清理了 PiggyCountCloud 下线遗留的孤儿 `_bootstrappingConfigs`（既有 unused 警告）。

## 四、UI：同步健康卡（新文件 lib/pages/cloud/sync_health_card.dart）

挂在云同步页（云端备份卡之后，`canUseCloud` 条件下）：

- 近 30 天成功率（≥99.9% verified 图标 / ≥99% check / ≥95% warning / 其余 error）+ 四态明细行（成功 · 失败 · 未收敛 · 并发拦截）；
- Top 3 失败错误类别（网络超时/认证/网关/并发/数据完整性/其他）；
- 「导出诊断数据」：30 天窗口 sync_op_log → JSON（schema:1，仅结构化字段）→ 系统分享面板，用户主动触发，唯一出机通道；
- l10n×3（zh/en/ko 各 8 词条，placeholder 元数据在模板 app_en.arb）。

## 五、P1-6 槽位补删持久化

- 登记（换名收尾删除失败）→ `stale_remote_slots` 表 + 内存 Set 双写，DB 是事实源；落库失败降级旧行为（仅内存，本会话内补删）；
- 装载（初始化成功后）→ 从表恢复到内存缓存再统一补删（reinit/dispose 只清内存缓存，DB 行跨重启存活）；
- 补删成功 → 双侧移除。修复场景：downloadRemoteLedger 换名中断 + 进程重启后，旧槽位不再被「云端账本发现」当新账本重复导入（2026-09-07 双端实测踩中的 12 账本重复问题根因之一）。

## 六、99.9% 目标的达成路径（与 2026-09-07 报告 §五一致，现状更新）

1. ✅ 测量口径落地：核心场景分母 + soft_fail 单列 + conflict 排除已实现；
2. ✅ 展示与导出：健康卡 + 诊断包（用户可主动反馈，替代遥测）；
3. ⏳ 基线建立：功能随版本发布后以 30 天窗口观察 real-world 成功率；
4. ⏳ 差距消除：P1-2 超时自适应（已于 2026-09-08 落地）与 P1-1 重试策略层（部分落地）是预判的 top 失败类，健康卡的 Top 错误类别将验证该判断；实验室侧弱网档压测（带宽受限维度）待补。

## 七、测试清单

| 文件 | 覆盖 |
|---|---|
| `test/cloud/sync_metrics_service_test.dart`（15 项） | 四态计数与成功率口径、conflict 不入分母、空窗口 null、按后端过滤、时间窗口过滤、30 天清理、导出结构化字段（无用户内容断言）、classifyError 六类、label 稳定性、attempts 归一、stale_remote_slots 幂等 |
| `test/data/migration_v43_sync_metrics_test.dart`（2 项） | v42→v43 onUpgrade 两表可用 + ts 索引；onCreate 新装路径 |
| 既有 1064 项全量回归 | cloud/backup/providers 287 + data 93 + 其余全过，零失败 |


---

## 八、第二批实施（同日：P1-5 完整性硬校验 + P1-1 条件 PUT 安全重试 + LOG-06）

### P1-5：下载内容完整性终审（破坏性恢复前的硬闸门）

**问题**：core `CloudSyncManager.download` 的 P4 校验因 App 层全部直连 `provider.storage.download` 是死代码；实际运行的对位物只有「metadata 交叉软告警」——CDN 陈旧副本/网关截断的脏快照可无声流入破坏性恢复。

**实现**（`lib/cloud/transactions_sync_manager.dart` 新增 `_verifyDownloadedSnapshotIntegrity`，接线三个破坏性入口：`downloadAndRestoreToCurrentLedger` / `downloadRemoteLedger` / `downloadAndPreview`）：

- 基准取**快照内嵌指纹**（'contentFingerprint'）而非 metadata——内嵌值与内容同生共死，不存在「算法迁移错位」误报（换基准后软告警时代的 M2 迁移窗口问题不复存在）；
- 内嵌指纹 = 内容重算指纹 → 放行；
- 不一致 → **单次重下自愈**（陈旧副本窗口），返回值采用重下的新内容；仍不一致 → **硬失败**（CloudStorageException，恢复中止）；
- 内容非 JSON → 硬失败；
- 旧快照（v6 前无内嵌指纹）→ 退回 metadata 软告警路径（迁移窗口兼容，维持 M4 既有取舍）。

**测试**（`test/cloud/sync_integrity_hard_verify_test.dart` 6 项，走公共入口端到端验证）：自洽放行 / 非 JSON 硬失败 / 重下自愈采用新内容 / 持续不一致硬失败 / 旧快照兼容不阻断 / 预览链路同口径。

### P1-1 切片：S3 条件 PUT 网络故障安全重试

**安全性论证**（核心）：带 If-Match 锚点时，「超时但服务端已落盘」的 A-1 歧态由锚点化解——远端 ETag 已变 → 重试吃 412 → 翻译为冲突流程（上层走用户确认/合并），**绝不静默覆盖他机数据**；未落盘则重试正常落盘。盲写路径维持不重试纪律（A-1 未修，写后校验兜底）。

**实现**（`packages/flutter_cloud_sync_s3/lib/src/s3_client.dart`）：putObject 的 SocketException/TimeoutException 分支——`(ifMatch != null || ifNoneMatch) && netRetries < 2` 时按既有 `retryDelayForTest` 指数退避重试（≤2 次），并修正超时消息使用 `transferTimeoutFor(data.length)`（自适应档）；盲写原样上抛。

**测试**（`packages/flutter_cloud_sync_s3/test/s3_conditional_retry_test.dart` 5 项）：网络故障一次后重试成功 / 已落盘场景重试吃 412 转冲突（安全性核心用例）/ 持续故障 1+2 次后上抛 / 盲写不重试纪律 / onRetryEvent 逐次留痕。

### LOG-06：重试逐次日志

- S3：`onRetryEvent` 回调（新增字段），`_retryIdempotent` 的网络/5xx/时钟偏差三分支与 putObject 条件重试逐次上报，`S3StorageService` 构造时注入 `logger.info`（重试属正常自愈，非告警）；
- WebDAV：`_retryIdempotent` 重试分支直接 `logger?.info`（带 HTTP 状态码与次数）。

### 顺手修正：WebDAV 既有测试与实现不一致

`webdav_validate_status_test.dart` 的「null 状态放行」断言在 `9ecf378`（09-08 修复批）有意反转 `webdavValidateStatus` 的 null 语义（放行 null 会让 `_statusCodeOf` 拿不到结构化码、错误分类退化到字符串匹配）时未同步更新——修正断言对齐实现，并在用例名中记录理由。

### 回归验证

- `flutter analyze` 全库：0 error / 0 warning；
- 全库 `flutter test test/`：**1070 项全部通过**（基线 1064 + 本批净增）；
- 包套件：S3 129 项全过（含新增 5 项）、WebDAV 59 项全过、test/cloud 242 项全过；
- 一次全库混跑中 `sync_integrity_hard_verify_test`「内容非 JSON」用例偶发失败，单跑与 test/cloud 连跑 3 轮 + 全库重跑均绿——确认为偶发 flaky（非确定性调度），如再现优先怀疑测试并发环境而非实现。

### 本批后剩余待办

- P1-1 尾巴：四套重试收编单一 RetryPolicy 策略层（S3 条件重试与逐次日志已就位，收编主要是参数集中与 TSM 附件重试迁移）；
- P1-4（Supabase/iCloud 能力显式化）、P2-1/2/3/4、SEC-03/06/08、LOG-04/05——方案均已定，按批次推进。

---

## 九、第三批实施（同日：P1-4 能力显式化 + P2-6 参数文档 + LOG-01 收尾）

### P1-4：Supabase BinaryCapableStorage + 能力矩阵展示

- **Supabase 二进制路径**（`supabase_storage_service.dart`）：实现 `BinaryCapableStorage`（uploadBinary 直传字节 + downloadBinary 返回原生字节，均带认证门禁/超时包装/异常分类）——SDK 的 uploadBinary/download 本就是字节接口，此前未实现可选能力接口导致附件/ZIP 备份恒走 base64 文本兜底。落地后 `CloudStorageBinaryExt` 自动分派真字节路径，**流量 -33%**，云端对象原生格式。旧 base64 文本对象由既有嗅探兜底兼容（备份恢复 ZIP 魔数/附件 sha256 终审）。新增 4 项语义单测（类型分派/双路径认证门禁/logger 注入），包 23 项全过；
- **LOG-01 Supabase 侧收编**：5 处 dev.log → `storageLogger` 静态注入（对齐 WebDAV/S3 模式），provider_factory 装配时接线进应用日志（release 可留痕）；
- **能力矩阵展示**：连接测试成功弹窗附「后端能力」行（并发保护：S3 原生/WebDAV 近似/其余校验兜底；二进制传输：iCloud 标注降级形态）——把降级从静默变透明，l10n×4；
- **留待迭代备案**：iCloud 二进制路径（P2-3）需原生侧 method channel 改造，本环境无法验证 iOS 原生行为，不在本批实施。

### P2-6：参数集中文档

新增 `docs/sync-reliability-params.md`：四后端超时分级表（S3 自适应 30s+30s/MB 等 13 项）、五套重试策略矩阵（含 S3 条件 PUT 新增的安全重试行）、三层并发防护、四条设计纪律、非重试面备案。此后改参数的唯一权威口径。

### P1-1 尾巴结论（不实施收编，备案理由）

TSM 附件重试（1s/2s/4s）**不迁移**到 core RetryHelper：它是业务级三态语义（ok/objectMissing/transientFailure 需调用方区分），与传输级重试（成功/失败二元）不同构，强行收编会破坏三态返回；且为会话内内存队列 drain，无多端共享风暴面，jitter 无必要。P1-1 的实质债务（WebDAV 假 jitter、条件 PUT 安全重试、参数漂移文档化）已全部落地。

### 回归验证

`flutter analyze` 0 error / 0 warning；全库 `flutter test test/` **1074 项全过**（Supabase 包 23，新增 4）。

---

## 十、第四批实施(2026-09-10:P2-1/P2-2/P2-4/SEC-03/SEC-06/SEC-08/LOG-04/LOG-05 收尾批)

### P2-4 + SEC-08:备份失败补试 + 时钟回拨防护

- **语义变更**:`backup_auto_last_date` 去重 key **仅成功写入**——弱网日 22:00 备份失败不再占用当日名额,按 30 分钟退避自动补试直至成功或跨日(P2-4);
- **回拨防护**(SEC-08):`BackupScheduler.attemptAllowed` 纯函数——`backup_auto_last_attempt_ms` 锚点 + `minAttemptInterval` 30 分钟失败退避(调度器分钟级 tick 不连打云端) + `clockRollbackTolerance` 5 分钟回拨容差(now 早于锚点减容差一律拦截,NTP 小幅修正不误伤、回拨后爬回仍须满退避间隔);手动备份同口径写 attempt 锚点(用户刚试过,30 分钟内不叠加自动补试);
- **测试**:`backup_scheduler_test.dart` 新增 6 项(attemptAllowed 全矩阵 + 失败不占名额),组内 16 项全过。

### SEC-03:明文迁移失败凭据残留告警

- 包侧:`CloudServiceStore.lastMigrationErrorKey/Message` 结构化痕迹(迁移失败时记录,迁移成功/_writeCfg 清明文时自愈清除),`activeCloudConfigProvider` 同步转 `cloudMigrationWarningProvider`;
- App 侧:云同步页新增 tertiary 色 banner(区别于损坏的 error 红,非致命——数据可用即工作),l10n ×4(`cloudMigrationWarning`);
- **测试**:包内新增 3 项(失败记录痕迹且明文不被误删/成功清除+明文删除/重保存配置清除痕迹),包 93 项全过。

### SEC-06:enable 失败不清旧密钥

- enable 前快照旧三件套(key/salt/verifier),失败路径**恢复旧材料**而非 `clearAll`(旧版会把 disable 后特意保留的旧密钥一并抹掉,存量密文从此不可解密);首次 enable(无旧材料)维持 clearAll 清半写入状态;恢复失败记 error 提示重置加密;
- **测试**:新增 2 项(disable→enable 失败→旧三件套字节级恢复+旧密码可解旧 verifier/首次失败→清半写入),文件 55 项全过。

### LOG-04:LoggerService 启动加载竞态

- 症状:fire-and-forget `_loadLogs` + `_isLoaded` 立即置 true——窗口期新日志先入队,2s 节流保存把「只含新日志」的队列覆盖写盘(**历史永久丢失**);加载完成后旧日志追加队尾(时序颠倒);
- 修复:single-flight `_ensureLoaded` + `_pendingLogs` 暂存(未加载完成的新日志一律暂存,完成后历史在前按序并入) + `_doSaveLogs` 写盘前等加载 + `clear` 世代计数(加载在 flight 时清空,完成后不回填);`exportAsText`/`logs` 含暂存条目;
- **测试**:新增 4 项(窗口期不丢+时序/写盘不被覆盖/清空优先/正常路径),`logger_service_test.dart` 12 项全过。

### LOG-05:日志中央脱敏层

- `LogSanitizer`:全部日志(Flutter+原生桥接)入队/落盘前统一过滤——URL userinfo(`https://u:p@h` → `https://***@h`)、键值对凭据(password/secret/anonKey/apiKey/token/authorization 等 15 词,`k=v`/`k:v` 形态,大小写不敏感)、JSON 凭据字段、Bearer/Basic 头;
- 顺序敏感:Bearer/Basic 头先于键值对(否则 `Authorization: Bearer xxx` 会脱成 `Authorization: *** xxx` 留 token 残值);幂等(`***` 不被再改写);账本名/指纹哈希按备案保留(非凭据,排障对账需要);
- **测试**:8 项单测(URL/双形态键值对/JSON/头/多处/不受影响项/幂等/入口统一 message+error)。

### P2-1:getStatus 冷启动指纹缓存

- `_localFpCache`(ledgerId → 指纹+校验位):命中时跳过全量导出(冷启动大账本 CPU 归零);**双失效防线**——①`local_changes` 轻量校验位(MAX(id)+COUNT,查询失败返回随机值强制失效——宁可多算不可漏算)②`ChangeTracker.onLocalContentGeneration` 写路径回调(user-global=0 影响全部快照,按全部失效);
- **recordChanges:false 导入路径显式失效**(不写 local_changes、guard 不变的漏判窗口):恢复(downloadAndRestore/restoreAll 覆盖语义)、合并(applyPreviewChanges)、云端账本导入(importRemoteLedger)、备份恢复(runAfterDownload/C → clearStatusCache 全量)逐点补失效;`clearStatusCache` 与指纹缓存同口径;上传成功 `rememberLocalFingerprint` 登记(上传后 UI 刷新 getStatus 零导出);reinit/dispose 清空;
- getStatus 缓存命中路径 `localSerializedData/localParsedCount` 省略(包内按需自行导出——该场景云端指纹必然全量下载比对,导出无法避免,不构成退化);
- **测试**:`local_fingerprint_cache_test.dart` 5 项(命中复用/guard 变化失效/tracker 回调失效/user-global 全失效/markLocalChanged 失效)。

### 弱网档双端实测:评估完成,执行受环境阻断

单模拟器(PS16k 镜像)2 小时冷启动窗口 `adb offline`(qemu 近闲置、非 crash),双端无从开展;已排除 adb 重启/锁清理/递增等待,残留已清理。弱网相关修复以单测矩阵为替代性证据(P1-2 超时档 5 项/P1-1 条件重试 5 项/P2-4 矩阵 6 项),完整评估与重跑指引归档 `docs/synctest/弱网档双端实测评估-2026-09-10.md`。

### 回归验证(2026-09-10)

- `flutter analyze`:0 error / 0 warning(info 级既有遗留不变);
- 全库 `flutter test test/`:**1103 项全过**(基线 1074 + 本批净增:备份 6/SEC-06 2/LOG 12/P2-1 5,另 l10n 重生成);
- 包套件:core 93(基线 90+SEC-03 3)/S3 129/WebDAV 59/iCloud 8/Supabase 23,全过;合计 **1215 项,0 失败**(1 skip 为 W5 集成测试按设计);
- 审计问题清单 28 项全部闭环或备案:26 项已修复(✓),P2-3(iCloud 原生侧)/N-2 留待迭代备案,弱网双端实测待环境具备时按指引补做。

### 本批后剩余待办

- P2-3 iCloud base64 method channel 内存峰值(原生侧改造,本环境无法验证 iOS 原生行为);
- 弱网档双端实测(条件具备时按 §五指引执行)。

---

## 十一、弱网档双端实测执行(2026-09-10 凌晨:四组用例全通过)

评估文档(`docs/synctest/弱网档双端实测评估-2026-09-10.md`)所述环境阻断已解决并完成实测,完整报告见 `docs/synctest/弱网档双端实测报告-2026-09-10.md`。要点:

- **环境修复**: PS16k 引导阻断 root cause = userdata qcow2 损坏,`-wipe-data` 后 90s 引导;双实例=AVD 克隆;凭据改用仓库固化 WebDAV 测试栈(S3 secure 备份因 Keystore 随 wipe 重置不可移植)。
- **用例 1**: EDGE 弱网 6 账本/6000 笔全量上传,每快照 ~425KB(超 350KB 档),Post-upload verify ×6 全过——P1-2 自适应超时实测通过。
- **用例 2(P2-4)**: 真实时间轴全链路——手动备份 attempt 锚点 → 定时触发失败(Connection refused,`backup_auto_last_date` 不写/失败呈现/「30 分钟后自动补试」日志)→ 退避期 tick 静默 → 31 分钟后自动补试成功(`backup_auto_last_date` 写入/服务器 ZIP 落盘)→ 成功后当日去重。SEC-08 回拨端到端受非 root 限制,单测矩阵覆盖备案。
- **用例 3(P2-1/P2-2)**: 双端「本地指纹走缓存(guard=...)」日志命中;A 端「附件目录列举走会话缓存」;B 端恢复路径指纹缓存失效链(recordChanges:false 显式失效→unknown 方向如实呈现)。
- **用例 4**: B 端一键恢复 5/5 新账本+默认账本合并,A 端 Apply all 反向回传;DB 级比对已同步 5005 笔逐字段 0 差异(账本 1 同 syncId 异名为已知设计边界,连同 is_shared 边界如实定性)。
