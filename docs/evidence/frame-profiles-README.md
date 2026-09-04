# 帧率实测交付物（2026-09-04）

## 文件说明

| 文件 | 内容 |
|---|---|
| `frame-profile-home-scroll-2026-09-04.json` | 首页交易明细列表滑动帧统计（427 笔交易/3 个月数据，分组卡片懒加载） |
| `frame-profile-analytics-scroll-2026-09-04.json` | 洞察页（Line/Bar/Pie 图表 + 列表）滑动帧统计 |
| `frame-trace-home-2026-09-04.pftrace` | 首页原始 perfetto trace（16MB），可用 https://ui.perfetto.dev 打开复演 |
| `frame-trace-analytics-2026-09-04.pftrace` | 洞察页原始 perfetto trace（10MB） |
| `sync-interruption-stress-2026-09-04.log` | 同步模块 100 轮随机中断重试压测日志 |

## 采集方法（与 DevTools Performance 视图同源）

- 构建：`flutter build apk --profile`（dev flavor，Vulkan/Impeller 后端）
- 设备：MuMu 模拟器（x86_64, Android 15, API 35）
- 数据：427 笔交易跨 2026-07~09（注入 sqlite，drift epoch-seconds 时间戳），3 账户 60 分类
- 采集：`perfetto` atrace（gfx/input/view/wm/sched + app 分类）15s 录制，
  ADB `input swipe` 8 组慢速 fling 模拟用户连续滑动
- 统计口径：app SurfaceView 的 `onFrameAvailable` 帧提交时间戳间隔
  （掉帧 = 提交间隔跨越 vsync 周期）；>100ms 间隔剔除（滑动命令间静止期）

## 结果

| 场景 | 有效帧 | 中位间隔 | 平均间隔 | p99 | 最差 | 等效帧率 | >25ms 卡顿 |
|---|---|---|---|---|---|---|---|
| 首页明细滑动 | 649 | 16.70ms | 16.67ms | 22.45ms | 30.3ms | **60.0 fps** | 0.3% |
| 洞察页滑动 | 336 | 16.69ms | 16.63ms | 18.18ms | 30.1ms | **60.1 fps** | 0.3% |

两场景均 vsync 锁步稳定 60fps（模拟器刷新率上限 60Hz），无 >32ms 帧、
无 >700ms 冻结窗口。90/120Hz 高刷验证需真机（模拟器 vsync 上限 60Hz，
DevTools 中 UI/GPU 帧预算相应为 16.67ms——实测中位 16.70ms 达标）。

## 复现命令

```bash
flutter build apk --profile -d <device>
python scripts/profile_frames.py --vm <dart-vm-uri> --adb-serial <serial> \
    --seconds 12 --swipes 12 --out frame-home   # 帧事件采集脚本（VM timeline）
# perfetto 录制（本次采用）：
adb shell perfetto -c /data/local/tmp/trace_cfg.txt --txt -o /data/local/tmp/trace
# trace_cfg: atrace_categories: "gfx input view wm sched" + atrace_apps: <pkg>
```
