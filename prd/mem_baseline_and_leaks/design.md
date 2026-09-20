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
| PRAGMA 挂 `NativeDatabase(setup:)` / 改 `DatabaseConnection.custom` | 前者与 `createInBackground` 互斥；后者绕开 `database_health_service.dart:157` 的 `PRAGMA quick_check` 通路 | — |

## 四、唯一可能增加 RSS 的项怎么处理

M18（PRAGMA）里 `cache_size=-8192` + `mmap_size` 是**用内存换读盘**，RSS 可能上升。
它排在 B6 之后判，出口是回读断言（`journal_mode` 必须为 `wal`、`cache_size`/`mmap_size`
必须等于设定值）。原先"检测到 `-wal`/`-shm` 就打 warning"的逻辑与显式 WAL 冲突，降为 info，
否则每次启动都告警。
