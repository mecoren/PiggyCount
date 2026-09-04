# 120Hz 真机门禁（G1/G2）执行状态与操作指南

> 状态（2026-09-04）：**硬件依赖阻塞——当前环境无 120Hz 真机可接入**。探测过程与证据见下；拿到真机后按本指南执行，结果回填本目录即可闭环 G1/G2。

## 环境探测记录（2026-09-04）

| 探测项 | 方法 | 结果 |
|---|---|---|
| USB 真机 | `adb devices -l` + Windows PnP 设备扫描（WPD/Phone/Android/ADB/各手机厂商关键字） | **无任何手机设备**；USB 总线仅有集线器/复合设备 |
| 无线 ADB（本机端口） | `adb connect` 5555/5556/5557/30000/40000/40001/40123/45000 | 全部失败（其中 5555/5557 命中的仍是 MuMu 模拟器实例，已断开） |
| 无线 ADB（局域网） | 192.168.31.0/24 全段 TCP:5555 并发探测（0.4s 超时×64 线程） | **0 台开放** |
| 可用设备清单 | `flutter devices` / `adb devices -l` | 仅 4 个入口 = **同一对 MuMu 模拟器**（aurora 24031PN0DC + dm1q SM_S9110，x86_64 镜像），`emulator-5554` 与 `127.0.0.1:16384` 为同一实例、`emulator-5556` 与 `127.0.0.1:16416` 为同一实例 |
| 模拟器刷新率上限 | `dumpsys display` supportedModes | 两实例均 **60.000004Hz 物理模式**（alternativeRefreshRates 仅 15Hz 省电档），`frameRateCategoryRate high=90.0` 为软件能力声明、**无 90Hz 物理模式** —— >60fps 帧率在原理上不可测 |

结论：G1（120Hz 设备滑动 ≥90fps）/ G2（高刷无 >2 vsync 周期慢帧）的实测**必须依赖物理 120Hz 屏幕的真机**，当前开发环境无法提供。

## 拿到真机后的执行指南（复用既有基线）

1. **连接**：USB 数据线连接 120Hz 真机（开发者选项 → USB 调试开启；或无线调试配对后 `adb connect <ip:port>`）。确认 `adb devices` 出现真机序列号、`dumpsys display | grep -E "fps|supportedModes"` 显示 120Hz 模式。
2. **安装 profile 构建**（当前代码）：
   ```bash
   flutter build apk --profile
   adb -s <真机序列号> install -r build/app/outputs/flutter-apk/app-<abi>-dev-profile.apk
   ```
3. **注入数据**（与 60Hz 基线同 seed，保证可比）：参照 `docs/evidence/frame-profiles-README.md` —— 427 笔交易（seed 42）经 sqlite 注入 app_flutter/piggycount.sqlite（drift epoch-seconds 时间戳；错误的时间戳格式会导致列表为空，见审查报告第十二部分「工程事实」节）。
4. **采集**（与 60Hz 基线完全相同的滑动脚本与 perfetto 配置）：
   ```bash
   # perfetto 配置已在 docs/evidence/frame-profiles-README.md；atrace_apps 换成真机包名同款
   adb shell perfetto -c /data/local/tmp/trace_cfg.txt --txt -o /data/local/tmp/g1_trace &
   # 8 组慢速 fling（同基线）：
   #   input swipe 540 1450 540 600 450; sleep 1.8; input swipe 540 700 540 1500 450; sleep 1.8  × 8
   adb pull /data/local/tmp/g1_trace
   ```
   （或 USB 调试下直接 DevTools Performance 视图录制，截图交付即满足「DevTools 快照」原字面要求。）
5. **判定**（120Hz 下 vsync = 8.33ms）：
   - **G1 通过**：复杂页面（首页明细/洞察图表）滑动等效帧率 **≥90fps**（帧间隔中位 ≤11.1ms）；
   - **G2 通过**：帧间隔 >2 个 vsync 周期（>16.67ms@120Hz）的帧占比 <1%，无 >50ms 可感知卡顿帧、无 >700ms 冻结窗口。
6. **回填**：结果 JSON + 原始 trace 存入 `docs/evidence/`（命名沿用 `frame-profile-*-120hz-<日期>.json/.pftrace`），并把本文件状态行与审查报告第十三部分 G1/G2 状态从「未验证」改为实测结论。

## 60Hz 环境下的既有证据（模拟器可达上限，已达 ≥60fps 验收子项）

- after（d1852b8）：两场景 vsync 锁步 60.0/60.1fps、>25ms 卡顿 0.31%/0.30%、无 >32ms 帧、无冻结窗口（`frame-profile-home-scroll-2026-09-04.json`、`frame-profile-analytics-scroll-2026-09-04.json`）。
- before/after 前后对比（`frame-profile-before-after-comparison-2026-09-04.json`）：洞察页 before 1 帧 53.2ms 卡顿 → after >32ms 帧清零；>25ms 卡顿率 0.46%→0.31% / 0.59%→0.30%。
- 外推依据（非证据，仅工程判断）：60fps 锁步 + p99 22.45ms 说明帧工作远未饱和 16.67ms 周期；120Hz 下帧预算 8.33ms，需真机实测确认，不以此代证。
