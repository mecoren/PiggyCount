# 真机验证清单（拿到设备照着做）

日期：2026-10-05
**状态：全部未执行** —— 本轮工作区只有模拟器 + 桌面，没有可跑的 Android/iOS **真机**。
本文件只回答一个问题：**拿到设备后，按什么顺序、用哪些命令、把结果填到哪里**。

> 约定（仓库既有口径，见 `prd/README.md`）：真机数字**不得**用模拟器值或算式顶替；
> 没跑之前相关表格一律留空并标「未实测」。

---

## 0. 准备

| 项 | 要求 |
|---|---|
| 设备 | 一台 Android 真机（建议 Android 10+，另留一台低端机做下界）；iOS 真机可选 |
| 构建 | **profile** 构建（`flutter build apk --profile`）。debug 有断言与 JIT，数字无意义 |
| 连接 | `adb devices` 能看到设备；`flutter devices` 能看到同一台 |
| 自检 | 先跑三条脚本的自检，确认脚本本身没坏（不连设备） |

```bash
python scripts/profile_cold_start.py --self-check
python scripts/profile_frames.py --self-check   # 若无该开关则跳过，本脚本按需连设备
python scripts/profile_memory.py --self-check
```

---

## 1. 性能三基线（冷启动 / 页面切换 / 列表滚动 FPS）

**照 `docs/evidence/perf-baseline-2026-10-05.md` §1 的三条命令原样跑**，命令与取数口径
（`am start -W` 的 `TotalTime`、VM Service timeline 帧事件）都写在那里，本文件不复制以免漂移。

要点：

1. 三条都带 `--version-sha $(git rev-parse --short HEAD)`：数字必须能对到某个提交。
2. 冷启动跑 10 次取**中位**（单次受系统调度影响大）；切页与 FPS 各跑 ≥ 3 轮。
3. 结果落在 `<out>-rows.md`（**列名固定，直接粘进验收表**）与 `<out>-*.summary.json`。
4. 判定阈值在 `scripts/profile_cold_start.py` 顶部常量（`COLD_PASS_MS` / `COLD_WATCH_MS` /
   `JANK_FRAME_MS` / `BAD_P90_MS`）—— 当前是**启发式**值，回填真实分布后**校准**它们；
   校准前不接 CI（恒红的门禁等于没有门禁）。

**回填位置**：`docs/evidence/perf-baseline-2026-10-05.md` §4 验收表（列名固定）。
同时把「环境」列写全：机型 / Android 版本 / 构建类型 / 是否插电 / 冷热状态。

**可选对账**：应用内 debug 仪表盘（`dev_perf_dashboard_page`，仅 debug 可见）与脚本**同口径**
（UI/raster 分列）。先在应用里看到大数，再跑脚本，两边差一个数量级就说明采样方式理解错了。

---

## 2. 无障碍真机三项（读屏 / 热区 / 大字号）

代码侧的门禁已在仓库里（`test/styles/contrast_token_test.dart`、字号 ratchet 基线与
`scripts/contrast_check.py`），**下面这三项只能在真机上做**，模拟器不算数。

### 2.1 大字号不破版

1. 系统设置 → 无障碍 → 字体大小调到**最大**；再叠加「显示大小（DPI）」调到最大。
2. 逐页扫：首页（含日汇总条）/ 记一笔（金额键盘 + 备注 + 账户选择）/ 详情 / 报表与图表 /
   海报 / 设置列表 / 云同步页。
3. 看什么：文字截断（非省略号）、控件重叠、按钮被挤出行外、弹窗超出屏幕、键盘遮挡。

**记到哪**：`docs/optimization-plan-2026-09-19.md` 的 U1/U2 节，逐条写「页面 → 现象 → 截图名」。

### 2.2 热区 ≥ 48×48dp

1. 开发者选项 → 打开「显示布局边界」/「指针位置」，或开 TalkBack 后用「显示触控区域」。
2. 主路径逐一点：底部导航、返回键、列表项右侧操作、数字键盘、日期滚轮、开关。

**记到哪**：同上；不达标项写清控件名与实测尺寸。

### 2.3 读屏（TalkBack / VoiceOver）

1. 开 TalkBack（Android）/ VoiceOver（iOS），关掉「触摸浏览」以外的辅助。
2. 走主路径：记一笔 → 首页 → 切账本 → 报表 → 设置 → 云同步 → 开关整库加密。
3. 看什么：每步都有可理解的朗读；没有「未标记按钮」「图片 xx」这类噪音；图标按钮读得出用途；
   数字与金额读到单位；弹窗出现时焦点自动进入且能读全。

**记到哪**：同上；除现象外，记下**哪一条 l10n 文案读起来不对**（改文案比改代码便宜）。

---

## 3. 整库加密（真机点开关 + 落盘取证）

> 本轮已在模拟器上用**探针入口**跑通了链路（加密后文件头非明文、40008 行完好、
> 关闭后回明文），见 `prd/sqlcipher_db_encryption/design.md` §7 的表。
> 但**开关 UI 这条路没在真机点过** —— 下面第 1~3 步就是补它。

前置：按 `prd/sqlcipher_db_encryption/design.md` §7.1 的配方启用 Android 的 SQLCipher
（`python scripts/fetch_sqlcipher_android_libs.py` + pubspec 里 `name_android: sqlcipher`）。

1. **点开关**：设置 → 加密设置 → 整库加密 → 打开 → 确认弹窗（3s 倒计时）→ 提示"重启后生效"。
2. **重启并观察首次迁移**：冷启动会先把整库迁为密文。记录**耗时**（模拟器 16.6MB ≈ 3.7s），
   并确认期间界面有反馈、不白屏卡死（数据量大时这里最需要确认）。
3. **落盘取证**（不 root 也能看）：

   ```bash
   adb shell run-as com.wait.piggycount sh -c \
     'od -An -tx1 -N 16 /data/data/com.wait.piggycount/app_flutter/piggycount.sqlite'
   ```

   > 包名按构建形态取：prod release = `com.wait.piggycount`，dev 风味 = `com.wait.piggycount.dev`，
   > debug 构建再加 `.debug` 后缀（见 `android/app/build.gradle` 的 `productFlavors` / `buildTypes`）。
   > `run-as` 只对可调试构建生效；release 包要看落盘，得用 root 设备或 `adb backup`。

   期望：**不是** `53 51 4c 69 74 65 20 66 6f 72 6d 61 74 20 33 00`（`SQLite format 3`）。
   应用内要能正常打开、能读到期初数据（掉数据是最严重的失败）。
4. **关闭加密往返**：设置里关掉 → 重启 → 再跑一次第 3 步，文件头应**回到明文**，数据一条不少。
5. **只读探针（可选交叉验证）**：`flutter build apk --debug -t tool/db_encryption_device_probe.dart`
   装上去跑一遍，日志里应出现 `[DbProbe] PROBE DONE (ok)`。

**记到哪**：`prd/sqlcipher_db_encryption/design.md` §7 的实测表（追加真机一行：机型 / 库大小 /
迁移耗时 / 文件头前后）。

---

## 4. 一键回填位置汇总

| 验证项 | 结果写进 |
|---|---|
| 冷启动 / 切页 / FPS | `docs/evidence/perf-baseline-2026-10-05.md` §4（列名固定） |
| 内存（既有专项） | `docs/evidence/mem-baseline-2026-09-19.md` |
| 大字号 / 热区 / 读屏 | `docs/optimization-plan-2026-09-19.md` U1/U2 节 |
| 整库加密真机 | `prd/sqlcipher_db_encryption/design.md` §7 实测表 |
| 三基线的**阈值校准** | `scripts/profile_cold_start.py` 顶部常量（校准后才考虑接 CI） |

跑完后顺手做两件收尾：把各表格的「未实测」字样删掉；把这些数字**回填到**对应
`prd/*/requirements.md` 的验收项，别只留在证据文档里。
