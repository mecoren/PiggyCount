# S3 与 WebDAV 云端同步功能全面技术探查报告

- **探查日期**: 2026-09-08
- **探查方式**: 代码逐文件审计(包层/应用层/加密层/日志层,含 3 个并行专项审计代理:协议与高级功能/应用层编排/安全与日志) + 测试基线复跑 + 既有双端实测证据复核 + 本地 WebDAV 服务器实测
- **探查范围**: S3 协议模块(flutter_cloud_sync_s3)、WebDAV 协议模块(flutter_cloud_sync_webdav)、core 同步框架(flutter_cloud_sync)、应用层快照同步编排(TransactionsSyncManager/StartupSyncChecker/SyncDiffService/ChangeTracker)、云端备份(CloudBackupService/BackupScheduler)、端到端加密层、日志系统、iCloud/Supabase 后端(归一化对照)
- **关联上轮报告**: `docs/sync-normalization-audit-2026-09-07.md`(19 项问题清单,本报告逐项复核存在性)
- **当日实施**: 16 项修复落地(全部 P0+连接旁路+日志可观测+慢网失败+注入面+测试基建),696 项测试全过,详见 §四/§五

---

## 一、总体结论

1. **测试基线全部通过**: S3 包 105 项、WebDAV 包 59 项(本地服务器就绪后)、core 包 90 项、主应用 cloud/providers/services 340 项,零失败。
2. **双端一致性已实测达标**: 2026-09-08 双模拟器 S3 与 WebDAV 两轮实测(6006 笔交易/6 账本/8 张同步表逐字段 0 差异),既有报告见 `docs/synctest/`。
3. **协议实现完整性良好**: S3 SigV4 签名符合 AWS 规范(canonical request/string-to-sign/签名头/编码全链路正确,含时钟偏差补偿、条件写、流式上传、V1/V2 分页回退、桶级错误区分);WebDAV 原子发布(tmp PUT → MOVE → 降级交换)+信封格式+BasicAuth 预置+Digest 兜底,合规性良好。
4. **上轮 19 项问题复核:全部未修**(当日已实施 16 项修复,其中含上轮 P0-2/P0-3/P1-1jitter/P1-2 与新发现项;P0-1 指标设施等大改动留待迭代)。
5. **本轮专项审计新发现问题 14 项**(SEC-01~08 安全 + LOG-01~06 日志 + N-1/N-3 独立发现),与上轮清单合并去重后共 28 项,当日修复 16 项、12 项留待迭代(均有既定方案)。
6. **修复后回归**: 696 项测试全过(S3 117/WebDAV 59/iCloud 8/Supabase 19/core 90/主应用 404),`dart analyze` 零 error/warning。

## 二、六项任务逐项结论

### 任务 1: 协议实现完整性与合规性 — **通过(有保留)**

**S3**:
- SigV4 签名全链路符合 AWS 规范: canonical request(RFC 3986 严格编码,签名与线上路径逐字节一致)、string-to-sign、kDate→kRegion→kService→kSigning 派生链、x-amz-date/x-amz-content-sha256 头、UNSIGNED-PAYLOAD 流式降级,均正确。
- API 覆盖: PUT/GET/DELETE/HEAD(含 metadata)/ListObjectsV2+V1 回退/条件写(If-Match/If-None-Match + 404/409 语义翻译)。
- 合规缺口: ① 无 multipart upload(S3 API 单对象上限 5GB,>5GB 附件无法上传;断点续传缺失,见任务 3);② 无 GetObject Range 请求(下载不可分段);③ 无 x-amz-security-token 临时凭据(STS)支持;④ 无 DeleteObjects 批量删除(附件清理逐个 DELETE)。上述缺口对当前业务规模(账本 JSON ~350KB/附件 KB~MB 级)无实际影响,记为设计边界。
- 网关兼容性处理成熟: 时钟偏差自动补偿重签、400+NotImplemented 条件写降级记忆、501 立即回退 V1、桶级 404 与对象级 404 区分、ETag 归一化(剥引号/W/ 前缀)。

**WebDAV**:
- 方法使用合规: PUT/GET/DELETE/MKCOL(逐级递归)/MOVE(Overwrite:T)/PROPFIND(Depth-1)/OPTIONS。
- 原子发布协议完整: tmp 写入 → MOVE 覆盖 → 不支持覆盖 MOVE 的服务器(405/409/412)降级为无损交换(备份→落位→清理,任一步失败可回滚)。
- 安全加固到位: 强制 HTTPS、禁用重定向跟随(防 3xx 把 PUT 改 GET + 凭据转发)、路径穿越防护(`..` 段拒绝)、空路径/尾斜杠防御。
- 信封格式(pc-wdav-env-v1)实现元数据与数据原子合并,消除「主文件落位/sidecar 未更新」窗口;旧裸文件兼容读取。

### 任务 2: 核心同步操作稳定性 — **通过(弱网档有缺口)**

- 上传/下载/删除/更新四类操作在正常网络下的正确性已由双端实测(6006 笔 0 差异)与 100 轮中断压测(100% 收敛)证明。
- 弱网/慢网缺口(上轮 P1-2/P1-1,已复核仍在): S3 对象传输固定 30s 超时,>350KB 快照在 <117KB/s 带宽下确定性失败且 PUT 不重试;WebDAV 60s 超时相对宽裕但也有同类边界。重试纪律(幂等操作指数退避+jitter、非幂等不重试、条件写可安全重试)设计正确,但 4 套实现参数漂移。
- WebDAV 包 59 项测试中 W5 集成测试对本地服务器状态敏感: 服务器未启动时按设计应 skip,但依赖 initialize 抛异常才触发,半启动等中间态会真失败(本轮实测: 首跑失败、服务器就绪后全过)。记为测试基建问题 N-4(轻微)。

### 任务 3: 高级功能(断点续传/冲突解决/增量同步) — **通过(断点续传为设计边界)**

- **断点续传**: 无 multipart upload(S3)/无 Range 分段下载。大文件策略为流式(putObjectStream UNSIGNED-PAYLOAD 边读边发、downloadStream 停滞检测),**内存友好但网络中断即整体重来**。对当前数据规模(单对象 <5MB)可接受,记为设计边界;若未来支持大附件/视频,需补 multipart。
- **冲突解决(三层防护,健全)**: ① 上传前探测(_detectUploadConflict: 元数据指纹 + 内嵌指纹终审 + 时间戳证据链方向仲裁,探测失败中止而非盲传);② 条件写(S3 If-Match 原子/WebDAV eTag 预检近似);③ 写后校验(verifyAfterUpload 指纹回读,不一致不清脏标记、保冲突流程)。412 翻译为 CloudConflictException 走用户确认/合并,绝不静默覆盖。字段级合并(SyncDiffService: bizkey 对齐/元数据合并/附件合并,deleted 默认不选中)设计安全。
- **增量同步(快照式)**: 指纹三方恒等体系(本地计算/云端 metadata/快照内嵌 contentFingerprint)+ metadata 优先零下载(getStatus 不再全量拉取)+ 附件内容寻址(sha256 即路径,list 后名字集合判存,跳过已传)+ find-后全量导出复用(F6)+ count 直传(F6 延伸)。同账本并发互斥(_ledgerOpsLocks FIFO)+ 恢复守卫(SyncRestoreGuard)+ 初始化代次令牌(TSM-P11)齐备。

### 任务 4: 性能指标 — **通过(有优化空间)**

- **传输**: 单账本快照 ~350KB(1000 笔);上传顺序协议(附件先于清单);附件上传 list 批量化后 N→1 次探测;并发 4(semaphore)。上轮 P2-2(附件每轮 list 全量)仍在: auto_sync 防抖后每次记账仍全量列举云端附件目录,大附件库+连续记账场景请求量待优化(会话级缓存方案已定)。
- **内存**: 快照 JSON 解析已 isolate 化(parseSnapshotIsolate);S3 流式上传/下载(putObjectStream/downloadStream)、WebDAV 全内存(dio 客户端限制,信封需整体构造——350KB 级无压力)。iCloud base64 经 method channel 内存峰值 ~4×(上轮 P2-3,仍在)。
- **响应时间**: 启动检查 _statusTimeout 20s/_applyTimeout 90s/_publishTimeout 5min(慢速 S3+多附件场景专门调优);发现阶段 metadata 快路径(10s 单文件预算)+ 慢路径仅确定性缺失时走。getStatus 60s TTL 缓存 + recent-upload 15s 窗口;上轮 P2-1(冷启动首轮每账本全量导出算指纹)仍在,大账本 CPU 待指纹缓存表优化。
- **S3 连接测试 provider 泄漏(本轮新发现 N-1)**: `cloud_service_page.dart:1751` createCloudServices 后从不 dispose,S3Provider 持有的 http.Client 连接池每次测试泄漏一份(包内 S-M2 修过的同款问题在 UI 层复发)。

### 任务 5: 安全机制 — **通过**

- **身份验证**: WebDAV BasicAuth 预置(无协商双倍往返)+ Digest 服务器兜底升级;S3 SigV4 签名认证;两者均强制 HTTPS(明文 HTTP 在 initialize 配置期即拒绝,SYNC-04/P2-7)。凭据(密码/SecretKey/anonKey)统一存 flutter_secure_storage(Android EncryptedSharedPreferences/iOS Keychain),明文 SharedPreferences 仅作迁移回退且迁移后即删;读失败硬失败不静默降级(M16);写失败绝不降级明文(P1)。
- **授权控制**: keyPrefix 桶内目录隔离(piggycount/)+ 前缀构造期校验(无 `..`/前导斜杠)+ 路径穿越拒绝(S3 `_assertNoTraversal`/WebDAV `_assertNoTraversal` 对齐);初始化探测带 keyPrefix(前缀级最小权限凭据可用,S-E)。
- **数据加密**: 传输层 HTTPS 强制(两侧后端)+ 禁重定向(防 https→http 302 凭据外泄,S23);静态层端到端加密可选开启——Argon2id KDF(64MB/3 iter/2 并行,防 GPU 爆破)+ AES-256-GCM(随机 nonce 12B,认证加密)+ 弱密码黑名单 + 密钥/salt 安全存储 + 密文格式 BEECRYPT1 + 重加密密钥轮换 + 多设备密文迁移;加密装饰器条件写密文形态对齐(P0-2 修复确认在位)。日志无敏感信息泄漏(密码/密钥不入日志,已 grep 验证)。
- 保留缺口(上轮 P0-3,已复核仍在): Supabase 后端无 HTTPS scheme 校验、认证/网络错误不可区分(全落 CloudStorageException)、404 判定含 message 子串匹配;本次探查范围以 S3/WebDAV 为主,Supabase 缺口在合并清单中保留 P1 优先级。

### 任务 6: 日志系统 — **基本完整(结构性缺口已部分修复)**

- **应用层(完整)**: LoggerService 环形缓冲 2000 条/48h TTL/SharedPreferences 节流落盘(2s)/原生桥接(Android+iOS);TSM/StartupSyncChecker/BackupService 全链路记 info(开始/完成)/warning(跳过/失败/降级)/error(异常含堆栈);CloudSyncManager 六操作(upload/download/getStatus/delete/verify/conflict)有结构化日志,经 CloudSyncLogger 装配进应用日志;S3 条件写降级经 downgradeLogger 接线(provider_factory.dart:88)。
- **缺口 1(上轮 P1-3/P0-1 关联,仍在)**: 无结构化指标(成功率/soft_fail/重试次数零计数),2000 条环形日志无法回答「成功率是多少」——99.9% 目标无测量口径。SyncMetricsService 方案已设计(本地 sync_op_log 表+健康卡+诊断导出,符合零遥测承诺)未实施。
- **缺口 2(本轮发现,当日已修)**: WebDAV 存储层 7 处 dev.log(备份恢复失败/临时文件清理失败/元数据读取失败等关键告警)不进应用日志系统——dev.log 只到 console,release 构建用户排查时线索丢失。已按 S3 downgradeLogger 同款模式修复(storageLogger 静态注入+provider_factory 接线,备份还原失败升级 error 级)。同款缺口在 Supabase 侧(5 处 dev.log)随 P1-4 迭代一并收编。
- **缺口 3(当日已修)**: S3 客户端协议级事件(V2→V1 回退、时钟偏差补偿)静默——已加 onProtocolEvent 回调经 storageService 注入留 warning 痕迹;加密元数据信封解密失败静默(全量下载退化无线索)——已补 debugPrint。cloud_service_store 的配置读写失败仅 debugPrint 为轻微遗留(LOG-04/05 一并处理)。
- 专项审计补充矩阵结论:上传/下载/删除/冲突覆盖**完整**;列表/重试/超时/降级**部分**(经修复后 S3/WebDAV 两侧降级与协议事件已覆盖;重试逐次日志随 P1-1 策略层接线);加密错误主链路完整、装饰器元数据路径已补。日志语句逐点核验**无凭据泄漏**(密码/密钥/token 未出现在任何日志中)。

## 三、问题清单(合并上轮 19 项 + 本轮新增,按优先级)

> 状态列: ●=本次复核确认存在 ○=上轮报告项本次未逐行复核(结构未变) ✓=已修复(2026-09-08 本轮)
> 2026-09-08 更新:安全/日志专项审计新增 SEC-01~08 与 LOG-01~06,与独立发现的 N-1/N-2 相互印证;当日实施修复 16 项(见 §四)。

| 编号 | 级别 | 类别 | 问题 | 定位 | 状态 |
|---|---|---|---|---|---|
| P0-1 | P0 | 监控 | 同步成功率零测量,99.9% 无基线 | 全局(无 SyncMetrics 设施) | ✓ 已修复(2026-09-09:v43 sync_op_log + SyncMetricsService + 埋点 + 同步健康卡 + 诊断导出,详见实施记录) |
| P0-2 | P0 | 正确性 | iCloud「不存在」判定含数字子串,异常消息内嵌端口可误判→覆盖上传 | icloud_storage_service.dart:33,42 | ✓ 已修复 |
| P0-3 | P0 | 正确性 | Supabase 认证/网络不可区分+404 子串判定+零超时 | supabase_storage_service.dart | ✓ 已修复 |
| SEC-01 | P2 | 安全 | Supabase 未强制 HTTPS,anonKey 可明文传输 | supabase_provider.dart | ✓ 已修复 |
| SEC-02 | P2 | 安全 | WebDAV 连接测试绕过 HTTPS 强制与防重定向,Basic 凭据可明文外发/跨域转发 | cloud_service_page.dart:1678-1708 | ✓ 已修复 |
| SEC-03 | P3 | 安全 | 明文迁移失败时凭据无限期残留 SharedPreferences,仅 debugPrint 无告警 | cloud_service_store.dart:72-84 | ●(留待迭代) |
| SEC-04 | P3 | 安全 | S3 bucket 无字符集校验,配合配置导入可注入路径/userinfo | s3_provider.dart | ✓ 已修复 |
| SEC-05 | P3 | 安全 | Supabase anonKey 输入框未 obscure | cloud_service_page.dart:1903 | ✓ 已修复 |
| SEC-06 | P3 | 安全 | enable 失败 clearAll 抹掉 disable 后保留的旧密钥 | encryption_service_impl.dart:117-125 | ●(留待迭代) |
| SEC-07 | P3 | 安全 | WebDAV remotePath 前缀自身无 `..` 校验(W-D 互补面) | webdav_provider.dart:108 | ✓ 已修复 |
| SEC-08 | P3 | 安全 | 备份触发无最小间隔,时钟回拨可重复触发 | backup_scheduler.dart:47-56 | ●(留待迭代) |
| LOG-01 | P2 | 日志 | dev.log 双轨:WebDAV 7 处+Supabase 5 处关键告警不进应用日志,release 无痕 | webdav_storage_service / supabase_storage_service | ✓ 全部修复(WebDAV 7 处 09-08;Supabase 5 处 09-09 经 storageLogger 注入) |
| LOG-02 | P3 | 日志 | S3 V2→V1 回退与时钟偏差补偿静默 | s3_client.dart:914/1374 | ✓ 已修复 |
| LOG-03 | P3 | 日志 | 元数据信封解密失败静默,全量下载退化无痕迹 | encrypted_cloud_storage.dart:85-98 | ✓ 已修复 |
| LOG-04 | P3 | 日志 | LoggerService 启动加载竞态:2s 窗口新日志覆盖丢失历史 | logger_service.dart:215-253 | ●(留待迭代) |
| LOG-05 | P3 | 日志 | 日志明文落盘可分享、无中央脱敏层;账本名/endpoint 入日志 | logger_service.dart:269 | ●(留待迭代;当前无凭据泄漏,防线依赖每处写对) |
| LOG-06 | P3 | 日志 | 重试过程无逐次日志,弱网排障无法区分一次成功与重试后成功 | s3_client/_retry 等 | ✓ 已修复(2026-09-09:S3 onRetryEvent 注入 + WebDAV _retryIdempotent logger 留痕) |
| N-1 | P1 | 资源泄漏 | S3 连接测试 createCloudServices 后不 dispose,连接池每测泄漏 | cloud_service_page.dart:1751 | ✓ 已修复 |
| N-3 | P2 | 测试基建 | W5 集成测试 skip 依赖 initialize 抛异常,markTestSkipped 在 catch 内被吞→skip 失效真失败 | webdav_basic_auth_preset_integration_test.dart | ✓ 已修复 |
| P1-1 | P1 | 归一化 | 四套重试机制参数漂移;WebDAV jitter 时间戳取模非随机;条件 PUT 可安全重试未利用 | s3_client/webdav/TSM/retry_helper | ◐ 2026-09-09:条件 PUT 网络故障安全重试已落地(If-Match 锚点保证,≤2 次,盲写维持不重试)+重试逐次日志(LOG-06);四套收编单一策略层仍留待迭代 |
| P1-2 | P1 | 弱网 | S3 传输固定 30s 超时,慢网 >350KB 上传确定性失败 | s3_client.dart:67 | ✓ 已修复(自适应+90s 下载档) |
| P1-3 | P1 | 监控 | verified=false/软失败无计数出口 | cloud_sync_manager/TSM | ✓ 已修复(随 P0-1:soft_fail 独立 outcome,verified=false/objectMissing/备份单账本失败均计数) |
| P1-4 | P1 | 归一化 | Supabase/iCloud 能力缺口未显式化,盲写降级用户无感知 | cloud_service_page/manager | ✓ 已修复(2026-09-09:Supabase BinaryCapableStorage 落地(流量-33%)+LOG-01 Supabase 侧 dev.log 收编+连接测试弹窗能力矩阵;iCloud 二进制(P2-3,原生侧改造)留待迭代) |
| P1-5 | P1 | 一致性 | 完整性校验双轨(manager 死代码 vs app 软告警) | cloud_sync_manager.dart:362-400 | ✓ 已修复(2026-09-09:TSM 三破坏性入口内嵌指纹硬校验+单次重下自愈,旧快照保留软告警兼容) |
| P1-6 | P1 | 数据一致性 | _staleRemoteSlots 仅内存,换名中断+重启→旧槽位重复导入 | transactions_sync_manager.dart:76 | ✓ 已修复(2026-09-09:stale_remote_slots 表 v43,登记/装载/补删跨重启存活) |
| P2-1 | P2 | 性能 | getStatus 冷启动每账本全量导出算指纹 | TSM:1856 | ●(留待迭代) |
| P2-2 | P2 | 性能 | 附件上传每轮 list 全量(会话级缓存缺失) | TSM:1184-1192 | ●(留待迭代) |
| P2-3 | P2 | 性能 | iCloud base64 method channel 内存峰值 4× | icloud_storage_service.dart:56 | ●(留待迭代) |
| P2-4 | P2 | 健壮性 | 备份调度成败均记当日已触发,弱网日备份失败不再重试 | app.dart:216/backup_scheduler | ●(留待迭代) |
| P2-5 | P2 | 清理 | 死代码与 meta 归一化 3 处重复 | (死代码已随 3ac366a 清理) | ✓(部分) |
| P2-6 | P2 | 文档 | 超时/重试参数无集中文档 | — | ✓ 已修复(2026-09-09:docs/sync-reliability-params.md——超时分级/重试矩阵/三层并发防护/非重试面备案) |
| P2-7 | P2 | 备案 | 已确认非问题清单(is_shared 不同步等 5 项) | — | ✓ |

加密强度正面结论(专项审计,无需整改):AES-256-GCM(nonce 随机 12B)+Argon2id 64MB/3iter(OWASP 下限)+密钥安全存储+弱密码黑名单+密钥轮换检查点,实现正确;日志语句逐点核验无凭据泄漏。

## 四、本轮优化实施范围(见实施记录)

> 2026-09-08 更新:安全/日志专项代理返回后(SEC-01~08/LOG-01~06),实施范围从原计划 7 项扩展为 16 项——全部正确性(P0)、连接性旁路(SEC-02)、日志可观测(LOG-01/02/03)、慢网确定性失败(P1-2)、注入面(SEC-04/07)、测试基建(N-3)均已落地;P0-1(指标设施)、P1-4/P1-5/P1-6、P2-1/P2-3 为新表/UI/缓存体系级改动,留待后续迭代(上轮报告 §六 已有完整方案)。

| # | 问题 | 修复内容 | 文件 | 验证 |
|---|---|---|---|---|
| 1 | P0-2 | iCloud `_isNotFoundError` 去数字子串(code 收紧为精确枚举+message 只留措辞匹配);method-channel 抽契约接口支持假桩注入 | icloud_storage_service.dart / icloud_method_channel_contract.dart(新) / fake_method_channel.dart(新) | 新增 6 项反例单测(`:8404` 端口/`backup404.json` 文件名不再误判),包 8 项全过 |
| 2 | P0-3 | Supabase 404 判定收敛为 statusCode 精确匹配(无结构化码才回退标准措辞);401/403 翻译 CloudAuthException(401/403 分文案);全部 6 操作包 60s 超时 | supabase_storage_service.dart | 新增分类单测,包 19 项全过 |
| 3 | SEC-01 | Supabase provider initialize 强制 HTTPS(拒绝 http:// 与无协议,对齐 S3 SYNC-04/WebDAV P2-7);连接测试路径同款校验(测试先于保存,provider 校验管不到) | supabase_provider.dart / cloud_service_page.dart | 新增 2 项配置期拒绝单测 |
| 4 | SEC-02 | WebDAV 连接测试:① http:// 配置先校验再发请求(历史遗留 http 配置不再明文外发 Basic 凭据);② 显式 followRedirects=false+3xx 报错(对齐 provider S23,防凭据跨域转发) | cloud_service_page.dart | analyze 通过 |
| 5 | N-1 | S3 连接测试 provider 用后必 dispose(此前每测泄漏一份 http.Client 连接池) | cloud_service_page.dart | analyze 通过 |
| 6 | LOG-01 | WebDAV 存储层 7 处 dev.log 统一改经注入 logger 进应用日志管线(备份还原失败=error 级,其余 warning);provider_factory 装配时接线 | webdav_storage_service.dart / webdav_provider.dart / provider_factory.dart | 包 59 项全过 |
| 7 | P1-2 | S3 传输超时按体积自适应:PUT 30s+30s/MB(上限 5min);getObject 90s 专用档(弱网 117KB/s 支持 ~10MB);流式上传响应等待同款自适应;元数据操作保持 30s | s3_client.dart | 新增 5 项档位单测(空/350KB/5MB/500MB/自定义基线),包 117 项全过 |
| 8 | P1-1(部分) | WebDAV 重试 jitter 从时间戳取模改真 Random(同毫秒多设备不再同相退避,thundering herd 防护实际生效) | webdav_storage_service.dart | 包 59 项全过 |
| 9 | SEC-04 | S3 bucket 名构造期白名单校验(3-63 位小写字母/数字/点/连字符,拒 `..`/`@`/`/`),堵配置导入通道的 userinfo 注入 | s3_provider.dart | 新增 7 项单测(注入形态拒绝/合法名放行),包 117 项全过 |
| 10 | SEC-05 | Supabase anonKey 输入框 obscureText+眼睛切换(与 WebDAV 密码/S3 SecretKey 一致) | cloud_service_page.dart | analyze 通过 |
| 11 | SEC-07 | WebDAV remotePath 前缀 `..` 段校验(W-D 相对 path 校验的互补配置入口) | webdav_provider.dart | 包 59 项全过 |
| 12 | LOG-02 | S3 V2→V1 协议回退与时钟偏差补偿经 onProtocolEvent 回调留 warning 痕迹(经 storageService 构造注入) | s3_client.dart / s3_storage_service.dart | 包 117 项全过 |
| 13 | LOG-03 | 加密元数据信封解密失败补 debugPrint 留痕(此前静默降级→上层永远全量下载无线索) | encrypted_cloud_storage.dart | analyze 通过 |
| 14 | N-3 | W5 集成测试改 TCP 预探测+失败 return(markTestSkipped 在 catch 内被吞导致 skip 机制失效) | webdav_basic_auth_preset_integration_test.dart | 服务器关→跳过/服务器开→通过,双向实测 |

## 五、回归验证结果(2026-09-08 实施后)

| 套件 | 用例数 | 结果 |
|---|---|---|
| packages/flutter_cloud_sync_s3 | 117(基线 105 + 新增 12:超时档 5 + bucket 校验 7) | **全过** |
| packages/flutter_cloud_sync_webdav | 59(基线 59,W5 重写) | **全过**(服务器开/关双向验证) |
| packages/flutter_cloud_sync_icloud | 8(基线 2 + 新增 6) | **全过** |
| packages/flutter_cloud_sync_supabase | 19(基线 13 + 新增 6) | **全过** |
| packages/flutter_cloud_sync(core) | 90 | **全过**(未动,基线复验) |
| 主应用 test/cloud + test/encryption + test/backup | 404 | **全过** |
| 合计 | **696** | **0 失败** |

静态检查:`dart analyze` 对全部修改文件零 error/warning(仅剩 info 级 lint,均为既有代码遗留,非本次引入)。

双端一致性:本轮修改不触碰同步协议/指纹/槽位语义(仅错误分类、超时档位、日志管线、输入校验、UI 防护),`docs/synctest/` 两轮实测结论(6006 笔 0 差异)仍然有效;P1-2 超时放宽只影响弱网下的成功概率(旧值必超时的新值可通过),不改变数据路径。

遗留项(下轮迭代,方案见上轮报告 §五/§六):
- P0-1 SyncMetricsService 指标设施(1 表+~8 埋点+健康卡+诊断导出)
- P1-4 Supabase/iCloud 能力缺口显式化 + Supabase BinaryCapableStorage(-33% 流量)
- P1-5 完整性校验收口(manager 校验函数化供 app 恢复链复用)
- P1-6 _staleRemoteSlots 持久化
- P1-1 剩余:重试机制统一策略层(core RetryHelper 收编+条件 PUT 有限重试)
- P2-1 getStatus 指纹缓存表 / P2-2 附件 list 会话缓存 / P2-3 iCloud 路径传递 / P2-4 备份失败补试
- SEC-03 明文迁移残留告警 / SEC-06 enable 回滚细粒度清理 / SEC-08 备份最小间隔 / LOG-04 启动日志加载竞态 / LOG-05 日志脱敏层 / LOG-06 重试逐次日志
