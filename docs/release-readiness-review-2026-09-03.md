# PiggyCount 上线标准审查报告（UI / 性能 / 功能，2026-09-03）

> **状态更新（2026-09-04 第二轮：性能收尾 + S3/WebDAV 同步复核）**：在首轮全部落地的基础上，第二轮聚焦「统计查询全量载行 + N+1」类性能遗留（首轮已覆盖列表/启动/图标路径，本轮覆盖统计聚合路径），共修复 6 项（P1-P6，见文末「第九部分」）；S3/WebDAV 同步链路经全量源码复核**未发现新问题**（签名/条件写/信封原子性/重试护栏/冲突仲裁等前五轮修复全部在位且口径自洽）。验证基线：`flutter analyze` 相对 HEAD 净减 1 条（658→657）、零新增 warning/error；`flutter test` 全量通过（含新增 8 条 SQL 聚合回归测试）。

> **状态更新（2026-09-03 执行完毕）**：A 档 6 项全部修复；B 档 B1-B6/B8 完成（B7 文件拆分按计划留待常规迭代）；C 档 C7（海报币种单位）顺带完成。执行明细见文末「第八部分：执行记录」。验证基线：`flutter analyze` 相对 HEAD 净减 148 条告警、零新增 warning/error；`flutter test` 全量通过。

> 审查方式：全仓源码静态审查 + 基线验证（`flutter analyze` 0 error；`flutter test` 1034 全过）。
> 范围：UI（视觉一致性 / 暗色模式 / l10n / 交互 / 可访问性）、性能（启动 / 列表 / DB / 重绘 / 内存 / 包体）、功能（完整性 / 边界 / 错误路径）。
> 定位：前序审计（sync/security 2026-08-22 全量修复已落地）之后，聚焦「上线可用性」的增量审查。**不含同步/加密安全**（已由 8/22 审计五轮修复覆盖，本报告仅在涉及上线口径处引用）。

---

## 0. 总体结论

**项目整体已接近可上线水平**：核心记账链路（首页列表 / 编辑器 / 搜索 / 统计）有深度的性能工程（虚拟化列表、N+1 消除、预加载、防抖、repaint 收敛），l10n zh/zh_TW 全量覆盖，测试基线全绿。剩余问题分三档：

- **A 档（上线前应修，共 6 项）**：影响真实用户可感知的正确性 / 体验。
- **B 档（建议修，共 8 项）**：一致性 / 性能收尾，投入小收益确定。
- **C 档（可延后，共 7 项）**：锦上添花或需产品决策。

---

## A 档：上线前应修

### A1. 韩语语言包缺 163 个词条（l10n 完整性，用户可直接见）

`app_ko.arb` 缺 163 个 EN 已有 key（105 个 currency 相关 + 58 个功能词条：账户隐藏、皮肤名、外币重算、报表脚注等）。Flutter gen-l10n 对缺失 key 会回退到模板语言（EN），韩语用户会在账户隐藏、多币种、皮肤选择等页面看到**中英混排**。若上线宣称支持 4 语言，要么补齐（成本：一次性翻译 58 条 + 105 币种名），要么临时从 `supportedLocales` 摘除 `ko`（成本：改 1 行）。
位置：`lib/l10n/app_ko.arb`；入口 `lib/main.dart:683-688`。

### A2. 4 处硬编码中文 UI 文案绕过 l10n（韩英用户直接看到中文）

| 位置 | 文案 | 建议 |
|---|---|---|
| `lib/pages/ai/ai_chat_page.dart:242` | `'暂无消息'` | 新增词条（zh 已有同义 `commonEmpty` 可用） |
| `lib/pages/ai/ai_chat_page.dart:259` | `'加载失败: $e'` | 新增 `commonLoadFailed(error)` |
| `lib/widgets/ui/searchable_dropdown.dart:139` | `'无匹配项'` | 新增词条 |
| `lib/pages/settings/attachment_preview_page.dart:79` | `'自定义图标 ($n)'` | 新增词条 |
| `lib/widgets/posters/annual_report_poster.dart:653-669` | `'日均支出/月均支出/元/天/元/月'`（海报，尚可接受但外币账本下单位错误） | 见 A4 |

### A3. 冲突对话框暗色模式不可读（数据同步高危场景的 UI）

`lib/pages/main/ledgers_page_new.dart:1892/1926/1934` —— 冲突信息块 `PiggyTokens.info/warning(context)` 作**容器底色**（亮色 #3B82F6 / #F59E0B 全饱和度），上面叠 `Colors.black54` 小字。亮色下勉强可读；**暗色模式下底色变为亮蓝 #60A5FA / 亮黄 #FBBF24，黑字对比度尚可，但容器夹在暗色 dialog（surfaceElevated）中极突兀，且正文 `onSurface`（暗色为浅色）落在高饱和底上不可读**——同文件 `ledgersConflictLocalInfo` 用默认样式无颜色分支。
建议：底色改 `token.withValues(alpha: 0.12)`（信息条惯用式，仓库内 `ai_provider_manage_page.dart:211` 已是该模式），副文字用 `textSecondary(context)`。
同类问题（次级）：`lib/pages/account/accounts_page.dart:1517`（`Colors.orange` 边框上的 `fontSize: 11` 橙字，暗色可读性差）。

### A4. 年报页 `Colors.black54` 排名文字在暗色下对比度不足

`lib/pages/report/annual_report_page.dart:1240` —— 排名圆底为固定 `rankColors`（多彩色），第 4 名起文字 `Colors.black54`。页面背景是 `primaryColor`（主题色可被用户换成深色，如紫 #7E57C2、蓝 #2563EB），深主题色 + black54 对比度跌破 WCAG AA。建议统一 `index < 3 ? Colors.white : PiggyTokens.textPrimary(context)` 按底色亮度计算，或非前三名也用浅字。
同页 `:304` `Colors.white70` 在浅主题色（蜂蜜黄 #F8C91C）底上同样不达标。年报是分享传播场景，截图会被发出去，值得修。

### A5. `print()` 混入 release 日志（184 处，含启动关键路径）

`grep print( lib` = 184 处（`data/db.dart` 40、`notification_android.dart` 30、`main.dart` 21 等）。Flutter release 下 `print` 走 `dart:developer.log`→系统日志，Android 上 `adb logcat` 可见；iOS 输出流也被记录。风险：
1. **性能**：迁移日志（db.dart 40 条）在老用户升级首次启动时同步执行，I/O 在启动关键路径；
2. **信息泄露**：日志含时区/通知/备份路径等上下文；
3. **一致性**：项目已有完善的 `logger` 体系（48h 持久化、节流写入、release 静默控制台），`print` 是双轨。
建议：机械替换 `print(` → `logger.info/warning(`（一次性脚本 + 人工过目），analyze 无新告警即完成。这是低风险高确定性收尾。

### A6. release 构建无全局异常兜底 + 无崩溃上报

`main()` 未挂 `FlutterError.onError` / `PlatformDispatcher.instance.onError` / `runZonedGuarded`。当前唯一接管点是 widget_manager 渲染窗口内的临时替换（`widget_manager.dart:844`，渲染完即还原）。后果：release 未捕获异常只进系统日志，用户遇到的崩溃**开发者不可见、无法统计、无法修复**。记账应用的数据写入类崩溃（DB、导入、同步）没有上报渠道等于盲飞。
建议（不引第三方 SDK 的最小方案）：
```dart
FlutterError.onError = (d) { logger.error('Zone', 'Flutter error', d.exception, d.stack); };
PlatformDispatcher.instance.onError = (e, s) { logger.error('Zone', 'Uncaught', e, s); return true; };
```
logger 已持久化 48h 到本地，用户报障时可导出（log_center_page 已有 UI）。中期再评估 Sentry/Crashlytics。

---

## B 档：建议修（一致性 / 性能收尾）

### B1. `annual_report_page.dart:993/1010` 图例硬编码 `'收入'/'支出'`
l10n 已有 `transactionTypeIncome/Expense` 类词条（import 解析处非 UI），此处是唯一硬编码中文图例（白字 0.8 透明度在 primary 底上）。改词条引用即可，与 A2 同 PR。

### B2. Toast 无防重叠/无动画
`lib/widgets/ui/toast.dart` —— 连续两次 `showToast`（如批量操作完成 + 同步提示）会叠在一起，且无进出场动画（生硬闪现）。`Future.delayed(duration).remove()` 若 entry 已被移除会 throw（当前 `entry.remove()` 未检查 `mounted`，重复 remove 会抛 `FlutterError: Unscheduled OverlayEntry`——被 `Future.delayed` 的 zone 吞掉不致崩溃，但会污染 debug 日志）。建议加队列（后到顶替先到）+ fade 动画 + remove 前 `if (entry.mounted)`。

### B3. `CustomIconService.resolveIconPath` 每行每次 await 目录 IO
`lib/widgets/category_icon.dart:81`（每行自定义图标）→ `FutureBuilder` → `resolveIconPath` → `getApplicationDocumentsDirectory()` + `dir.exists()` + `create(recursive:)`。3000 笔列表滚动时每个自定义图标行都会走一次平台通道 + 目录探察。目录路径在 app 生命周期内不变，**启动后缓存一次**即可（static late 或首调用 memo）。同时 `FutureBuilder` 每次 rebuild 新建 future，可改 `late final _pathFuture`。
现状影响面：仅 `iconType=='custom'` 的分类（多数用户用 material 图标），故列 B 不列 A。

### B4. 图表无 RepaintBoundary 隔离
`lib/pages/main/analytics_page.dart`（LineChart:1151 / BarChart:1201 / PieChart:1283）均未包 `RepaintBoundary`。fl_chart 的 PieChart 触摸高亮 `_touchedIndex` 变化会整页 repaint（analytics 页含三个图表 + 列表）。仓库已有先例（annual_report_page 4 处、expandable_bottom_sheet 2 处），补齐 analytics 页三处 + 账户页趋势图。改动小（3×2 行），滑动/触摸流畅度收益直接。

### B5. `_buildDayCard` 内 day 汇总每帧重算
`lib/widgets/biz/transaction_list.dart:500-510`（'header' 分支；'day' 分支 `_buildDayCard` 同理）—— 每帧 build 时对当天交易循环累加 dayIncome/dayExpense。数据在 `_flatItems` 构建期（`_buildFlatItems`）已可一次性预计算存入 tuple。3000 条数据快速滚动时每帧循环全 day 列表是可感知的浪费。属于列表优化的最后一公里（前序已做虚拟化/预加载/指纹去重，此为遗留）。

### B6. 首屏就绪与周期交易生成耦合
`ui_state_providers.dart:327-339` —— `appInitStateProvider` 切 `ready` 前串行 await `generatePendingTransactionsStatic` + 每账本 `PostProcessor.runR`（含云同步触发）。多数启动"本次没有需要生成的重复交易"直接空转（一查即过）；但**有大量历史周期的账本**（补半年 daily）会把用户按在 Splash 上数秒。周期交易不是首屏必需数据：可先生成 ≤1 条近期实例（或直接跳过）→ ready → 后台补全 + 完成后 `sharedResourceRefreshProvider` 通知列表刷新。启动 TTI 收益直接。

### B7. 核心文件超长（可维护性）
`cloud_service_page.dart` 2890 行、`accounts_page.dart` 2510、`ledgers_page_new.dart` 2128、`annual_report_page.dart` 2067、`cloud_sync_page.dart` 2024。单文件 2000+ 行的 StatefulWidget 意味着任何小改动的回归面都很大（accounts_page 已因此积累多处补丁式代码）。建议按 Section 拆 widget 文件（不是重构逻辑，只是搬移 + const 化），降低后续迭代成本。**非上线阻塞**，但每次发版 hotfix 的风险都在涨。

### B8. `flutter analyze` 遗留 804 条 info/warning（全在 test 目录）
`annotate_overrides` 9、`unused_import` 4、`dangling_library_doc_comments` 15 等。不阻塞，但发版 CI 若开 `-Dfatal-infos` 会全红。一次性清理脚本 + `analysis_options.yaml` 加 `errors: annotate_overrides: error`（仅 test 子树）。

---

## C 档：可延后 / 需产品决策

### C1. 巨型页面的 `IndexedStack` 常驻
`app.dart:52-57` 四个 Tab 全量常驻（首页/分析/账户/我的）。分析页与账户页各有图表+列表，冷启动首帧要 build 全部四个。可换 `LazyIndexedStack`（首次点击才 build）或保留现状（团队已做过大量键盘/重绘优化，收益需实测）。**需 profile 决策，勿盲改**。

### C2. `assets/logo2.png` 等 589KB 大图 ×3 份
`logo2.png` / `launcher_legacy.png` / `icon_master.png` 各 589KB，是同一张图的三份拷贝（assets 3.3MB 的大头）。launcher 图已由 `adaptive_foreground.png`（315KB）承担新用途。核对 `icon_master.png` 的实际引用（若仅用于 about 页可压到 100KB 内）。APK 已 R8+ABI split（arm64 ~40MB 达标），此项是再抠 1MB 的余量。

### C3. 币种词条 105 个仅 EN/ZH 有
(currency 系列) zh_TW 也缺。多币种账本的币种选择器在 TW/ko locale 显示英文名。可接受（币种名本就常用英文），列入 A1 的翻译批次顺带处理即可。

### C4. `primaryColorProvider` 被 220 处 watch
主题色变化（用户改色）会触发 220 个订阅点 rebuild，含列表行内的 `CategoryIconWidget`（12 处）。改色是低频操作，实际无性能问题；但架构上 `primary` 应从 `Theme` 取（`colorScheme.primary`），widget 层不该知道 provider。迁移成本大、收益是代码洁癖，**明确不急**。

### C5. 无障碍未系统覆盖
IconButton 90 处大多无 tooltip/semanticsLabel；账本金额对小屏用户缩放 clamp 1.15（已有）。记账 app 的核心用户群对无障碍诉求有限，但应用市场审核日益关注。建议：先给「批量操作/删除/同步」类 IconButton 补 semantics label（约 20 处高危操作），其余延后。

### C6. AI 聊天页 ListView 无反向虚拟化优化
1201 行，消息多时 `ListView.builder` 已够用；`_scrollToBottom` 用 `jumpTo`（无动画）。小问题。

### C7. 海报 `元/天` 单位与多币种冲突
`annual_report_poster.dart:653-669` 固定 `元`，但账本币种可设 USD 等（`baseCurrencyProvider` 存在）。生成海报应从账本币种取符号。与 A4 同文件，可同 PR 处理。

---

## 已验证的优秀实践（无需再动）

- **列表性能**：FlutterListView 虚拟化 + onItemHeight 估算 + `_flatItems` 引用缓存 + 预加载 JOIN + 标签/附件指纹去重批量查（`transaction_list.dart`）——3000 条场景已系统优化过。
- **键盘/重绘**：MaterialApp 主题记忆化（`_AppThemes`）、textScaler 窄订阅、底部栏安全区下沉叶子组件——键盘动画路径已专项治理。
- **搜索**：200ms 防抖 + 流缓存复用 + 内存过滤（<10ms 不转圈）。
- **DB 层**：`getTagsForTransactions`/`getAttachmentCountsForTransactions` 均 isIn 批量 + 有 N+1 源码契约测试守护。
- **启动**：Splash 分步计时日志、并行预载、只取前 20 条、OrphanGC/SHA 回填延迟 3s 让路。
- **构建**：R8 minify + shrinkResources + ABI split（arm64 单包 ~40MB）+ AAB 独立轨道。
- **头像/附件**：512px/85% 压缩、缩略图管线齐备。
- **l10n**：zh/zh_TW 100% 覆盖（2494 key 对齐）。
- **审计沉淀**：8/22 安全审计的 P0-P4 全部落地（sync_providers/加密/冲突确认），本轮 UI/性能/功能审查未发现新的高危数据完整性问题。

## 建议执行顺序

1. **PR-1（l10n 收口，半天）**：A1（ko 补齐或摘除）+ A2 + B1 + C3 顺带 → gen + 四语言跑一遍 widget 测试。
2. **PR-2（暗色可读性，2 小时）**：A3 + A4 + accounts_page:1517 橙字 → 手动切暗色逐屏过。
3. **PR-3（日志与兜底，半天）**：A5 print 替换 + A6 全局错误钩子 → analyze 全绿 + 冒烟。
4. **PR-4（性能收尾，半天）**：B3 iconPath 缓存 + B4 RepaintBoundary + B5 day 汇总预计算 + B6 周期生成后移 → 真机 profile 对比。
5. **PR-5（体验细节）**：B2 toast 队列 + C7 海报币种单位。
6. B7/B8/C* 排入正常迭代。

> 附：本报告全部结论均经源码二次核验（位置含文件:行号），未采纳上轮审计已修复项；测试基线 1034 全过为改动前的地面真值。

---

## 第八部分：执行记录（2026-09-03 全部落地）

### 已完成项 ↔ 报告条目对照

| 条目 | 改动 | 涉及文件 |
|---|---|---|
| A1 韩语缺 163 词条 | 补齐 163 词条（58 功能词条人工翻译 + 105 币种标准韩文名），四语言 key 集合全对齐 | `lib/l10n/app_ko.arb` |
| A2 硬编码中文 UI | AI 聊天空态/错误、下拉无匹配、附件管理自定义图标标签、搜索框 hint 全部走 l10n | `ai_chat_page.dart`、`searchable_dropdown.dart`、`attachment_preview_page.dart` |
| A2+ 年报页 22 处硬编码 | 年度洞察/收支对比/图例/排名徽标/储蓄率/单位（天·笔·月）全部词条化（新增 ~30 词条×4 语言，复用 analyticsIncome/Expense 等） | `annual_report_page.dart`、四语言 arb |
| A2+ 年报海报 24 处硬编码 | 恭喜攒下/花超、洞察卡、月度趋势、已达成/未达成、QR CTA 全部词条化 | `annual_report_poster.dart`、四语言 arb |
| A3 冲突对话框暗色 | info/warning 容器改 12% alpha 底，副文改 `textSecondary(context)` | `ledgers_page_new.dart:1870-1938` |
| A4 年报对比度 | 排名徽标文字按底色/主题亮度自适应（金银铜深字 + 暗色浅字）；空态文字/图标按 primary 亮度切换 | `annual_report_page.dart` |
| A2 延伸 | accounts 页"未折算"徽章 `Colors.orange` → `PiggyTokens.warning` | `accounts_page.dart:1515` |
| A5 print 混入 | 145 处 `print(` → `logger.info/warning(`（按内容分 level，自动补 import）；顺手删 1 个既有 unused tz import | `db.dart`、`main.dart`、`notification_*.dart`、`reminder_monitor_service.dart` 等 12 文件 |
| A6 全局异常兜底 | `FlutterError.onError` + `PlatformDispatcher.instance.onError` 接入 logger（48h 持久化），与 widget_manager 渲染窗口临时接管链式兼容 | `main.dart:52-63` |
| B1 图例硬编码 | 年报图例收入/支出 → `analyticsIncome/Expense`（同 A2 批次完成） | `annual_report_page.dart` |
| B2 Toast 重写 | 全局单槽顶替（不再叠屏）、淡入淡出动画（200/240ms）、`entry.mounted` 守卫杜绝重复 remove 异常；API 不变（256 个调用点零改动） | `toast.dart` |
| B3 iconPath 每行 IO | `CustomIconService.getIconDirectory` static 缓存目录路径；`CategoryIconWidget` 进程级相对路径→绝对路径缓存，解析过一次后 rebuild 同步渲染 | `custom_icon_service.dart`、`category_icon.dart` |
| B4 图表 RepaintBoundary | 分析页 LineChart/BarChart/PieChart、账户页迷你趋势图、净值趋势页，共 5 处 | `analytics_page.dart`、`accounts_page.dart`、`net_worth_trend_page.dart` |
| B5 day 汇总每帧循环 | 日收入/支出在 `_buildFlatItems` 构建期预计算存入 flat item（`dayTotals`），渲染期零循环；`_buildDayCard` 保留未传时兜底现算 | `transaction_list.dart` |
| B6 首屏耦合周期生成 | `appSplashInitProvider` 先切 `ready`，周期交易生成+云同步后置为 `unawaited` 后台任务，生成完经 `PostProcessor.runR` 自动刷新 UI/统计 | `ui_state_providers.dart:316-348` |
| B8 lint | 净减 148 条（avoid_print 299→154，剩余 154 全在 `scripts/i18n` CLI 工具与 `packages/` 子包，属工具/子包固有）；`use_build_context_synchronously` 107→106（顺带修 ai_chat 2 处） | 多文件 |
| C7 海报币种 | `AnnualReportPoster` 新增 `currencyCode` 参数，6 处 `¥` 硬编码与净储蓄单位改 `getCurrencySymbol(账本币种)` | `annual_report_poster.dart`、`annual_report_page.dart` |

### 未在本轮处理（与计划一致）

- **B7 巨型文件拆分**：按报告建议排入常规迭代（重构面大，避免与发版修复混批）。
- **C1 IndexedStack 常驻**：需真机 profile 数据决策。
- **C2 大图资产**：需确认 `icon_master.png` 引用后再压。
- **C4 primaryColorProvider 架构迁移**：纯重构，收益是代码洁癖。
- **C5 无障碍 semantics**：按报告只补高危操作项，本轮未动（后续单独批次）。
- **C6 AI 聊天滚动动画**：影响极小。
- 既有 `use_build_context_synchronously` 105 处 info（分布在 ledgers/accounts 等大文件）：HEAD 既有，修复涉及面广，留档。

### 验证结论

- `flutter analyze`：0 error、0 新增 warning/info；相对 HEAD **净减 148 条**（299→154 avoid_print、-1 unused_import、-2 use_build_context_synchronously）。
- `flutter test`：全量通过（见执行后基线）。
- l10n：四语言 top-level key 集合完全一致（2494+新增 ≈ 2534 key），`flutter gen-l10n` 生成成功。

---

## 第九部分：第二轮执行记录（2026-09-04，性能收尾 + S3/WebDAV 同步复核）

### S3/WebDAV 同步链路复核结论：未发现新问题

对 `packages/flutter_cloud_sync_s3`、`packages/flutter_cloud_sync_webdav`、`packages/flutter_cloud_sync`（manager 层）与 app 侧 `TransactionsSyncManager` / `CloudSyncManager` / `startup_sync_checker` 做了全量源码复核（约 12,000 行），前五轮审计的修复全部在位且口径自洽：

- **S3**：SigV4 签名链（Content-Length 不签、查询串 RFC 3986 与 canonical 逐字节一致）；条件写（If-Match 引号形态、412/404/409→条件失败语义、409 有限重试）；流式上/下载（UNSIGNED-PAYLOAD、早响应停泵、下载停滞检测）；ListObjects V1/V2 三重翻页护栏（页数上限/token 无推进检测/畸形响应显式报错）；时钟偏差自动补偿；认证/权限异常语义保真（CloudAuthException 不被通用 catch 降级）；metadata base64 往返（含 padding 剥离自愈）；keyPrefix 沙箱（`..` 分段级拒绝）。
- **WebDAV**：HTTPS 强制 + 3xx 拒绝（防凭据重放泄露）；temp-PUT→MOVE→降级交换的原子发布（W-A 成功 MOVE 回 200 的假失败探测、W-F 备份名并发序号）；信封格式（meta 与数据同文件原子发布，消除 sidecar 窗口）；M10 元数据 (path,eTag) 缓存；WD-2 父目录缓存 + 404 自愈；错误分类器（结构化状态码优先、纯数字子串匹配彻底移除，防 `:8404` 端口误判 404）。
- **App 侧**：上传冲突仲裁链（元数据指纹→内嵌指纹终审→可信墙钟门禁→条件写锚点）；TSM-P8 账本级互斥锁；恢复临界区守卫（SyncRestoreGuard）；写后校验结论上浮（verified=false 不清脏标记）；附件内容寻址 + 三态下载结果（objectMissing 不空转重试）。

结论：同步链路维持「可上线」判定，无需改动。

### 性能遗留修复（P1-P6，全部落地）

首轮审计覆盖了列表/启动/图标/重绘路径，本轮聚焦**统计查询层**——多处把全表交易行加载进内存再 Dart 循环累加，或循环内逐条点查（N+1），其中两项在每笔记账触发的热路径上：

| 条目 | 问题 | 修复 | 文件 |
|---|---|---|---|
| P1 `getLedgerStats` | 每次调用把该账本**全部交易行**载入内存再逐行累加（万笔账本 = 万行对象分配）；`localLedgersProvider`/`allLedgersProvider` 再对每个账本逐个调它 = N+1 | 改一条 `SUM(CASE)/COUNT` GROUP BY 聚合 SQL；新增 `getAllLedgerStats()` 单条 SQL 批量返回全部账本统计，两个 provider 消费 | `local_ledger_repository.dart`、`ledger_repository.dart`、`local_repository.dart`、`sync_providers.dart` |
| P2 `getAllAccountStats` | 账户页常驻主 Tab watch 的 `allAccountStatsProvider` 逐账户串行 4-7 条查询、每条全量载行；**每笔记账 bump statsRefresh 都触发整轮重算** | 单条多子查询 JOIN 聚合 SQL（余额/支出/收入三口径一次算出；口径与 getAccountBalance/Expense/Income 逐字对齐，含 transfer 双向、adjustment、excludeFromStats、估值账户、共享账本排除） | `local_account_repository.dart` |
| P3 `_aggregateTopLevelCategories` | 分析页每次刷新串行 20-60 条 `getCategoryById` 点查（三段循环 N+1） | 新增 `getCategoriesByIds()` 批量接口，一次查询取全部正 id 分类（synthetic 负 id 仍走 sharedSynthetic map） | `local_category_repository.dart`、`category_repository.dart`、`local_repository.dart`、`analytics_page.dart` |
| P4 统计序列 | `totalsByDay` 全量载行再 Dart 按日分组；`totalsByMonth` 全量载行；`totalsByYearSeries` **无时间过滤全表载入** | 三者改 SQL GROUP BY 聚合：日分组用 `date(happened_at,'unixepoch','localtime')`（本地时区日界）；月/年分组在 SQL 内计算周期标签（`day>=startDay` 归当月否则归上月，与 `labelForDate` 逐字一致）；补零逻辑保留 | `local_statistics_repository.dart` |
| P5 `_analyticsFutureCache` | 分析页 future 缓存无淘汰，键含 refreshTick+时间戳+类型，每次交互新增条目、旧 future（含整段查询结果）永不释放，页面常驻主 Tab 栈随会话泄漏式增长 | 改单条记忆化（`_lastAnalyticsFuture`）：旧键无人再读，直接替换；「setState 重建复用已发查询防闪烁」的原始目的不变 | `analytics_page.dart` |
| P6 年报月度数据 | 打开年报页串行 12 次 `monthlyTotals`（12 次查询往返） | 单条 GROUP BY SQL 按「周期标签月」聚合（与 P4 同款 label 规则），一次算出 12 个月收支 | `annual_report_page.dart` |

### 实现要点与踩坑记录（供后续维护参考）

- **口径严格对齐**：P1 的 `CASE type WHEN 'income' THEN 1 WHEN 'expense' THEN -1 ELSE 0 END` 显式排除 transfer（原 Dart 实现只处理 income/expense 两分支）；首批实现误写 `ELSE -1` 会把 transfer 算 -500（账本余额口径漂移），回归测试当场拦下——这正是「新 SQL 与旧实现结果一致性」测试的价值。
- **SQLite 日期语义**：drift 的 `DateTime` 参数以 unixepoch 整数存储、与列内整数直接可比较；`strftime('%Y', '2026-07')` 对 `'YYYY-MM'` 形态返回 **null**（需完整日期），HAVING 年过滤必须用 `substr(label,1,4)`。
- **excludeFromStats 双口径**：余额/净值路径**包含**被排除交易（D5），收支统计路径**排除**——P2 的批量 SQL 用不同子查询分别实现两口径，回归测试逐项断言与单账户路径一致。
- 测试基建：`test/repositories/sql_aggregation_regression_test.dart` 新增 8 条用例，覆盖 transfer/nativeAmount 折算/excludeFromStats/共享账本排除/周期标签月跨月边界/批量↔单条路径一致性。

### 验证结论（第二轮）

- `flutter analyze`：0 error；相对 HEAD **净减 1 条**（658→657），零新增 warning/info。
- `flutter test`：**1042 全部通过**（HEAD 基线 1034 + 新增 8 条聚合回归）。
- 既有口径回归锁（multi_currency_statistics / statistics_exclude_flags / account_stats_exclude_flags / budget_exclude_flags）全部通过——SQL 改写未改变任何统计口径。
