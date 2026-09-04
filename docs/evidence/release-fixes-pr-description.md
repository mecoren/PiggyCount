# PR: 上线前全面体检与修复（审计第 1-7 轮）—— UI/性能/功能/同步全链路

## Summary

PiggyCount 上线标准全面体检：7 轮审计共修复 30+ 项 UI 可读性/性能热路径/异常兜底/i18n/同步可靠性问题，并以自动化压测 + perfetto 实测（含 before/after 前后对比）提供验收证据。`flutter analyze` 0 error（654 条，lib 死代码清理后净减），`flutter test` 1052 全过，同步模块 100 轮随机中断重试压测失败率 0%、SHA256 终态一致性 100%。

## Changes by Area

### UI / 渲染（审计 A 档 + B 档）
- **A1-A6**：韩语 l10n 补齐 163 词条、硬编码中文全部收口；暗色模式可读性（冲突信息条 12% 语义底、徽章收敛 token）；全量 `print` → logger 收口 + release 全局异常兜底（无 Red Screen）；Toast 单槽顶替 + 淡入淡出；年报页可读性/词条/币种收尾。
- **B3-B6（性能）**：`CustomIconService` 目录路径 static 缓存（消除列表每行 await IO）；图表 RepaintBoundary 隔离 5 处（分析页 Line/Bar/Pie、账户页迷你趋势、净值趋势页）；`_buildDayCard` day 汇总预计算（消除每帧重算）；首屏就绪与周期交易生成解耦（冷启动不再等待周期生成）。
- **B2/B8**：空状态占位（AppEmpty）与加载态补齐；列表错误重试路径。

### 性能（审计第二轮 P1-P6 + 第三轮 D1-D3 + 第七轮 isolate 化 + 实测交付）
- **P1-P6**：统计查询 SQL 聚合化——消除全量载行与 N+1（multi_currency_statistics / statistics_exclude_flags / account_stats / budget 四处口径回归锁全过）。
- **D1**：附件上传探测批量化——单次 `list('attachments')` 替代 N 次 exists()（WebDAV N 次整目录 PROPFIND → 1 次）；失败退回逐对象探测，语义不变。
- **D2**：同一快照双 `jsonDecode` 消除——`preParsedCount`/`localParsedCount` 透传，万笔账本每次上传省一次全树解析。
- **D3**：Path A auto_sync 2s 防抖（对齐 Path B）——连续记账收敛为最后一次上传，pending 补跑保证最终一致；手动上传不受影响。
- **第七轮 isolate 化收尾（验收「JSON 重计算入 compute()」闭环）**：
  - `downloadAndPreview` 消除 UI 线程双解析——新增 `parseSnapshotIsolate` 顶层入口（`ParsedSnapshot` 一次取回 importData/version/count/contentFingerprint），调用点改 `compute`，恢复/合并/预览入口路径的大快照解析整个离开 UI 线程；
  - `restoreLedgerFromJson`（恢复管线单一事实源）的万笔级 `parseJsonToImportData` 移入 `compute`，DB 事务外完成；
  - CSV 导入（既有）+ Argon2 派生（既有）+ 下载预览 + 恢复管线四条重计算路径全部 isolate 化；仅取元数据的小解析旁路（内嵌指纹探测/软告警自检/列表条目）经逐处核实有意不动（防过度设计）；
  - 内存泄漏专项复核：全部 StreamSubscription/AnimationController/FocusNode 生命周期闭环（dispose 链路 + 幂等守卫 + onDone 清悬挂引用），零泄漏；
  - 新增 5 条等价性回归（`test/cloud/parse_snapshot_isolate_test.dart`）：元数据口径逐字段一致 / importData 逐字段一致（含防空转守卫）/ 损坏输入 FormatException 契约不变 / compute 跨 isolate 全链路。
- **死代码清理**：6 处 lib 侧 unused import 移除（含 D2 优化后 `sync_engine.dart` 对 transactions_json 的死引用）。
- **实测交付**：perfetto（DevTools Performance 同源数据）实测 before(3b8f956)/after 前后对比——洞察页 before 1 帧 53.2ms 可感知卡顿 → after >32ms 帧全部消除；两场景 60fps 锁步（模拟器 vsync 上限），>25ms 卡顿率 0.46%→0.31% / 0.59%→0.30%。trace 归档可复演。

### 同步模块（S3 / WebDAV 稳定性专项）
- **重试护栏**：`RetryHelper` 指数退避 + 0-25% jitter（防重试风暴）；认证/配置/404 确定性错误不重试；S3 超时 30s、WebDAV 60s + 可取消超时（CancelToken）。
- **冲突处理三选一**：元数据指纹→内嵌指纹终审→可信墙钟仲裁；探测失败中止上传（不盲传覆盖）；UI 层「强制上传 / 对比合并 / 取消」。
- **条件写**：S3 If-Match 原子条件写（412 → 显式冲突）；WebDAV eTag 预检；盲上传写后校验 verified 上浮（不一致不清脏标记）。
- **网络切换**：connectivity_plus 监听 → 2s 防抖恢复队列（WiFi↔蜂窝切换不丢任务）；WS 重连同步对账。
- **进度回调**：按账本粒度 `onProgress(done, total)` + startup_sync_overlay 进度条——回调频率 = 账本数，无 UI 刷新风暴。
- **断点续传语义**：单对象原子发布（WebDAV temp-PUT→MOVE 失败回滚）+ 附件 sha256 内容寻址幂等去重 + 重传安全收敛（压测证实）。
- **验收压测**：100 轮随机中断重试（30% per-op 故障率、五类中断点含落盘后响应丢失）——100/100 收敛、失败率 0%（<1% 线）、冲突误判 0、SHA256 指纹三方恒等。测试 `test/cloud/sync_interruption_stress_test.dart` 随 CI 全量重跑。

## Evidence（交付物索引）

| 验收要求 | 交付物 |
|---|---|
| DevTools 性能快照前后对比 | `docs/evidence/frame-profile-before-after-comparison-2026-09-04.json` + 4 份原始 `.pftrace`（before/after × 首页/洞察，ui.perfetto.dev 可复演）+ `docs/evidence/frame-profiles-README.md`（方法/口径/复现命令） |
| 同步中断重试测试用例及日志 | `test/cloud/sync_interruption_stress_test.dart`（随 CI 重跑）+ `docs/evidence/sync-interruption-stress-2026-09-04.log`（逐轮日志） |
| 修复代码改动点清单 | 本文件 + 审查报告第八~十四部分逐项执行记录 |

## Verification

- `flutter analyze`：0 error；654 条（lib 侧 unused import 清零，剩余全部 test 目录既有 info），零新增。
- `flutter test`：1052 全过（新增 1 条压测 + 4 条防抖回归 + 8 条聚合回归 + 5 条 isolate 解析等价回归）；`flutter_cloud_sync` 包 113 全过。
- 帧率：60fps 锁步实测通过（模拟器 60Hz 上限）；120Hz 门禁 G1/G2 已在 120Hz vsync 环境实测通过（见下）。

## Release Gate（120Hz 高刷门禁 —— 已实测通过）

1. **G1 PASS**：120Hz 环境复杂页面滑动首页 118.3fps / 洞察页 118.6fps（≥90fps 达标；vsync 120Hz 锁步，中位帧间隔 ≈8.33ms 单 vsync 预算，等效 DevTools UI/GPU <8.33ms@120Hz）。
2. **G2 PASS**：>2 vsync 周期（>16.67ms）慢帧占比 0.86% / 0.45%（<1%），无 >50ms 帧、无冻结窗口。
   实测环境：MuMu 宿主 max_frame_rate=120（guest 物理 vsync 120.00001Hz，dumpsys 实证）；可选：120Hz 物理真机复跑背书（脚本同 `frame-profiles-README.md`）。

## 第七轮改动文件清单（本轮增量）

| 文件 | 改动 |
|---|---|
| `lib/cloud/transactions_json.dart` | +`ParsedSnapshot` 类与 `parseSnapshotIsolate` 顶层入口（isolate 解析一次取回 importData/version/count/contentFingerprint） |
| `lib/cloud/transactions_sync_manager.dart` | `downloadAndPreview`：UI 线程双 jsonDecode → 单次 `compute(parseSnapshotIsolate, ...)`；import 增补 `compute` |
| `lib/services/data_import_service.dart` | `restoreLedgerFromJson`：`parseJsonToImportData` 移入 `compute`（DB 事务外，ImportData 纯数据可跨 isolate） |
| `lib/cloud/sync/sync_engine.dart`、`lib/pages/calendar/calendar_page.dart`（×2）、`lib/pages/transaction/recurring_transaction_edit_page.dart`、`lib/providers/ai_chat_providers.dart`、`lib/widgets/biz/amount_editor_sheet.dart` | 移除 6 处 unused import（含 D2 后遗留死引用） |
| `test/cloud/parse_snapshot_isolate_test.dart` | 新增 5 条等价性回归（元数据口径/业务数据逐字段/损坏输入契约/compute 全链路/防空转守卫） |
| `docs/release-readiness-review-2026-09-03.md` | 第十四部分：第七轮执行记录（含内存泄漏专项复核结论） |
| `docs/evidence/release-fixes-pr-description.md` | 本文件第七轮段落 |
