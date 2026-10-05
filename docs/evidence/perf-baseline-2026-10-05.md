# 性能三基线 · 采集流程与验收表（建议 #13）

日期：2026-10-05
**状态：未实测** —— 本轮工作区只有模拟器/桌面，没有可跑的 Android **真机**；本文是
**已自检过的脚本 + 固定列名的空表**。拿到真机后按第 1~3 节跑完，回填第 4 节。
在此之前，任何耗时/帧率数字都**不得**当实测写进结论。

> 口径：内存维度的基线另有专项（`docs/evidence/mem-baseline-2026-09-19.md` +
> `scripts/profile_memory.py`）。本文只管**冷启动 / 页面切换 / 列表滚动 FPS**三条
> 用户可感知的延迟基线，即 `prd/README.md` 里「建议 13」尚未完成的那部分。

## 1. 三条基线怎么取（都不引入新依赖）

| 基线 | 脚本 | 取数口径 | 为什么是它 |
|---|---|---|---|
| 冷启动 | `scripts/profile_cold_start.py --mode cold` | `am force-stop` → `am start -W` 的 `TotalTime`/`WaitTime` | Android 官方口径；`TotalTime` 含进程创建 + 首帧渲染，跨机型可比。不用 `flutter run` 的控制台日志（受调试模式拖慢） |
| 页面切换 | `scripts/profile_cold_start.py --mode nav` | VM Service `getVMTimeline`，期间用 `input tap` 驱动切页 | 复用 `scripts/profile_frames.py` 已验证的 timeline 解析；切页卡顿是 UI 线程帧，不是 `am start` 能测的 |
| 列表滚动 FPS | `scripts/profile_frames.py` | VM Service timeline 的帧事件分布 | 已有脚本，本轮不动 |

```bash
# 冷启动（profile 构建，10 次取中位）
python scripts/profile_cold_start.py --mode cold --adb-serial <serial> \
    --package com.wait.piggycount --runs 10 \
    --version-sha $(git rev-parse --short HEAD) \
    --out docs/evidence/perf-baseline-2026-10-05

# 页面切换（先手动停在首页，给出要点的一串坐标）
python scripts/profile_cold_start.py --mode nav --adb-serial <serial> \
    --vm http://127.0.0.1:<port>/<token>= \
    --taps "540,1800;540,300;540,1800;540,300" \
    --version-sha $(git rev-parse --short HEAD) \
    --out docs/evidence/perf-baseline-2026-10-05

# 列表滚动 FPS（原脚本）
python scripts/profile_frames.py --vm http://127.0.0.1:<port>/<token>= \
    --adb-serial <serial> --seconds 12 --out docs/evidence/perf-baseline-2026-10-05-frames
```

每次跑产出 `<out>-<label>.summary.json`，并往 `<out>-rows.md` **追加一行**
（列名与第 4 节验收表一致，直接粘）。不连设备的那部分有自检：

```bash
python scripts/profile_cold_start.py --self-check   # am start 解析 / 统计 / 判级
python scripts/profile_frames.py                    # 无 --self-check（原脚本按需连设备）
python scripts/profile_memory.py --self-check
```

## 2. 判定阈值（**启发式，非实测**；拿到真机后按实际分布校准）

| 指标 | PASS | 观察 | 差 |
|---|---|---|---|
| 冷启动 `TotalTime` 中位 | ≤ 1200 ms | ≤ 2500 ms | > 2500 ms（SLOW） |
| 切页 UI 帧 `p90` | ≤ 16.67 ms（60fps 单帧预算） | ≤ 32 ms | > 32 ms（JANK） |

阈值写死在 `scripts/profile_cold_start.py` 顶部常量（`COLD_PASS_MS` / `COLD_WATCH_MS` /
`JANK_FRAME_MS` / `BAD_P90_MS`）。**恒红的门禁等于没有门禁**，所以这三个数在真机数字
回填前只是"提醒级"，不接 CI。

## 3. 应用侧采集器（debug 仪表盘）

`prd/mem_baseline_and_leaks/design.md` 当初否决了常驻遥测（每 30s 写 prefs 本身就是
开销、且基线还没跑）。本轮按用户要求补一个**仅 debug / 开发者入口可见、release 不常驻**
的采集器 `lib/services/platform/perf_metrics_collector.dart`：

- 用 `WidgetsBinding.instance.addTimingsCallback` 取帧耗时（`FrameTiming` 含
  build/raster 两段），环形缓冲最近 N 帧，供仪表盘页 `dev_perf_dashboard_page` 实时展示；
- 读数与本文脚本**同口径**（UI/raster 分列），便于"应用内看到的"与"脚本采到的"对账；
- release 构建下不启动（门控 `kDebugMode`），零常驻成本。

## 4. 验收表（跑完回填；列名固定）

| 场景 | 数据集 | 版本sha | 采样数 | 中位(ms) | p90(ms) | 最差(ms) | 判定 |
|---|---|---|---|---|---|---|---|
| 冷启动（profile 构建） | none |  |  |  |  |  |  |
| 首页 → 明细 → 返回 | M |  |  |  |  |  |  |
| 首页 → 洞察 → 报表 | M |  |  |  |  |  |  |
| 首页连续滚动 30 屏（FPS） | M |  |  |  |  |  |  |
| 大账本首页滚动（FPS） | L |  |  |  |  |  |  |
| （对照组）本轮加固前的构建 | M |  |  |  |  |  |  |

回填规则：每行由 `profile_cold_start.py` / `profile_frames.py` 追加；对照组在收口前的
commit 上重跑同一场景 —— **本轮任何性能"收益"都是这两行的差**，没有它就是"收益未证"。

## 5. 拿到设备后的头三件事（避免白跑）

1. 基线要在 **profile 构建**上跑（`flutter run --profile` / `--release` 装真机），
   debug 构建的冷启动/帧耗时不能代表用户；`--package` 按 flavor 填
   `com.wait.piggycount` / `.dev` / `.debug`。
2. VM Service URL 从 `flutter run --profile` 输出里取，端口与 token 随进程变；它掉了
   只影响"页面切换/FPS"两路，不影响冷启动（走 adb）。
3. 冷启动必须 **`am force-stop` 后跑**（脚本已做），否则测的是热启动；`--cooldown`
   默认 1.5s，机型慢时可调大。
