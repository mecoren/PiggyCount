# 内存基线 · 采集流程与验收表（B6）

日期：2026-09-19　版本：v0.7.8（Flutter 3.44.3 / Dart 3.12）
**状态：未实测** —— 本轮工作区没有可跑的 Android 真机/模拟器，本文是**已自检过的流程 + 空表**，
拿到设备后按下面五步跑完回填第 4 节。B7-B10 各项的内存收益目前全部是**算式**，等这张表出数字。

## 1. 灌语料（`scripts/seed_mem_baseline.py`）

三档数据集（方案 §B6 定义）：

| 档 | 交易 | 附件 | 用途 |
|---|---|---|---|
| S | 500 | 2 | 快速回归，脚本自检 |
| M | 10 000 | 200 | **主基线档**（方案里"1 万条交易 + 200 附件"） |
| L | 100 000 | 800 | nightly / 手动，复现 M2 首页全量与 M13 归档峰值 |

```bash
# ① 从设备拉库（应用先停，否则拉到的是一份没有检查点的 WAL 残片）
adb shell am force-stop com.wait.piggycount
adb exec-out "run-as com.wait.piggycount tar -c app_flutter" | tar -x -C ./pulled
# ② 灌数据（幂等：按现有条数补齐到目标，可反复跑）
python scripts/seed_mem_baseline.py --tier M --db ./pulled/app_flutter/piggycount.sqlite
# ③ 推回去（脚本末尾会原样打印这几条）
adb shell am force-stop com.wait.piggycount
adb push ./pulled/app_flutter/piggycount.sqlite /data/local/tmp/piggycount.sqlite
adb shell "run-as com.wait.piggycount rm -f app_flutter/piggycount.sqlite*"
adb shell "run-as com.wait.piggycount cp /data/local/tmp/piggycount.sqlite app_flutter/piggycount.sqlite"
adb push ./pulled/app_flutter/mem_seed_attachments /data/local/tmp/attachments
adb shell "run-as com.wait.piggycount cp -r /data/local/tmp/attachments/. app_flutter/attachments/"
```

脚本约定（都对着源码核过）：

- **只写 `transactions` / `transaction_attachments`，不新建账本/账户/分类**。新实体是"本地独有"，
  同步时容易被云端反向清掉，测基线要的是稳定语料。目标账本默认取交易最多的那个（`--ledger-id` 可指定）。
- 类型权重、金额区间、汇率折算**直接 import `scripts/inject_transactions.py`**，与既有语料同源。
- `happened_at` / `created_at` 单位是**秒**。实测依据：插 `2026-09-19T12:00Z` 后经 drift 落库，
  裸 SQL 回读 `created_at = 1789819200`（integer，10 位）；`ledgers.created_at` 的列默认值也是
  `CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)`。
- 附件行沿用应用自己的命名 `sha_<sha256>.jpg` 并填真实 `local_sha256`（读图路径按文件名找文件，
  `attachment_service.dart` 的 `backfillLocalSha256` 也按这个假设跑）。
- 合成附件是**近似纯色** JPEG（约 60KB/张，1920×1920）。附件的内存代价在**解码后**
  （1920×1920×4B = 14.7MB/张，`lib/services/attachment_service.dart:20-21`），与文件体积无关，
  所以合成图不影响解码峰值这一路测量。要真实体积（M13 的"归档峰值 ≈ 附件总量 ×3"）时
  加 `--from-photos <目录>`，脚本原样复制而不生成。
- 收尾执行 `PRAGMA wal_checkpoint(TRUNCATE)`：B10 起应用跑 WAL，让内容全落回主文件后，
  只推 `.sqlite` 一个文件才不会丢数据。

已验部分（本机，无设备）：`--tier M` 在 `seed_16384` 真实库副本上跑通 —— +5 000 笔 /
附件补到 200 行（该账本原有 1 行）、4.8s；`PRAGMA integrity_check = ok`；附件行 1920×1920、
`file_name == 'sha_' + local_sha256 + '.jpg'` 与文件实际 sha256 逐字节一致、零孤儿行、
重复 file_name 只多出语料自带的那一条跨账本去重行；**重跑一遍两阶段都报"已够，跳过"且行数不变**（幂等）。

## 2. 采集（`scripts/profile_memory.py`）

三路取数，缺一路就分不开"谁在吃内存"：

| 路 | 取什么 | 为什么必须是它 |
|---|---|---|
| `/proc/<pid>/status` | `VmRSS`（当前）、`VmHWM`（本进程峰值） | 稳定格式。不用 `dumpsys` 的 TOTAL：Android 版本间列序会变（老版本最后一列叫 "Rss Dirty"，不是 RSS），列序一变就静默读错 |
| `dumpsys meminfo <pkg>` | `Native Heap` / `Graphics` / `.so mmap` / `Dalvik Heap` … 分区 Pss | **位图与纹理记在 native 侧**，只有这路能看到；取不到留空，不污染主曲线 |
| VM Service `getVM` → 每 isolate `getMemoryUsage` | `heapUsage` / `heapCapacity` / `external` | **Dart 堆**。与 RSS 相减才能判断"是 Dart 对象常驻还是位图常驻"（本轮 M10/M11/M12 与 M19 的分界就在这里）。可选，不传 `--vm` 也出基线 |

```bash
python scripts/profile_memory.py --adb-serial <serial> --package com.wait.piggycount \
    --label 冷启动稳定 --dataset M --version-sha $(git rev-parse --short HEAD) \
    --seconds 90 --interval 1 \
    --vm http://127.0.0.1:<port>/<token>= \
    --out docs/evidence/mem-baseline-2026-09-19
# 滚动档加 --swipes 30（复用 scripts/profile_frames.py 的滑动实现，按模拟器 1080×1920）
```

每次跑产出 `<out>-<label>.samples.csv`、`.summary.json`，并往 `<out>-rows.md` **追加一行**
（列名与第 4 节的验收表一致，直接粘）。

不连设备的那部分有自检：`python scripts/profile_memory.py --self-check`
（`/proc` 解析、`dumpsys` 分区解析含"列名对不上→整体留空"、斜率与判级）。

**斜率 estimator 的选择**（自检逼出来的）：最初按方案实现成最小二乘，构造一条 ±100KB 的
采样锯齿（GC 锯齿的真实形状）就给出 **181.8 KB/min 的假泄漏斜率**。改成"窗口三等分、
最早 1/3 与最晚 1/3 的 RSS 中位数差 / 中位时刻差"后同一条锯齿是 0，线性上升段仍精确 600 000。
判级阈值因此定在 **>2000 KB/min = LEAK / 200~2000 = 观察 / 其余 PASS**：抖动残量落在
百 KB/min 这一档，而本轮要抓的泄漏（整本账本明文常驻、海报位图不释放、附件全尺寸解码）是
MB/min 量级，阈值不该去追那个量级以下。

## 3. 应用侧心跳（已落地）

`lib/app.dart`：`_startMemoryHeartbeat()`（`initState` 里随 observer 一起起）每 30s 写一条
`[mem] rss=…MB max_rss=…MB` 到既有 `logger_service`；`didHaveMemoryPressure()` 覆写记 warning。
用途是把 `dumpsys` 曲线和"用户当时在干什么"对上（脚本侧只有时间戳）。

- 用 `dart:io` 的 `ProcessInfo.currentRss` / `maxRss`。方案原文写的 `dart:ui MemoryInfo` **在本版本不存在**
  （3.44.3 的 sky_engine `lib/ui/` 全目录零命中 `MemoryInfo`；`maxRss` 只在 `dart:io` 的 `ProcessInfo`）——已按代码纠正。
- 内存压力回调同理：`AppLifecycleListener` **没有** memory-pressure 钩子，
  真出口是 `WidgetsBindingObserver.didHaveMemoryPressure`（`binding.dart:402`，由 `binding.dart:1376` 派发）。
- release 下这些行**不进 logcat**（`logger_service.dart:572` 的 `debugPrint` 受 `kDebugMode` 门控），
  读法 = 应用内"日志中心"页导出。
- 代价：2000 条环形缓冲里每 30s 占一格（16.7 小时才填满），换得到带场景标签的基线。

## 4. 验收表（跑完回填；列为方案 §B6 定死的列名）

| 场景 | 数据集 | 版本sha | TOTAL RSS | Native Heap | Graphics | Dart old-gen | 峰值 | 峰值时刻动作 | 稳态 | 5min 泄漏斜率(KB/min) | 判定 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 冷启动稳定 | M |  |  |  |  |  |  |  |  |  |  |
| 首页连续滚动 30 屏 | M |  |  |  |  |  |  |  |  |  |  |
| 附件预览翻页 20 张 | M |  |  |  |  |  |  |  |  |  |  |
| 生成并分享年度报告海报 | M |  |  |  |  |  |  |  |  |  |  |
| 同步导入 5 本大账本 | L |  |  |  |  |  |  |  |  |  |  |
| （对照组）同场景 B7-B10 之前的构建 | M |  |  |  |  |  |  |  |  |  |  |

回填规则：每个场景一行由 `profile_memory.py` 追加，第 6 行（对照组）在收口前的 commit 上重跑同一
场景得到 —— **B7-B10 各项的"收益"就是这两行的差**，没有它按方案 §七 判"未落地"。

## 5. 拿到设备后的头三件事（避免白跑）

1. `adb shell "run-as <pkg> ls app_flutter"` 先确认能进应用私有目录（release 不可调试，
   基线要在 **profile 构建**上跑；`--package` 按 flavor 填 `com.wait.piggycount` / `.dev` / `.debug`）。
2. VM Service URL 从 `flutter run --profile` 的输出里取，端口和 token 都随进程变；
   它只给 Dart 堆，掉了不影响 RSS 主曲线。
3. 测同步档（L）前先退出云账号或关网络：10 万笔语料一旦被 fullPush 上传，测的就不是内存了。
