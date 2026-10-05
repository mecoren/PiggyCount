# 内存基线与泄漏收口（B6-B10 / M10-M21）— 设计文档

批次日志（file:line 证据、门禁、实测/未实测状态）在
`docs/optimization-plan-2026-09-19.md` §13 的 B6/B7/B8/B9/B10 五节。本文件只留**设计决策与否决理由**。

## 一、核心取舍

### 决策 1：先收口、后基线（与方案定的顺序相反）

方案写"B6 必须最先做，是其余批次的前置"。实际执行把 B7-B10 提前，B6 交的是
**可执行流程 + 自检过的脚本 + 空表**。理由：本轮工作区没有任何 Android 真机/模拟器，
基线跑不出数字，而 B7-B10 每项都是"两行代码级"的确定收口（native 句柄该释放就该释放，
与基线无关）。等基线 = 全部不做。

代价如实挂账：按 §七.2 的硬门禁，**数字回填前 B7-B10 的收益判"未证"**。文档里所有
MB 级数字都标了"算式不是实测"。

### 决策 2：RSS 取数不信 `dumpsys` 的 TOTAL 列

`profile_memory.py` 的 RSS/峰值走 `/proc/<pid>/status` 的 `VmRSS`/`VmHWM`，`dumpsys meminfo`
只用来拿**分区**（Native Heap / Graphics / .so mmap）。原因：`dumpsys meminfo` 的列序随
Android 版本变，老版本最后一列是 "Rss Dirty" 而不是 RSS，拿它当总量会在跨机型上静默错。

### 决策 3：泄漏斜率不用最小二乘

方案写的是"5min 泄漏斜率"，第一版照字面用线性回归。构造 ±100KB 的采样锯齿（GC 锯齿的
真实形状）后，回归给出 **181.8 KB/min 的假泄漏**。改成"三等分、取两端 1/3 的 RSS 中位数差 /
中位时刻差"：锯齿归 0，真线性上升段仍精确。判级阈值随之定在 >2000 KB/min = LEAK /
200~2000 = 观察 / 其余 PASS。

**恒红的门禁等于没有门禁** —— 这条决定了脚本能不能当门禁使用。

### 决策 4：三路取数，而不是只看一个总 RSS

native 位图（M10/M11/M12）只在 native 侧显形，Dart 对象常驻（M16/M17/M19）只在 isolate 堆
显形。所以同时取：`/proc` RSS、`dumpsys meminfo` 分区、VM Service 每 isolate `getMemoryUsage`。
**两路相减是区分"位图泄漏"与"Dart 对象堆积"的唯一手段**，只看总 RSS 会把两类问题混成一条曲线。

### 决策 5：应用侧常驻开销只加一处心跳，落在 `app.dart`

`_PiggyAppState` 已经是 `WidgetsBindingObserver`，再加一个 `main.dart` 侧 observer 是重复设施。
每 30s 写一行 `[mem] rss=… max_rss=…` 进既有 `logger_service`，不建新表、不建 watchdog、不加原生通道。
代价明写：2000 条环形缓冲每 30s 占一格，16.7 小时填满。

## 二、方案里被证伪的两个 API 前提（按代码纠正）

1. **`dart:ui MemoryInfo` 在 Flutter 3.44.3 不存在**（`sky_engine/lib/ui/` 全目录零命中）。
   `maxRss` 只有 `dart:io` 的 `ProcessInfo`（另有 `currentRss`）→ 心跳用 `ProcessInfo`。
2. **`AppLifecycleListener` 没有内存压力钩子**。真出口是
   `WidgetsBindingObserver.didHaveMemoryPressure`（`binding.dart:402`，由 `:1376` 派发）。

## 三、否决项（与被否决的东西一样要写清楚）

| 项 | 否决理由 | add when |
|---|---|---|
| `_getImageInfo` 顺带 `targetWidth: 256` 降采样 | 读出的宽高不只本地显示：会写进同步 payload（`transactions_json.dart:251`、`sync_diff_service.dart:627`）与备份元数据（`attachment_export_import_service.dart:205` → `data_import_service.dart:1525` 回写）。把"实测宽高"换成"降采样后宽高"= 改一条跨端元数据语义。grep 未发现任何 UI 用它做布局 | 解码耗时有实测证据时，另立项评估 |
| 手写 JPEG/PNG 文件头解析做到零解码 | 同上，收益未证 | 解码耗时实测 |
| provider 全量改 `autoDispose` | `database_providers.dart`、`theme_providers.dart` 的常驻是**正确语义**，强行 autoDispose 会关 DB 句柄 / 主题闪白 | — |
| `.select()` 收敛 rebuild | 全仓 0 处；那是 rebuild 优化不是内存优化，而本轮已砍掉 FPS/重建遥测，没有数据无法选点 | 真机 FPS 门禁指出具体热点页 |
| 常驻遥测（`PerfMetricLog` 表 / `perf_watchdog.dart` / iOS `os_proc_available_memory` / `addTimingsCallback` FPS 上报） | 每 30s 写 prefs 本身就是开销；脚本基线还没跑 | 脚本基线跑完仍复现不了真机用户报的 OOM |
| Sentry / Crashlytics | 移动端要原生 SDK + 常驻 breadcrumb 队列（自身基线 10-20MB，与本轮目标相反）；本仓已有自建网络栈；Crashlytics 自身在低内存下 OOM | — |
| PRAGMA 挂 `NativeDatabase(setup:)` / 改 `DatabaseConnection.custom` | **2026-10-05 更正**：`setup` 与 `createInBackground` **不互斥** —— drift 2.35.0 的 `createInBackground` 就有 `DatabaseSetup? setup` 形参（`drift/lib/native.dart`，官方注释原话 "set encryption keys for SQLCipher implementations"）。本仓不用它的真实理由是：`setup` 在 drift 就绪**之前**执行、拿不到库对象，而 WAL / `journal_size_limit` 挂在每条连接都会跑的 `beforeOpen` 已足够；`DatabaseConnection.custom` 仍会绕开 `database_health_service` 的 `quick_check` 通路 | 需要"连接一建立就设置"的能力时（如 SQLCipher 的 `PRAGMA key`，见 `prd/sqlcipher_db_encryption/design.md` §3） |
| **M2-b：物化 `daily_totals(day_key, ledger_id, income, expense, cnt)` + 删首页全量 fallback**（2026-10-05 判为不做） | ① M2-a 已把日合计压成单条 SQL 聚合（`getDailyTotalsInRange`，走既有索引、区间被窗口限住），物化表要换来的那点常数级收益**没有任何实测支撑**（B6 真机基线至今是空表）；② 物化是**派生状态**，得在 add / update / delete / softDelete / restore / purge / import / 云合并 / 清账本 / 周期生成**每一条写路径**上维护，漏一条就是"表头数字与明细对不上"的静默错误 —— F1-a 当初正是为躲开这类人工谓词才选"整行搬进回收站"的 correct-by-construction；③ 它是本地表还是同步表本身又是一个新决策（本地则云恢复后必须全量重算）；④ 首页兜底也不是白拿：删掉 `cachedTransactionsProvider` 会让冷启动/切账本首帧从"20 条"变成"空白" | 真机基线在 L 档（10 万笔）上显示**日合计聚合本身**是首页耗时热点时另立项；届时必须同时给"可关、可批量重算、有索引"三件（Firefly III #11531 / #11620 的教训） |
| **TODO-M12b：PNG 本体降采样重编码**（2026-10-05 维持不做） | 一次动作能永久修掉 7 个引用点并减包体，但它是**二进制资产变更**：需要图像工具链 + 目视复核重编码后的观感（本环境无真机、无截图对比手段），且必须与海报侧 `cacheWidth: 256` 及 `annual_report_page` 的 `precacheImage` 缓存键**同值耦合**（改错就是海报 logo 空白） | 有图像工具与目视复核条件、且基线显示启动峰值仍被 logo（`piggycountassets_*` 解码 11.5MB / `logo2.png` 4MB）主导时 |

### 2026-10-05 追加：M2 的落地形态与余量

- **M2-a 已落地**：`watchTransactionWindow`（keyset 游标 + LIMIT）+
  `getDailyTotalsInRange`（日合计下沉 SQL）+ 首页窗口切流。首页常驻从"整本账本"
  变为"已滑过的页数 × 100"（`kTransactionWindowSize`）；窗口 `limit` **只增不减**，
  已显示的行不会被挤出，日分组器的删除检测语义因此不变。
- 日合计由 `homeDayTotalsProvider` 出（family key = 已加载窗口最旧的一天 —— 刻意
  不依赖窗口流本身，否则整窗行会被 provider 再持有一份，内存翻倍）。
- 回归：`test/repositories/transaction_window_regression_test.dart`（5 例，含同秒
  多笔的 keyset 边界与"日合计 vs Dart 累加"逐值对拍）、
  `test/providers/home_tx_window_providers_test.dart`（2 例）。
- **收益仍是算式不是实测**：无真机，RSS 前后对比、以及"触底加载 / 月份跳转撑窗口"
  两条交互都没有设备证据；按本文 §三 的口径，B6 基线回填前一律算"未证"。
- M2-b 见上方否决项；M18 的 `cache_size` / `mmap_size` 维持不设（见 `db.dart` 的
  `beforeOpen` 注释里的定论与复访条件）。

## 四、唯一可能增加 RSS 的项怎么处理

M18（PRAGMA）里 `cache_size=-8192` + `mmap_size` 是**用内存换读盘**，RSS 可能上升。
它排在 B6 之后判，出口是回读断言（`journal_mode` 必须为 `wal`、`cache_size`/`mmap_size`
必须等于设定值）。原先"检测到 `-wal`/`-shm` 就打 warning"的逻辑与显式 WAL 冲突，降为 info，
否则每次启动都告警。
