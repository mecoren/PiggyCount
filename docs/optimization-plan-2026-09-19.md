# PiggyCount 优化落地记录（2026-09-19 轮 · 内存专项 B6-B10 + B11 存档 / 功能 F1-F2 / UI U1-U3）

方案正文（批准版 `azure-bay-mole`）只存在于会话里、不在仓库；**编号表与批次记录都在本文件**
（§十二 是编号表，§十三 是批次记录）。基线：v0.7.8 / Flutter 3.44.3。

- 上一轮编号：内存 M1-M9、批次 B1-B5（`optimization-plan-2026-09-14.md`）
- 本轮编号：内存 **M10-M21**（批准版写的 "M10-M22" 里 M22 未启用；M2 保留给延后的首页窗口）、
  批次 **B6-B10**（B11 只交存档设计）、功能 **F1-F3**、UI **U1-U3**
- **行号会漂**：本轮之后的批次改过它引用过的文件，所以本文件的行号是**当时**的实测值。
  引用前先 grep 符号名（B11 一节开头有这条告诫，适用于全文）。

## 十二、本轮编号表（一眼版 · M10-M21 / B6-B11 / F1-F3 / U1-U3）

状态只有四种：**已收口**（代码 + 门禁 + §13 记录齐）/ **部分**（主项收了、明写的余量没收）/
**存档**（设计定稿、本轮不动代码）/ **未落地**（欠的是外部条件，不是活儿）。
每行只给一句话，理由与 file:line 全在指向的那一节里。

| 编号 | 一句话 | 状态 | 记录 |
|---|---|---|---|
| M10 | `_getImageInfo()` 的 `codec`/`image` 不释放（14.7MB/张） | 已收口 | B7 |
| M11 | 5 处 `toImage(pixelRatio:2/3)` 位图不释放（8-15MB/张） | 已收口（6/6 产生点） | B7 |
| M11 附 | 顺带加 `targetWidth: 256` 降采样 | **判为不做**：宽高进同步 payload，触线上格式 | B7 |
| M12 | `Image.asset` 12 个调用点裸解原图（4MB / 11.5MB 每张） | 已收口；PNG 本体重编码留 **TODO-M12b** | B8 |
| M20 | 图标全表在 `build()` 内重建（268 个 `_IconData`） | 已收口 | B8 |
| M21 | 列表 key 拼 ListView 下标，滚动即抖 | 已收口；真机滑动删除回归**未落地**（无设备） | B8 = U3 |
| M14 | 两处全表进 Dart 求余额/趋势 | 已收口（SQL 聚合下沉，新旧逐值相等） | B9 |
| M15 | 导入 `List<int>` 逐字节摊平（10MB 账单 → 80MB） | 已收口；`csv_parser` 四次全量复制、`xlsx` 整本常驻 = **同批跟进未做** | B9 |
| M16 | `List<int>` 当 provider family key（永不回收） | **部分**：两处 key 换 `join(',')`；`tag_providers` 批量 `autoDispose` 判为不做 | B9 |
| M17 | 日志 release 也入队 debug、每 2s 全量 `jsonEncode` | 已收口 | B9 |
| M19 | `_discoveredPayloads` 缓存解密后整本账本、无上限 | 已收口；`transactions_json.dart` 导出侧全量 = **同批未做** | B9 |
| M18 | SQLite 无显式 PRAGMA（WAL / cache / mmap） | 已收口 + 回读断言；`cache_size`/`mmap_size` 的取舍**未落地**（等 B6 数字） | B10 |
| M2 | 首页无 LIMIT 全账本三连 LEFT JOIN | 存档：M2-a/b 两步设计定稿 | B11 |
| M13 | 归档 Tar+Gzip 全内存（500 张 ≈ 450MB 峰值） | 存档：`archive` 磁盘到磁盘路径已核到源码行 | B11 |
| M22 | —— | **编号未启用**：批准版写 "M10-M22" 是上界占位，实际收口到 M21 | 本节 |
| B6 | 内存基线脚本 + 应用侧 30s 心跳 | 脚本与心跳已收口；**表内 RSS 数字全部未落地**（无设备） | B6 |
| F1-a | 软删除 / 回收站（v44 `deleted_transactions`） | 已收口（迁移测试 + 页面级回归） | F1-a |
| F1-b | 退款关联 `refund_of_id` + 报销状态 | **本轮不做**：前置是 CT-1 变更日志可靠性 | F1-a 末 |
| F2 | 任意区间 + 环比/同比 + 标签维度报表 | 已收口（12 例：9 数据层 + 3 页面级） | F2 |
| F3 | 预算结转 / 超支推送 / 规则引擎 / 模板 / Excel 导出 | 未开始：Q1 多选未选，README 的"超支提醒"宣称已删除 | D 批、F2 末 |
| U1 | 硬编码字号收敛到令牌 | **交的是 ratchet 门禁**（340/209 钉死），收敛本身未落地 | U1/U2 |
| U2-a | 图表进语义树（柱状 + 折线 + `hideAmounts` 隐私口径） | 已收口（3 例） | U1/U2 |
| U2-b | 文字对比度 ≥4.5:1 | 测了没改：亮色 `textTertiary` 2.18/2.41 不合格 | U1/U2 |
| U2-c | 读屏实测 / 热区 ≥48×48 / 大字号不破 | 未落地：三者都要真机 | U1/U2 |
| U3 | = M21 | 已收口 | B8 |

## 十三、批次记录（file:line 证据 + 验收状态）

### D 批 · 文档一致性（2026-09-19，已收口）

对外承诺与代码对齐，全部改文档、不改代码：

| 位置 | 原表述 | 改后 | 依据 |
|---|---|---|---|
| `README.md:48` / `README_EN.md:48` | "OCR 双引擎（本地 TFLite + GLM）" | "拍照 / 截图识别记账 — 由 AI 视觉模型（`glm-4v-flash`）完成，需智谱 API Key（v3.2.1 起已移除本地 OCR）" | `pubspec.yaml`/`pubspec.lock` 无任何 tflite 依赖；`lib/ai/providers/ai_provider_manager.dart:388` 注释自证；`lib/ai/engine/ai_extraction_engine.dart:124` 走 `glm-4v-flash` |
| `README.md:33` / `:90-91` / `README_EN.md:33` / `:84-85` | "OCR 本地识别 / 无需配置" | 功能启用条件表合并为"AI 小助手 / 语音记账 / 拍照与截图识别 → 智谱 GLM API Key"一行 | 同上 |
| `README.md:67` / `README_EN.md:60` | 预算条目含"超支提醒" | 删除；能力登记为 F3（本轮不做，Q1 已排除） | `lib/` 内 budget × notification 零命中 |
| `PRIVACY.md:93` | "Authentication credentials are stored securely using Android Keystore" | 拆成两条事实：同步密钥走 `flutter_secure_storage`（Android Keystore / iOS Keychain）；锁屏 PIN 只存 Argon2id 哈希 + 随机盐 | `lib/data/encryption/secure_key_storage.dart:27-31`、`lib/services/system/app_lock_service.dart:40-54` |
| `PRIVACY.md:111` / `:218` | "fully open source under the MIT License" / "完全开源（MIT许可）" | 明确"代码公开可审计，但**不是 MIT**，条款见 LICENSE（非商业免费，商业需付费授权）" | `LICENSE` 首段与"非商业/商业使用"章节；README 徽章本就写 BSL |
| `docoments/16-known-issues.md` 5.1.1 | "缺 (ledger_id, happened_at) 复合索引" | 标注**已过期**：索引存在于 `lib/data/db.dart:1324`（`onUpgrade` 的 v32 补建）与 `:1560`（`onCreate`） | 实读 |
| `docoments/16-known-issues.md` 3.1.1 | "Keystore 声明不符 + PIN 明文" | 标注**部分失效**：密钥侧已兑现、PIN 已 Argon2id 加盐；**仍成立**的是 PIN 哈希与锁定标志位在 SharedPreferences（`app_lock_service.dart:49,62`） | 实读 |
| `prd/README.md:35,48` | rec 9 / rec 14a 仍标待办 | 更新为已落地并补 commit（`c8c6e9c`+`ad807bc`；`63a02e9`） | `git log` |
| `docs/optimization-plan-2026-09-14.md:216` | "工具链锁 3.27.3 有因（pubspec.yaml:48-52 注释），不动" | 追加复核条目：SDK 已是 **3.44.3**（`pubspec.yaml:14`，版本单一来源注释在 `:8-13`），"不动"结论成立但依据已变 | 实读 pubspec |

**未改动并说明理由**：`README.md:12,26,30,168` / `README_EN.md:26,30,146,238` 的"开源 / open-source"用词。
理由：README 的许可证章节（`README.md:297` 起）已如实列出"个人使用免费 / 商业需授权"，徽章也是 BSL，
读者的信息链是完整的；把 6 处口语化的"开源"逐字改成"source-available"是纯 churn，且属对外口径变更，
需要产品决定。若日后要改，`PRIVACY.md` 已经改对了，README 跟着同一措辞走即可。

**验收**：`flutter analyze` / `flutter test` 不涉及（纯文档），改动全部为 `.md`。

### B6 · 内存基线设施（2026-09-19，脚本与心跳已落地 / **数字未测**）

方案的顺序是"B6 必须最先做，它是其余批次的前置"。实际执行顺序反了过来（B7-B10 先做），
理由写清楚：**本轮工作区没有任何 Android 真机/模拟器**，基线跑不出数字，而 B7-B10 的每一项都是
"两行代码级"的确定收口，等基线等于全部不做。所以 B6 交的是**可执行流程 + 自检过的脚本 +
空表**，欠的仍然是数字 —— 按方案 §七 第 2 条，B7-B10 在数字回填前**判"收益未证"**。

- `scripts/seed_mem_baseline.py`：三档语料（S 500 笔/2 附件、M 1 万/200、L 10 万/800），
  类型权重与金额区间**直接 import `scripts/inject_transactions.py`**，与既有语料同源。
  只写 `transactions` / `transaction_attachments`，不新建账本/账户/分类（新实体是"本地独有"，
  同步时会翻 —— 与 CT-1 同一个坑）。目标账本默认取交易最多的那个。幂等（按现有条数补齐）。
  合成附件按应用自己的命名 `sha_<sha256>.jpg` + 真实 `local_sha256`，尺寸 1920×1920
  （`lib/services/attachment_service.dart:20-21`，解码 14.7MB/张 —— 附件的内存代价在解码后不在
  文件体积，所以近似纯色小图不影响这一路）；要真实体积用 `--from-photos`。
  收尾 `wal_checkpoint(TRUNCATE)`：B10 起应用跑 WAL，不检查点就只推主文件会丢数据。
  **本机真验过**：在 `seed_16384.sqlite` 副本上 `--tier M` → +5 000 笔 / 附件补到 200 行
  （该账本原有 1 行）、4.8s、`integrity_check=ok`、附件宽高与 sha 逐条对上、零孤儿行；
  **重跑一遍两条都"已够，跳过"且行数不变**（`.workbuddy/gates/b6_seed.txt`、`b6_seed_rerun.txt`）。
  第一版这里溢出过（补成 201 行：算了 `need` 却按 `count` 建槽位），是本机这趟实跑抓出来的。
- `scripts/profile_memory.py`：三路取数 —— `/proc/<pid>/status` 的 `VmRSS`/`VmHWM`（RSS 与峰值，
  **不用 `dumpsys` 的 TOTAL：列序随 Android 版本变，老版本最后一列是 "Rss Dirty" 不是 RSS**）、
  `dumpsys meminfo` 分区（Native Heap / Graphics / .so mmap —— 位图与纹理只在 native 侧，
  Dart 堆看不全）、VM Service `getVM` → 每 isolate `getMemoryUsage`（**Dart 堆**，与前一路相减
  才能把 M10/M11/M12 与 M19 的性质分开）。输出 samples.csv + summary.json + 往 `-rows.md`
  追加一行（列名与验收表一致）。滑动复用 `profile_frames.swipe_list`。
  `--self-check` 是不连设备的那部分门禁（解析、留空行为、斜率与判级）。
  **过程中改了一个设计**：斜率最初照方案写成最小二乘，构造 ±100KB 采样锯齿（GC 锯齿的真实形状）
  就报 **181.8 KB/min 假泄漏**，改成"三等分、两端 1/3 的 RSS 中位数差 / 中位时刻差"后锯齿归 0、
  线性上升段仍精确。判级阈值因此定在 >2000 KB/min=LEAK / 200~2000=观察 / 其余 PASS。
- **应用侧心跳**落在 `lib/app.dart`（不是方案写的 `main.dart`）：`_PiggyAppState` 已经是
  `WidgetsBindingObserver`（`:92` addObserver），再加一个 `main.dart` 侧 observer 是重复设施。
  `_startMemoryHeartbeat()` 每 30s 写 `[mem] rss=… max_rss=…` 进既有 `logger_service`，
  `didHaveMemoryPressure()` 覆写记 warning，`dispose` 里 cancel。代价明说：2000 条环形缓冲
  每 30s 占一格（16.7 小时填满）。release 下这些行不进 logcat（`logger_service.dart:572` 的
  `debugPrint` 受 `kDebugMode` 门控），读法是日志中心页导出。
- **方案里两个 API 前提是错的，按代码纠正**：① `dart:ui MemoryInfo` 在 3.44.3 **不存在**
  （sky_engine `lib/ui/` 全目录零命中；`maxRss` 只在 `dart:io` 的 `ProcessInfo`，另有 `currentRss`）
  → 心跳用 `ProcessInfo`。② `AppLifecycleListener` **没有**内存压力钩子，真出口是
  `WidgetsBindingObserver.didHaveMemoryPressure`（`binding.dart:402`，由 `:1376` 派发）。
- `docs/evidence/mem-baseline-2026-09-19.md`：五步流程（拉库 → 灌 → 推回 → 采 → 回填）、
  固定列名的验收表（**空**，最后一行是给 B7-B10 收益用的对照组）、
  以及"拿到设备后头三件事"（run-as 可达性 / profile 构建 / 测 L 档先退云账号）。

**验收**：`flutter analyze` → `No issues found!`（`.workbuddy/gates/b6_analyze.txt`）；
`flutter test` 全量 → `01:29 +1342 ~1: All tests passed!`（`.workbuddy/gates/b6_test.txt`，
与本批前同数 —— B6 按方案**不加测试文件**，脚本自检就是它的可执行检查）。
脚本侧：`profile_memory.py --self-check` 通过；`seed_mem_baseline.py` 在真实库副本上端到端跑通
（`.workbuddy/gates/b6_seed.txt`）。**表内数字全部为空，未实测。**

### B7 · 泄漏收口 M10 + M11（2026-09-19，已收口）

native 位图释放。全仓 `grep "toImage(\|instantiateImageCodec"` 命中 **6 个点**，本轮 6/6 全部释放：

| # | 位置 | 改动 |
|---|---|---|
| M10 | `lib/services/attachment_service.dart:436-453` `_getImageInfo()`（产生点 `:441`） | `codec`/`image` 提为可空局部变量，`finally` 里 `image?.dispose(); codec?.dispose();`。改前 `try` 内直接 return，**两个 native 句柄都不释放**（1920×1920×4B ≈ 14.7MB/张，每存一张附件触发一次，调用点 `:142`） |
| M11 | `lib/services/export/share_poster_service.dart:74`（释放在 `:78`） | `toByteData` 取完字节后 `image.dispose()` |
| M11 | `lib/services/export/share_poster_service.dart:254,714`（释放 `:258,718`） | 同上（`pixelRatio: 3.0` 海报位图，单张 8-15MB） |
| M11 | `lib/pages/report/annual_report_page.dart:598,1902`（释放 `:600,1904`） | 同上（`pixelRatio: 2.0`，两处同一模式，已在 `try/finally` 内） |

**方案里"顺带加 `targetWidth: 256` 降采样"这一条判为不做**：`attachments.width/height` 不只在本地显示，
它会被写进同步 payload（`lib/cloud/transactions_json.dart:251`、`sync_diff_service.dart:627`）和备份
元数据（`attachment_export_import_service.dart:205` → `data_import_service.dart:1525` 回写）。把"实测宽高"
换成"降采样后宽高"等于改一条跨端元数据语义，而 grep 未发现任何 UI 用它做布局（全部命中都是搬运）。
按"触碰线上格式一律独立立项"的规矩，跳过。收益侧影响有限：dispose 后这段的全尺寸解码已经是**瞬时**占用。

新增守卫 `test/services/native_image_dispose_contract_test.dart`（2 例）：
1. 全仓扫 `lib/`，每个位图产生点后 10 行内必须出现 `dispose()`（注释行不计）——已做**负向验证**：
   临时放一个 leaky 探针文件，测试红并精确报 `lib\_tmp_leak_probe.dart:4`，随后删除探针；
2. `_getImageInfo` 方法体必须同时含 `finally` + `codec?.dispose()` + `image?.dispose()`，防重构后静默退化。

**内存门禁状态**：本轮**无真机 RSS 前后对比**（`adb devices` 为空）。上表收益是**算式不是实测**
（14.7MB/张 × 每次保存、8-15MB × 每次生成海报）。B6 基线脚本落地后须回填
`docs/evidence/mem-baseline-<date>.md`，在此之前 B7 的量化收益视为未验证。

**验收**：`flutter analyze` → `No issues found!`（`.workbuddy/gates/b7_analyze.txt`，0 error / 0 warning）；
`flutter test` 全量 → `01:24 +1323 ~1: All tests passed!`（`.workbuddy/gates/b7_test.txt`；
基线 1321 + 本批新增 2，skip 数不变）。真机五链路冒烟未做（无设备）。

### B8 · 资产降采样 + 小件 M12 / M20 / M21（2026-09-19，已收口）

#### M12 资产解码宽度上限

先实测资产体积再决定改哪里（PNG 解码后 = 宽×高×4B）：

| 资产 | 尺寸 | 解码 |
|---|---|---|
| `assets/images/piggyassets_{dashboard,holdings}{,_en}.png` | 1179×2556 | **11.5MB/张** |
| `assets/logo2.png`、`assets/images/piggyassets_logo.png`、`assets/icon/icon_master.png` | 1024² | **4.0MB/张** |

方案原列 4 个使用点，实扫 `grep "Image.asset("` 全仓 **12 个调用点**，全部裸解原图，12/12 收口：

| 使用点 | 改法 | 方案内/外 |
|---|---|---|
| `lib/widgets/biz/piggy_icon.dart:15`（`icon_master.png` 1024²） | `cacheWidth: (size × dpr).round()` | **方案外**，扫出来的：`PiggyIcon` 有 10 个调用点，默认 `size: 256` 但多数用在 24-48pt 位置 |
| `lib/widgets/biz/product_promo_card.dart:464` 截图缩略位 | `LayoutBuilder` + `box.maxWidth × dpr` | 方案内 |
| `lib/widgets/biz/product_promo_card.dart:526` 全屏预览 | `屏幕宽 × dpr`（`ResizeImagePolicy.necessary`，原图更窄时不会放大） | 方案内 |
| `lib/widgets/biz/product_promo_card.dart:193` + `_ProductLogo`（`:906`） | `44 × dpr` / `size × dpr`（`piggyassets_logo.png` 4MB） | **方案外**，`logoAsset` 是同一个 1024² 原图 |
| 6 个海报 `logo2.png`：`year_summary_poster.dart:160`、`user_profile_poster.dart:176`、`month_summary_poster.dart:624`、`ledger_summary_poster.dart:565`、`app_promo_poster.dart:160`、`annual_report_poster.dart:301` | 统一 `cacheWidth: 256`（盒净宽 26-80pt × 海报 pixelRatio 3 → 上限 240） | **方案外**，上一轮 M1 只登记了 `Image.file`，海报里的 logo 全漏了 |
| `lib/pages/auth/splash_page.dart:42` | `cacheWidth: 320`（盒净宽 88pt，够到 dpr 3.5） | 方案内 |
| `lib/pages/report/annual_report_page.dart:537` `precacheImage` | 改成 `ResizeImage(AssetImage('assets/logo2.png'), width: 256)` —— **必须和海报侧的 `cacheWidth` 同值**，否则预热的是另一个缓存键，海报上 logo 会空出来 | 方案内（但方案没写这个键耦合，是落地时才必须处理的） |

**没做的一件事并说明理由**：把 `logo2.png` 等 PNG 本体降采样重编码（一次动作可永久修掉 7 个引用点 + 减包体）。
理由：本轮环境无 ImageMagick/Pillow 之外的可视化复核手段，重编码后看不清退化是否可接受；
且二进制资产变更需要产品确认。留 **TODO-M12b**：若 B6 基线显示启动峰值仍被 logo 主导，再做资产侧。

新增守卫 `test/widgets/asset_image_cache_width_contract_test.dart`（1 例）：全仓扫 `Image.asset(`，
调用点后 7 行内必须出现 `cacheWidth`（注释行不计）。已做**负向验证**：临时放一个裸 `Image.asset`
探针 → 测试红并精确报 `lib\_tmp_width_probe.dart:3`，随后删除探针（`.workbuddy/gates/b8_negative.txt`）。

#### M20 图标全表只构建一次

`lib/pages/category/category_edit_page.dart:1548-1555`：`_GroupedIconGrid.build()` 每次调
`_getIconGroups()` 重建 268 个 `_IconData` + 19 个分组（该面板在键盘/输入每次 rebuild 都走一遍）。
改法：`_getIconGroups()` 变薄成 `_groupsByKind.putIfAbsent(kind, _buildIconGroups)`，原方法体重命名
为 `_buildIconGroups()`（**位置不动**，diff 只有 6 行）。grep 确认消费侧只读（`map`/`length`/下标），
无原地排序，共享实例安全。

#### M21 Dismissible key 去掉 index

`lib/widgets/biz/transaction_list.dart:657` → `Key('tx-${it.t.id}')`。
改前核查（方案要求）：数据源 `widget.transactions` 单一流、无合并（`:128`），一条交易只落一个日期组
（`:366-385` 按 `happenedAt` 分组），`id` 是主键 → **不存在撞 key**；`16-known-issues.md` 5.1.4 的
"拼接 index"里那个 index 在平铺路径上直接是 **ListView 可见区下标**（旧 `:590`），滚动即变，
所以 key 一直在抖。顺手删掉只为这个 key 而存在的 `flatDayStart` 记账链
（元组槽位、`_buildDayCard` 形参、`_buildTransactionRow` 形参共 8 处），`:93` 的历史注释正好印证
key 原本就是 `'tx-${id}'`。

**验收**：`flutter analyze` → `No issues found!`（`.workbuddy/gates/b8_analyze.txt`）；
`flutter test` 全量 → `01:59 +1324 ~1: All tests passed!`（`.workbuddy/gates/b8_test.txt`，+1 为本批守卫）。
内存收益同样是**算式不是实测**（logo 4MB→0.26MB、截图 11.5MB→按盒宽，splash 首屏少一份 4MB 常驻），
待 B6 真机基线回填。列表 key 变更需真机回归滑动删除，本轮无设备，登记为未验。

### B9 · 聚合 / IO / 常驻对象 M14 / M15 / M17 / M19 / M16（2026-09-19，已收口）

#### M14 两处全表进 Dart 的聚合下推

`lib/data/repositories/local/local_account_repository.dart`：

- `:591-625 getAllAccountsTotalStats`：旧实现 `db.select(db.transactions)` 不带任何谓词地
  把**全库**交易拉进 Dart，再按 `type` 累加。改一条 `customSelect`：
  `SUM(CASE type …)` + `account_id IS NOT NULL AND exclude_from_stats = 0 AND type IN
  ('income','expense') AND account_id IN (SELECT id FROM accounts) AND $exclude`
  （`$exclude` 是同文件 `:246` 已有的 `_kExcludeJoinedSharedLedgerSql`，与 drift 侧
  `_sharedLedgerIds()` 等价）。
  **保留不动**：上面那段 `for (account in accounts) getAccountBalance(account.id)` 的 N+1
  —— 它是延迟问题不是内存问题（每账户一条聚合 SQL，返回的都是标量），且
  `getAccountBalance` 的口径牵动账户卡片，另案。
- `:805-853 getAccountDailyBalances`：行查询加 `happenedAt >= startDate`，`startDate`
  之前的全部历史不再进内存，改一条基线聚合（`main_delta` CASE + `transfer_in`，
  `happened_at < ?2`），起点 = `initialBalance + 基线`。

口径两条容易踩的反向差异，都写进了守卫的语料自证：趋势**不**排除
`excludeFromStats`（账户真实余额），总收支**排除**；transfer 不进总收支但在趋势里轧差；
自己 own 的共享账本不能误排；孤儿 `account_id`（账户行已删）两边都不计。

新增 `test/repositories/account_totals_trend_sql_regression_test.dart`（2 例）：把两个旧实现
**逐字移植**成参照，灌一份跨窗口前/内/后 × 各 type × 三种账本形态的语料，逐值对拍 +
自证期望值（收入 500+300+999+600、支出 120+80、首点 480、末点 480+300+600-80+55.5-200+70）。
首跑就抓到我自己算错的那条自证期望（漏了 own 共享账本的 600），说明这段断言不是摆设。

#### M15 导入文件读取：`List<int>` 累加 → 预分配 `Uint8List` + `readInto`

`lib/services/import/file_reader.dart:61-96`：旧实现分块 `raf.read()` 存进
`List<List<int>>`，最后 `all.addAll(c)` 拼成 `List<int>`。Dart 的 `List<int>` 每元素占
8B（Smi），10MB 账单 → ~80MB + 倍增冗余 + 分块本身；改完是**一块 10MB**，
`readInto` 直接写进目标偏移，中间副本归零。顺带 `:31` 把 `bytes` 定成 `Uint8List`，
xlsx 分支不再 `Uint8List.fromList(bytes)` 二次复制（那又是一整份）。

新增 `test/services/file_reader_memory_test.dart`（3 例）：1.5MB 非 ASCII CSV 逐字符还原
（`readInto` 允许短读，这条是真门禁）+ 进度单调到 1.0 + UTF-16LE/空文件/仅 bytes 三条支路
+ 源码契约（`readInto` 在、`.addAll(` 不得复现）。契约断言负向验证过：写它的时候因为自己的
注释里出现了 "addAll" 而红过一次（`.workbuddy/gates/b9_m15.txt`），改成 `.addAll(` 后才绿。
**CI 里测不了 RSS**，所以名字里的 memory 指的是"改写后仍正确 + 回退会被拦"，不是内存数字。

#### M17 日志常驻收口

`lib/services/system/logger_service.dart` 三处：

1. `:357 levelAccepted` + `:307` 入队门控 —— release 下 debug 级不入队。理由不是条数
   （队列 2000 条封顶，挡掉 debug 只是换成别的），是**条的体量**：106 个 debug 调用点里躺着
   `logger.debug(_tag, '完整 prompt:\n$prompt')` 这类几十 KB 的行，每条入队要过 4 趟正则脱敏
   （每趟一份副本）、每 2s 被 `jsonEncode` 落盘、再常驻在 prefs 的内存缓存里。
   抽成静态口是因为单测里 `kDebugMode` 恒为 true，直接在 `_addLog` 里判覆盖不到 release 分支。
2. `:86-108 toJson` 截断 `error`(1000) / `stackTrace`(2000) 并标注原长；`message` 不截
   （排障主体）。落盘串才是常驻大头，内存侧原对象不动。
3. `:255-282 logs` getter 返回 `List.unmodifiable` 的**缓存快照**，队列任何改动置空
   `_snapshot`（4 处置空点：入队、pending 暂存、加载 finally、clear/reset）。
   旧实现每次 build 现场复制 2000 条且列表身份每次都变。`exportAsText` 改走同一 getter，
   少一份复制。消费点核查过：`log_center_page.dart:55,265` 只做 `where`/`length`，
   无人改返回的列表（改成不可变后若有新调用方原地排序会直接抛，属于想要的响法）。

新增 `test/services/logger_release_level_gate_test.dart`（8 例，含"历史日志加载完快照要刷新"
与"快照不可变"）。既有 `logger_service_test.dart` 的 12 例（含 clear 竞态、脱敏）全绿，
说明快照缓存没吃掉 LOG-04 的时序语义。

#### M19 发现阶段 payload 缓存封顶

`lib/cloud/transactions_sync_manager.dart:3344-3374`：`_discoveredPayloads` 缓存的是
**解密后的整本账本明文 JSON**，只在每轮发现开头 clear、导入后 remove，没有体积上限 ——
云端有 5 个大账本而用户一个都没点导入时，就是 5 份明文常驻。改法：`_cacheDiscoveredPayload`
过 `payloadWorthCaching`（单本 8MB / 总量 16MB），超限**干脆不缓存**，导入自然走
`:3607` 的未命中分支重新下载（语义不变，只多一次下载）。
两个阈值是**估式不是实测**（无真机、无真实云端语料），留 **TODO-M19**：B6 基线跑通后按真实
payload 分布回填。预算判定抽成静态口是为了测边界 —— 单测里造 8MB 明文只为走一遍分支不划算。
新增 1 例（5 条边界断言）在 `test/cloud/transactions_sync_manager_test.dart` 的发现组里，并给既有
"老文件回退下载"用例补了一条 `discoveredPayloadCountForTest == 1`（防止"封顶"写成"永不缓存"）。

**同批未做**：`lib/cloud/transactions_json.dart:55-66` 的导出侧全量 + `sort` + 4 份 Map。
理由是它不是"漏收"而是**协议形状** —— 线上格式就是"整本账本一个 JSON"，明文串必须整体物化，
要省只能改容器格式（分片/流式），按既定约束属于独立立项，与 M13 同批做。Dart 侧
`txs.sort` 是原地排，不产生额外驻留。

#### M16 family key：两个都是死代码，删

`:498`/`:76` 的 `attachmentCountsProvider`、`batchTransactionTagsProvider` 以 `List<int>`
当 family key（引用相等 → 每个新列表一个新元素、永不回收）。grep 全仓：两个 provider
**零调用点** —— 真正在批量取数的是 repository 方法本身（`transaction_list.dart:201,224`、
`ui_state_providers.dart:279-280`、`export_page.dart:143`、`sync_diff_service.dart:116`）。
所以不是"换字符串 key"而是直接删掉（-18 行，炸弹连带拆除）。

新增 `test/providers/provider_family_key_contract_test.dart`（1 例）：全仓扫
`.family<…>, (List|Map|Set)<`。正则锚在"值类型收尾的 `>` 后紧跟逗号"上 —— 第一版没锚，
`calendar_providers.dart:32` 那个 `family<List<({…List<Tag> tags…})>, (ledgerId,date) record>`
被误报（record key 本来就有值相等语义），锚定后消失。负向验证：临时探针
`family<List<({int n, List<Tag> tags})>, Map<String,int>>` → 红并精确报
`lib\_tmp_family_probe.dart:4`（`.workbuddy/gates/b9_m16_probe.txt`），删探针后绿。

**同批未做并说明理由**：给 `tag_providers.dart` 的 14 个 provider 批量补 `autoDispose`。
方案原文就写了"只修炸弹，不全量改 autoDispose"；这些 provider 存的是标签行（几十到几百行），
体量不足以进本轮清单，而 autoDispose 会让每次进页重订阅一次 stream —— 没有实测支撑前
不值得用可感知的重复取数去换这点常驻。`database_providers`/`theme_providers` 的常驻
是正确语义（关 DB 句柄 / 主题闪白），方案已判定不做，本轮维持。

#### 附带修正

`docs`/注释里 M14 的两条口径注释与 `_kExcludeJoinedSharedLedgerSql` 的引用位置一并核对；
无 schema 变更，故本批不涉及迁移测试。

**验收**：`flutter analyze` → `No issues found!`（`.workbuddy/gates/b9_analyze.txt`）；
`flutter test` 全量 → `01:41 +1339 ~1: All tests passed!`（`.workbuddy/gates/b9_test.txt`；
基线 1324 + 本批新增 15：M14 2、M15 3、M17 8、M19 1、M16 1，另 5 条断言并入既有用例）。
B7/B8 同样欠着的**真机 RSS 前后对比**仍欠着（无设备），B6 落地前本批所有数字都是算式。

### B10 · SQLite PRAGMA 显式化 M18（2026-09-19，已收口）

#### 落点：`migration.beforeOpen`，不是 `_openConnection`

`lib/data/db.dart:530-553`。库里原先对 `journal_mode` / `synchronous` / `cache_size` /
`mmap_size` / `journal_size_limit` 全部无声明，全吃 sqlite3 编译期默认。

**为什么只能是 beforeOpen**：生产连接是 `_openConnection` 里 `NativeDatabase.createInBackground(file)`
（`:1710`）起的**第二个 isolate**，而 PRAGMA 是 per-connection 的。三条备选都核过：
`NativeDatabase(file, setup:)` 与 `createInBackground` 互斥；改 `DatabaseConnection.custom` +
手动 `Isolate.spawn` 会绕开 `lib/data/database_health_service.dart:157` 的 `PRAGMA quick_check` 通路；
挂在 `onCreate`/`onUpgrade` 只在首次建库/升级那一趟生效，日常启动不跑。
`beforeOpen` 每次 open 都跑 —— 实测即证（drift 2.34.3 的 `QueryExecutor` 里
`beforeOpen(detail)` 紧跟 `migrate()` 之后，`:254-256`），所以**每条连接**都带 PRAGMA、
且 PRAGMA 跑在迁移之后（迁移用的事务已提交，不影响迁移语义）。

#### 设了什么 / 故意不设什么

| PRAGMA | 值 | 理由 |
|---|---|---|
| `journal_mode` | `WAL` | 写放大从"改一页复制一页回滚日志"降成追加 `-wal`；读不再被写挡。**负向对照顺手证实：改前 `journal_mode` 回读是 `delete` —— 生产一直在跑回滚日志模式** |
| `journal_size_limit` | `walRetainBytes` = 8MB（`:532` 常量） | 检查点后 `-wal` 的保留上限。这是**磁盘**不是内存：不设时一次批量导入把 `-wal` 顶到几十 MB 就不回落 |
| `synchronous` | **不动，保持默认 FULL** | WAL+FULL 仍每提交 fsync，掉电不丢最后几笔。换 NORMAL 是拿账本数据换写入速度，记账 app 不该做这个交易 |
| `cache_size` / `mmap_size` | **故意不设** | 拿内存换读盘（RSS 可能 +8~24MB），与本轮降内存目标反向。方案给这项定的门禁本就是"B6 真机基线之后再判"，基线还没跑（无设备）→ 留 **TODO-M18** |

附带：`:1699-1704` 那段"检测到 `-wal`/`-shm` 就 `logger.warning`"降为 `info`。WAL 现在是显式
设定，旁路文件属正常残留，恒告警等于没有告警；真正的锁问题归 `quick_check` 那条路。

#### 换 WAL 前的前置核查（这是会丢数据的那类改动，先确认再动手）

- 全仓只有 `database_health_service.dart:54` 引用库文件名，其 `_sidecarSuffixes`（`:57`）
  已经把 `-wal`/`-shm` 算进健康探测与备份清单；`grep` 确认**没有任何代码单独复制主 `.db` 文件**
  —— 只拷主文件会丢掉尚未检查点的 `-wal` 内容，那才是 WAL 真正的坑，这里不存在这条路。
- 库文件在应用私有目录，非网络/外部存储，POSIX 文件锁可用（WAL 的多进程前提）。

#### 门禁与它的负向对照

新增 `test/data/db_pragma_regression_test.dart`（3 例）：文件库回读 `journal_mode == 'wal'` +
`journal_size_limit == PiggyDatabase.walRetainBytes` + `synchronous >= 2`（默认值随编译选项在
FULL/EXTRA 间变，硬编码 2 会因平台差异恒红）+ 写入后主库旁**物理存在 `-wal`**；
重新打开（新连接）仍读到非 0 的 `journal_size_limit`（该值不落盘，只有被重设才读得到 → 这条
才是"beforeOpen 真的每次都跑"的证据）；`NativeDatabase.memory()` 一路**不受影响**
（`:memory:` 不支持 WAL，回读 `memory`，只断"不许抛" —— test/ 下几百例共用这个基座）。

负向对照：临时在 `beforeOpen` 开头插 `return;` → 两个文件库用例同时红，
`Expected: 'wal' / Actual: 'delete'`（`.workbuddy/gates/b10_m18_negative.txt`），删探针后绿。
探针不残留（`grep PROBE-M18` 空）。

**验收**：`flutter analyze` → `No issues found!`（`.workbuddy/gates/b10_analyze.txt`）；
`flutter test` 全量 → `01:38 +1342 ~1: All tests passed!`（`.workbuddy/gates/b10_test.txt`，
基线 1339 + 本批 3）。要说清覆盖面：test/ 下 **87 个文件用 `NativeDatabase.memory()`**，
那条路上 WAL 根本进不去（回读 `memory`），所以"套件全绿"并不等于"WAL 下全绿"；
真正走文件库的是 3 个文件 —— 本批新增的 1 个 + `migration_v41_local_changes_purge_test.dart`
+ `migration_v43_sync_metrics_test.dart`，即 **onCreate 与 onUpgrade 两条路在 WAL 连接上都是绿的**，
这正是 beforeOpen 排在 `migrate()` 之后需要证明的事。
本批唯一的内存收益是**写侧峰值**（回滚日志整页复制 → 追加），仍是**算式不是实测**，
与 B7/B8/B9 一起挂在 B6 真机基线欠账下。

### B11 · 存档设计：M13 归档流式 / M2 首页窗口（2026-09-19，**本轮不动代码**）

两个大件判给下轮，理由不是"难"，是它们**分别撞上本轮立的两条规矩**：
M13 要改备份/导出产物的生成路径（产物字节一变就是跨端语义），M2 要改查询形状（五处调用方依赖旧形状）。
Q3 的选择也是"基线先行，下轮做大件"。所以这里交的是**可以直接照着写代码的设计**，
外加本轮新核实的依赖包证据 —— 下轮不必重新调研。

> **行号口径**：批准版（`azure-bay-mole`）里的行号取自 F1-a/F2 之前，那两批改过这些文件，
> 数字已漂。本节一律给**符号名 + 实测行号**为准，引用批准版时先复核行号。

#### M13 归档 Tar+Gzip 全内存 → 磁盘到磁盘

现状（`lib/services/attachment_export_import_service.dart`，本轮实读）：
`:151` `file.readAsBytes()` 逐张进内存 → `:153` `archive.addFile(ArchiveFile(...))` →
`:164` `TarEncoder().encode(archive)` → `:165` `GZipEncoder().encode(tarData)` → `:178` `writeAsBytes(gzData)`。
峰值 ≈ 附件总量 ×3（原始 Archive + tar 字节 + gz 字节），500 张 × 300KB ≈ **450MB**。
同型问题在 `lib/cloud/backup/cloud_backup_service.dart`（`:135` 的 BKV-1 阈值注释与 `:251` 的止血告警
自认"全内存装配 ZIP、3 倍峰值"未修）。
读取侧：为取一个 `metadata.json` 也整包解压 —— `:269/272`、`:622/623`、`:688/689` 三处
都是 `GZipDecoder().decodeBytes(全部字节)` → `TarDecoder().decodeBytes(tar)`，两处全量在返回值上。
**这是算式不是实测**，`--from-photos` 的真实附件尺寸会显著抬高它。

**零新依赖的可行路径**（`archive` 3.6.1，包路径 pub cache `hosted/pub.flutter-io.cn/archive-3.6.1`，本轮逐行核过）：

| 证据 | 内容 |
|---|---|
| `lib/src/io/tar_file_encoder.dart:19` | `Future<void> tarDirectory(...)` 存在，签名带 `compression` 与目录参数 |
| `:36` | 包内注释原文 `// Encode a directory from disk to disk, no memory` |
| `:42`、`:44` | `InputFileStream(tarPath)` → `GZipEncoder().encode(input, output: output, level: level)` —— 输出是**磁盘 sink**，不是返回字节 |
| `:85` | 逐个文件走 `InputFileStream(file.path)`，分块懒读，不会把整目录收进内存 |
| `lib/src/gzip_encoder.dart:31` | `List<int>? encode(dynamic data, {int? level, dynamic output})` —— `output` 参数就是流式出口 |
| `lib/src/io/zip_file_encoder.dart:111`、`:230` | `open(String zipPath)` / `closeSync()`：云备份侧改 `ZipFileEncoder` 的 open → `addFile(File)` → close 三段 |

读侧：`TarDecoder.decodeBuffer(input, storeData: false)`（包内 `lib/src/tar_decoder.dart:20-21`，
`:36` 把它透传给 `TarFile.read`）只解头不存数据；`metadata.json` 排在 `avatar/`（`:93`）
与 `custom_icons/`（`:123`）之后、images（`:153`）之前 —— header-only scan 只需跳过前两个小条目，
不必碰附件。

**出口测试（下轮必须一起交）**：归档往返（导出 → 导入 → 逐附件 `local_sha256` 比对）+
产物须**同时**被 `TarDecoder` 与系统 `tar tzf` 读取（只自证兼容等于没测）。
**约束**：产物文件名、BKV 版本标记、tar 内部路径顺序都不许变 —— 那是跨端格式，改动本身要独立立项。

#### M2 首页全量三连 JOIN → keyset 窗口

现状：`local_transaction_repository.dart:123-143` `watchTransactionsWithCategoryAll`
（`tx + category + from/to account` 三连 LEFT JOIN，见 `:114-121` `_txJoins()`）**无 LIMIT**，
经 `_watchTxJoinWithSharedHydration`（`:160`）常驻在首页。1 万条 ≈ 15-25MB 常驻（算式）。

**不能直接换 keyset**，五处依赖旧形状（本轮逐个 grep 确认仍在）：
① `lib/widgets/biz/transaction_day_grouper.dart` 靠 `_idDayKey`（`:28`）全集对比做删除检测
（`:72` 取 oldKey、`:92` 全表扫残留）—— 截断窗口会把"滚出窗口的日"误判为已删除；
② `transaction_list.dart` 的日合计从分组内算；③ 同文件的 `_dateIndexMap` 支撑 `jumpToMonth`
（入口在 `home_page.dart:208`）；④ `_watchTxJoinWithSharedHydration` 用 `lastRows` 持有上一次全量并每次复制；
⑤ `search_page` / `export_page` / `category_selector_dialog` 语义上确实要全量。

**本轮新发现（对下轮有用，省一步设计）**：`watchTransactionsInMonth`（`:85-102`）已经是**窗口化前例** ——
`periodForLabel` 算半开区间 + `happenedAt` 降序，但返回裸 `Transaction`（无 JOIN）。
M2-a 的形状就是"把 `_txJoins()` 接上去 + 把区间上界换成 keyset cursor `(happened_at, id) < cursor`"，
命中既有索引 `idx_transactions_ledger_happened`（`lib/data/db.dart:1324` onCreate、`:1560` 迁移路）。

**两步走**：M2-a 新增 `watchTransactionWindow({ledgerId, before, limit})`，日/月合计下沉 SQL 聚合
（副作用收口，照 `test/repositories/sql_aggregation_regression_test.dart` 的一致性范式），
grouper 增"只合并、不删检"的窗口追加路径，`jumpToMonth` 未命中时降级为按目标月反查 cursor；
M2-b 物化 `daily_totals(day_key, ledger_id, income, expense, cnt)` 后删掉 `home_page.dart` 的全量 fallback
（`:55`、`:632`、`:962` 三处 fallback 注释即其足迹）。

**外部教训照抄**（Firefly III）：派生 running-balance 在 2.3 万条上批量编辑超时（#11531）、
1.4 万条报表缺索引（#11620）→ 派生列必须**可关、可批量重算、有索引**。
**前置**：B6 的 M/L 档真机数字。M2 是本轮唯一"随账本增长"的那类问题（M10-M21 都已是常数级收口），
所以数字一到位它就排第一。

### F1-a · 回收站 / 软删除（2026-09-19，已收口）

#### 实现与设计选择：归档表，不是 `deleted_at` 列

方案原文写的是"`transactions` 增 `deleted_at`（nullable）+ 所有读路径补 `deleted_at IS NULL`"。
读路径清点后改判：**transactions 的读约 75 处、其中约 50 处是手写 SQL 字符串**
（`SUM(CASE type …)`、`date(happened_at,'unixepoch','localtime')` 这类，见
`lib/data/repositories/local/local_account_repository.dart:287-312`、
`local_statistics_repository.dart:210,253,330`），漏一条就是"已删的交易仍计入余额"——
静默的账目错误，且编译器完全管不住。改成**整行搬进 `deleted_transactions`**
（`lib/data/db.dart:335-357`，PK=原 `tx_id`，`payload` 存整行 JSON）后：
余额 / 统计 / 预算 / 附件 GC / 首页列表**自动正确**，因为它们读的是 `transactions`，
而那行真的不在了。correct-by-construction 换掉 50 处人工谓词收口。

代价（换来什么、丢什么）：
- 归档行不进快照（`transactions_json` 只导 `transactions`）→ **回收站只在本机**，
  不上云、不进备份。对端感知这笔删除走的仍是原本那条路（本地有/云端无的 diff 项，
  按 SYNC-05 默认不勾选），与今天的硬删除语义完全一致，没有变得更差。
- 恢复要能"原地复位"：`transaction_tags` / `transaction_attachments` /
  `transaction_tag_overrides` 三类辅助行**刻意不删**（`local_transaction_repository.dart:772-794`），
  所以恢复不需要重建它们，附件文件也不会被 30 天孤儿 GC 吃掉
  （`lib/main.dart:860,882` 的 GC 以 `transaction_attachments` 全表行判存活，不按账本 join）。
- 30 天 GC 与"清空账本"的交叉：`lib/pages/main/ledgers_page_new.dart:738,805` 收集待删文件
  用的是 `getAttachmentFileNamesByLedger`（INNER JOIN `transactions`）→ 归档条目的文件
  **不在**那份清单里，所以既不会被误删、也不会被即时回收；`purgeDeletedTransactions*`
  走自己的引用计数删文件。净效果：只在回收站里留着的文件由 30 天 GC 兜底，无泄漏。

#### 落地点

| 位置 | 内容 |
|---|---|
| `lib/data/db.dart:335-357` `:567` `:1540-1550` `:1576-1580` | 表定义 / `schemaVersion=44` / onUpgrade 分支 / onCreate 同构索引（新装库不跑 onUpgrade，索引必须两处都建——本仓既有约定） |
| `lib/data/repositories/transaction_repository.dart:339-358` | 5 个接口方法；`deleteTransaction` 明确留作"彻底删除"，同步/清库路径继续用它 |
| `local_transaction_repository.dart:772-866` | 软删 / 列表 / 恢复 / 就地删除 / 账本级批量清理；恢复遇原 id 被占用**拒绝**（换 id 落回去等于把标签附件丢原地） |
| `local_repository.dart:220` `:371` | 删账本、清空账本两条路都先 purge，且放在 `changeTracker == null` 提前 return **之前**（否则快照后端漏清） |
| `orphan_scanner.dart:100-129` `:134-` | A2/A3 加 `LEFT JOIN deleted_transactions` 豁免。不豁免 = 每次软删都在清理页报假孤儿，用户点清理就把恢复要用的附件行删了 |
| 4 个用户删除入口 | `transaction_list.dart:739` 滑动删、`category_detail_page.dart:528`、`tag_detail_page.dart:507`、`search_page.dart:517` 批量删 → 全部改 `softDeleteTransaction`；`sync_diff_service.dart:726`、`ai_chat_service.dart:73`（撤销识别写入，不是用户删除）**保持硬删** |
| `lib/pages/maintenance/recycle_bin_page.dart` | 新页面（列表 + 恢复 + 就地彻底删除），入口挂在 `data_management_page.dart` 数据清理之后 |
| l10n 4 个 ARB | 新增 10 键；**改写 4 条已存在的假文案**：`deleteConfirmMessage`、`searchBatchDeleteConfirmMessage`（"此操作无法撤销"）、`searchBatchDeleteReconfirmMessage`（"删除后这些记账无法找回"）、`searchBatchDeleteSuccess` —— 现在软删可恢复，留着旧文案就是骗用户 |

#### 方案里这条前提被证伪：CT-1 阻塞项

方案 F1 写"**前置依赖（必须先修）**：CT-1 ChangeTracker 未注入导致 `local_changes` 全空转……
变更日志不可靠时引入软删除，会让同步把删除'复活'"。核实结果：**不必修，且不成立**。
- `lib/providers/database_providers.dart:24` 起 ChangeTracker 已随云端协同下线**不再构造**，
  `local_changes` 只有 `orphan_seeder.dart:223`（debug 塞数据）会写；
- 唯一读者 `transactions_sync_manager.dart:892-921` 的 `_localChangeEvidence` 在冷启动下
  给 `trusted:false` → `_detectUploadConflict` 返回 `'unknown'` → 结果是**多弹一次合并确认**
  （fail-safe），不是静默覆盖；会话内的编辑由 `markLocalChanged` 的 `_recentLocalChangeAt` 覆盖。
- 更直接：归档表设计**根本不写 tombstone**，被引用的那条复活路径不存在。

#### 明确没做（以及什么时候该做）

- **删除时的 Snackbar Undo**：方案要求"软删 + Snackbar Undo"。实测本 app 的通知原语
  `lib/widgets/ui/toast.dart:26` 是挂在 rootOverlay 上的 `IgnorePointer` 覆盖层，**没有 action 位**；
  全仓 `SnackBarAction` 0 处。给 4 个删除入口中的 1 个单独配撤销反而更不一致 →
  改为"4 个入口统一由回收站页面兜底 + 删除后 Toast 明示'已移入回收站'"。
  add when：真要原地撤销，得先给 Toast 加 action 或换 SnackBar，那是全局组件改造。
- **一键清空回收站 / 30 天 TTL 自动清理**：都不做。回收站占的只是被删交易的元数据行
  （每行约 1KB JSON），没有容量压力；自动删除用户数据是比不删更糟的默认。
  add when：用户报"回收站里条目多到翻不动"再加批量操作。
- **F1-b 退款/冲正关联 + 报销状态**：**本轮不做**，见下条。

#### F1-b 退款 / 报销 → 移交下一轮（原因与接手清单）

方案给 F1-b 的定义是 `transactions` 增 `refund_of_id`（自引用）+ `reimburse_status`。
这两列**必须进快照**才能在多设备下存活：改动面是
`lib/cloud/transactions_json.dart` 导出/导入 + `lib/cloud/sync_fingerprint.dart` 的
`contentFingerprintFromMap` **字段白名单**（不加进去=该字段对端不可见、下次全量 pull 静默丢）
+ `sync_diff_service.dart` 比较逻辑，并且**首次上线必然触发一轮 outOfSync 升级**
（白名单加字段的既有先例：M2 / TSM-P3）。按本轮定的硬约束——
"不新增依赖、不改协议/容器格式来解决内存问题；触碰线上格式一律判为独立立项"——
它不属于可以顺手夹带的批次。另外两点核实：
- 现状里 `type == 'adjustment'` 是**账户余额调整**（`local_account_repository.dart:292` 计入余额），
  不是"冲正某笔交易"，没有链接字段，不能当 F1-b 已实现；
- 退款目前只有文案（`categoryIncomeRefund` 分类名、`tagDefaultRefundable` 标签），无实体建模。
  预算回补口径（退款应回补预算，Firefly #7697）在动列之前必须先在
  `prd/transaction_model_completion/design.md` 写死并配一致性测试。
"统计口径复用既有 `excludeFromStats`"这条仍然成立（`local_account_repository.dart:476,565,572,578`
的余额 SQL 已在用它），是 F1-b 唯一不需要新协议的部分。

#### 门禁

- `flutter analyze` → `No issues found!`（`.workbuddy/gates/b12_analyze3.txt`）。
- `flutter test` 全量 → `02:43 +1353 ~1: All tests passed!`（`.workbuddy/gates/b12_test_full.txt`，
  B10 后基线 1342 + 本批 11）。
- 新增 `test/data/migration_v44_recycle_bin_test.dart`（2 例）：onCreate / onUpgrade 两条建表路
  径都有表 + `idx_deleted_transactions_ledger`；第一条同时是**建表幂等**的证（先把库压回 v43
  再开，表已存在还要能跑完 v44 分支）。
- 新增 `test/data/recycle_bin_round_trip_test.dart`（9 例）钉四条命门：软删后
  `getTransactionsByLedger` / `transactionsWithCategoryAll` / `totalsInRange` 全部看不到这笔钱；
  标签行 + 附件行 + 磁盘文件原地保留；恢复后**整行逐字段相等**
  （`restored.copyWith(updatedAt: 原值) == original`，drift 生成的 `==`）——
  `updated_at` 例外是想要的：`trg_transactions_touch_updated_at` 在 INSERT 时重盖，
  恢复后这笔本该重新推给对端；id 被占用时拒绝且不误删占用者；purge 连物理文件一起走；
  删账本/清空账本连带清回收站且不越界动别的账本；孤儿扫描不报假孤儿。
  附件物理文件断言需要 fake path provider（沿用 `attachment_sync_test.dart:633` 的
  `_FakePathProvider`，另补 `getTemporaryPath`——缩略图目录走的是 temp dir，
  少了这个 `_deleteAttachmentsForTransaction` 会在 try 里抛、静默跳过删行）。
  **顺带证伪一个担心**：软删时辅助行还在，若 SQLite 外键被打开就会 `FOREIGN KEY constraint failed`；
  全仓 `grep foreign_keys` 零命中、测试绿 → 本库连接未开 FK，搬行安全。

#### 事故记录：`dart format lib test` 全仓重排（已回滚，留此告诫）

批次收尾时跑了一次 `dart format lib test`，**357 个文件被重排**（+10151/-6556）。根因：
本仓 HEAD 不是 `dart format` 产物（手排版、约 100 列，`dart format` 按 80 列重排），
`pubspec.yaml:7` 的 `sdk: ^3.6.0` 只挡住 tall-style，挡不住行宽。
回滚判据（`.workbuddy/fmt_revert_scan.sh`）：把 HEAD 版单独格式化一遍，
**若与当前内容逐字节相同 → 该文件 100% 是格式化噪音、不含任何手工编辑** → 还原 HEAD。
356 个变更 dart 文件里 321 个属此类，已还原。剩下 35 个真改过的再用
`.workbuddy/deformat.sh`：把"编辑 diff"重新贴回 HEAD 版，**验收是"贴回去再格式化一遍
必须与现状逐字节相同"**，对不上一律保留现状——27 个还原成功、8 个保留（宁留噪音不改坏代码）。
最终 35 文件 +2274/-772（其中含 F1 全部真实改动）。
告诫后续会话：**这个仓库不要全仓 `dart format`**，新文件按就近风格写就行。

### F2 · 自定义区间报表（任意起止 + 环比/同比 + 标签维度）（2026-09-19，已收口）

#### 两处与方案字面不同，先记账

1. **区间选择器没走 `table_calendar`**。方案原文"复用已有 `table_calendar` 依赖与
   `calendar_page.dart` 交互"。实际用 Material 自带的 `showDateRangePicker`
   （`range_report_page.dart:149-166`）：它一次就返回**一个连续区间**（`table_calendar`
   的 range 模式要自己管 `_selectedStart`/`_selectedEnd`/中间态），中文/韩文月份由已挂上的
   `GlobalMaterialLocalizations.delegate`（`lib/main.dart:761`）出，**零新依赖、零新组件**。
   选择器给的是"含末日"，入口统一 `+1d` 转成半开区间（`:164`），与全仓取数口径一致。
2. **报表是新页面，不是洞察页的第 5 个视角**。方案的措辞是在 `analytics_page` 上加列。
   那页 1.5k 行、视角固定周/月/年/全部、数据靠 `List<dynamic>` **位次**传递、摘要卡只有
   **一个** `prevTotal` 槽、左右滑手势=切周期、还挂着分享海报分支。在它上面同时挂
   环比+同比两列再叠标签维度，改动面会铺满 4 个视角的取数与手势语义 —— 回归面远大于
   新页。**口径同源**靠两件共享物保证：同一批 repo 方法，以及把分类聚合从页面里抽出来的
   `lib/utils/analytics_category_rollup.dart`（`aggregateTopLevelCategories`，原
   `analytics_page.dart:1555-1747` 原样搬出，两页现在**必须**算出同一个数）。

#### 落地点

| 位置 | 内容 |
|---|---|
| `lib/data/repositories/statistics_repository.dart:49-59` | 接口 `totalsByTag(ledgerId, type, start, end)`。口径写进注释：`COALESCE(native_amount, amount)` + `exclude_from_stats = 0` + 半开区间，**可与 `totalsByCategory` 直接对账** |
| `local_statistics_repository.dart:320-402` | 实现：两条 `customSelect` 在 Dart 侧按 tag id 合并。① 主表路 `transaction_tags → tags`；② 共享账本 Editor 路 `transaction_tag_overrides → shared_ledger_tags`，按 `syncId` 转 synthetic **负 id**（与 `LocalTagRepository` 同源），否则协作者看到的标签构成会少一半。索引 `idx_transaction_tags_transaction/tag` 已存在，未建新索引 |
| `local_repository.dart:2527-2540` | 聚合层转发（`BaseRepository` 组合 `StatisticsRepository`，不转发则页面拿不到） |
| `lib/pages/report/range_report_page.dart` | 新页 654 行。取数**一次 `Future.wait` 八条 SQL**（`:91-103`）：本期/环比/同比 `totalsInRange` × 3、`totalsByDay`、`totalsByCategoryWithHierarchy`、共享合成分类、`totalsByTag`、`countByTypeInRange` —— 全部聚合，零整行拉取 |
| 同文件 `:35-64` | 四个 `static`：`dayChartLimit=31`、`momWindow`（紧邻本期之前、等长）、`yoyWindow`（整窗回退一年）、`changeRate`（上期 0 → null，渲染成「—」而不是 +∞%）、`rollToMonths`。做成 static 是为了纯函数可测，页面无需被 pump 就能钉住窗口算术 |
| 同文件 `:355-464` | 对比表：行=支出/收入/结余，列=本期/环比/同比；环比与同比格**上下两行**（变化率 + 对比窗绝对额）。涨跌配色按**行语义**走（`goodWhenUp`：支出涨=坏、收入涨=好），颜色仍取用户的红绿方案，不硬编码 |
| 同文件 `:516-610` | 标签构成：色点 + 笔数 + 占比条 + 金额。占比按"标签行之和"算（标签不互斥，各行之和通常**大于**区间总额，与标签详情页口径一致）；`#RRGGBB`/`#AARRGGBB` 都能解析，无颜色时按序列色板兜底 |
| 同文件 `:139-147` | 单槽记忆化 `_futureFor(ledgerId, refreshTick)`，key = `ledgerId\|start\|end\|dim\|tick`（与洞察页 `_rememberAnalyticsFuture` 同口径）：切维度只重发查询，`setState` 复用已发 Future |
| 同文件 `:168-175` | 柱状图左右滑 = 整窗按**自身长度**平移（洞察页"左右滑=切周期"的同手感，换了可变区间就得以窗口长度为步长） |
| 入口 × 2 | `analytics_page.dart:520-534`（洞察页头部 `date_range` 按钮，带 `Tooltip`）+ `mine_page.dart:417-429`（「我的」页年度账单之后）。**两个入口都不是新容器**，复用现成 `IconButton`/`SettingsNavItem` |
| `analytics_page.dart:1510-1527` `:832` | 方案 §四 明确点名的旧账：`_calculateBalanceSeries` 原在 **build 期**调用（原 `:865`），挪到加载侧、结果占返回位次 7。结余序列是纯函数、两份序列各最长 6 桶×31 天，放 build 里等于每次 setState 重排一遍 |
| l10n 4 个 ARB | 新增 8 键（`rangeReportTitle` / `…EntrySubtitle` / `…ColumnCurrent` / `…ColumnMom` / `…ColumnYoy` / `analyticsTagComposition(type)` / `…ChangeRange` / `…EmptySubtext`），en 起于 `app_en.arb:3843`。逐字节保留 BOM/CRLF 差异，脚本 `.workbuddy/add_l10n_f2.py` |

#### 明确没做（以及什么时候该做）

- **保存的报表 / 自定义报表**（Actual 的 custom reports）：要新表 + 迁移 + 一套管理 UI，
  而现在连"用户存第二个区间"的证据都没有。add when：真有人反复回到同一组区间。
- **现金流 / 净资产曲线 / 交叉点**：洞察页已有净资产视角，新页只做"区间内的量"。属 F3。
- **环比/同比列开关**：三列一屏放得下，加开关是用 UI 复杂度换"少看一眼"。
- **点柱下钻到当日明细**：洞察页有同类交互，新页未接。add when：有人反馈"看到某天高想知道那天买了什么"。
- **标签维度不做多标签交叉筛选**（"A 且 B"）：`transaction_tags` 上自 join 是另一套查询形状，
  先要单标签的构成。
- **Excel/PDF 导出**：F3 已登记。
- **内存硬门禁（§七.2）对本批判为"无对比项"**：F2 全是 SQL 聚合、零整行载入，
  新增常驻只有一个 `Future.wait` 的 8 个结果对象（最坏 6 桶×31 天的日序列）。
  没有真机 RSS 基线可前后对比（B6 的 `profile_memory.py` 至今无设备数据），
  所以**不声称任何内存收益数字** —— 这是算式不是实测。设备到位后按 §七.2 补行。

#### 门禁

- `flutter analyze` → `No issues found!`（`.workbuddy/gates/b13_f2_analyze4.txt`）。
- `flutter test` 全量 → `02:09 +1365 ~1: All tests passed!`（`.workbuddy/gates/b13_f2_testfull2.txt`，
  F1-a 后基线 1353 + 本批 12）。
- 新增 `test/data/report_range_aggregation_test.dart`（9 例）：`totalsByTag` 与单标签
  `getTagStats` **逐值相等**（两条实现必须对账）；口径四合一（排除不计入统计 / 半开区间
  首秒末秒 / 按类型过滤 / `native_amount` 优先 → 730 与 3 笔）；一笔多标签分别计入；
  共享账本 override 合并且 id 为负；**软删的交易不进报表**（与 v44 交叉，等于替 F1-a 补一条读侧证）；
  `momWindow` 紧邻等长、`yoyWindow` 闰日进位（2024-02-29 → 2023-03-01，多算一天胜过抛异常）、
  `changeRate` 四种边界、`rollToMonths` 并桶升序。
- 新增 `test/pages/report/range_report_page_test.dart`（3 例，页面级）：三个对比窗各查各的
  区间不串行（+200.0% / +500.0% 只能由 本期300/环比100/同比50 这组数推出）；标签块 200/1笔
  与分类块 300/2笔 **不同源**（串行就露）；切收入维度换掉序列/分类/标签三块但**不动**对比表；
  区间内无记账走 `AppEmpty` 而不是画一屏零柱。
  两个踩点值得留给后续页面测试：**①** 页面是 `ListView`，默认 800×600 测试视口装不下后三张卡，
  未构建的 sliver 里 `find.text` 必然找不到 → `tester.view.physicalSize` 拉高（`:80-84`），
  比在测试里穿插滚动更稳；**②** `AmountText` 带 `showCurrency` 的那格文本含币种符号，
  断言得用 `textContaining`。

### U1/U2 · 字号令牌收敛 + 无障碍基线（2026-09-19，**U2 图表这一层已落地 / U1 交付的是门禁不是收敛**）

方案 §五 把 U1 写成"338 处硬编码 fontSize 收敛到令牌，按页分批，每批带视觉 diff 截图"。
实测后 U1 的**扫描部分判为不做**（理由全在下面，含数字），改交付一条 ratchet 门禁；
U2 按方案落地"图表"这一层，"金额"这一层判为**不需要补**。

#### U1 · 为什么不盲扫（先测量，再决定，这是本轮实测的分布）

扫描口径：`lib/pages` + `lib/widgets`，跳过注释行，只数 `fontSize:` 后面直接跟数字的**字面量**
（`fontSize: PiggyChartTokens.xLabelFontSize` 这类不算，它本来就已经在令牌上）。

| 目录 | 字面量 | `fontSize:` 总命中 | 涉及文件（任一口径） |
|---|---|---|---|
| `lib/pages` | **340** | 344 | 53 |
| `lib/widgets` | **209** | 247 | 48 |

合计 549 处，直方图（就是那份"收敛顺序表"，本轮不执行）：
`16×125 14×97 12×91 13×64 18×42 20×27 11×15 15×14 24×14 10×13 28×9 22×9 32×9 17×9 9×5 48×2 42×2 100×1 36×1`。

三条判"不做"的理由，**都不是"工作量大"**：

1. **高频的两个值没有对应令牌。** 16 是第一名（125 次）、13 是第四名（64 次），而
   `PiggyTextTokens`（`lib/styles/tokens.dart:800-856`）兜底分支里出现的字号只有
   11/12/14/15/18 —— 换成令牌不是重命名，是**先要设计 16 和 13 算什么档**（并到 15？并到 18？新开一档？）。
2. **令牌成员返回的是整只 `TextStyle`，不是字号。** `title/strongTitle/boldTitle/body/label`
   每个都自带 `color: PiggyTokens.textPrimary(ctx)` 和 `fontWeight`（`:802-856`）；
   另一条路 `PiggyTypography.buildBase`（`:871`）是 TextTheme 级替换，连带 `height`/`fontFamily` 副作用，
   且 16/13 在那里同样没有档位。所以"逐处替换"**每一处都可能同时改到颜色和字重** ——
   这是一次视觉变更，不是一次机械替换。
3. **本轮没有设备，出不了"每批带视觉 diff 截图"这个验收物。** 方案给 U1 定的出口就是截图对比；
   没有对比条件就把 549 处改掉，等于把视觉回归一次性引进来再靠用户报。

**因此本轮 U1 交付**：`test/styles/font_size_token_ratchet_test.dart`（1 例）——
把 340/209 钉成基线，**新增一处硬编码字号就红**，失败信息带"最多 8 个文件"+"字面量直方图"
（即下一轮该从哪个值、哪个文件开手的依据）。已做**负向验证**：临时放 `lib/pages/_u1_probe.dart`
（两处字面量），测试红且精确报 `lib/pages: 342 > 基线 340 （多出 2 处）`（`.workbuddy/gates/b13_u1_ratchet_negative.txt`），
随后删探针。守卫自检：全扫描计数 <500 即红（照 `native_image_dispose_contract_test.dart` 的"守卫本身失效了"惯例；
第一版直方图键取错切片位（`m.end` 落在数字之后），负向跑出来是 `6×127 2×111 …` 这种没意义的分布，
就是这条自检加负向验证一起抓出来的）。

**add when**：有设备能出前后截图时，按直方图从 **14×97 → 12×91** 开手（这两个值令牌里已有，
风险最低），16/13 先补档再动。

#### U2 · 图表这一层（做了）与金额这一层（判为不必做）

先确认哪些图在语义树里**一个节点都没有**（读代码，不猜）：
`AnalyticsBarChart` 的轴标签是 fl_chart 的 `SideTitleWidget`+`Text`，柱体是画出来的；
`LineChart` 整张图是 `CustomPaint` + `TextPainter`（`Text(` 只命中 1 处，是滑动提示）——
这两个是真空洞。`balance_trend_chart.dart:54` 委托给 `LineChart`，**白赚**不用单独做。
三个饼图/构成图各有 4-5 个真实 `Text` 图例，读屏至少能念出分类名 → 本轮不动（补了是重复劳动）。

落地：
- `lib/widgets/charts/chart_tooltip_bubble.dart` 新增 `chartSeriesSemantics(context, xLabels, series, hideAmounts)`
  （与既有 `chartTooltipLayout` 同处，两图共用，保证措辞与格式一致）。
  输出 `图表，共 N 个点：3/1 120.00, 3/2 80.00, …`；**`hideAmounts` 为真时只念标签不念数值** ——
  这条是隐私口径，不能因为"补无障碍"把用户金额读给旁边的人听。
- `analytics_bar_chart.dart` / `line_chart.dart` 各在 `Stack` 首子节点放一个**无 child 的 `Semantics(label: …)`**。
  为什么是 childless：`Semantics` 继承 `SingleChildRenderObjectWidget` 且 `child` 可空（SDK
  `packages/flutter/lib/src/widgets/basic.dart:7945`），在 `StackFit.expand` 下
  `RenderProxyBox.performResize()` 取 `constraints.biggest` → 直接拿到整张图表的矩形。
  反过来"包一层"要把两图各 150 行缩进整体重排，而**本仓不做全仓 `dart format`**（§13 已有的告诫）。
- 轴标签排除：两条 `Text` 轴标签各包一层 `ExcludeSemantics`（`analytics_bar_chart.dart:221`、`:258`），
  否则读屏把刻度数字和序列摘要混着念。踩点：**`Text` 没有 `excludeSemantics` 参数**，
  第一版直接写 `excludeSemantics: true` 是编译错误（两处），必须用 `ExcludeSemantics(child: …)`。
- l10n：新键 `semanticsChartSeries(count, points)`，4 个 ARB 齐（en 起 `app_en.arb:3851`，模板 ARB 带
  `placeholders` 类型），`flutter gen-l10n` 已跑。
- 新增 `test/widgets/chart_semantics_test.dart`（3 例）：① 柱状图序列逐点进摘要（`3/1 120.00`、`3/3 200.50`）；
  ② `hideAmounts` 时含标签但 `'120.00'` **不出现**；③ 折线图双线两值都进、顺序与 `series` 一致
  （`8月 100.00 / 30.00`）。三例都断言**摘要节点唯一**（`w.child == null` 的 `Semantics`），
  重复标注会念两遍。

**"金额"这一层判为不补**（方案 §五 U2 写了"补金额与图表这一层"）：`AmountText` 渲染的就是 `Text`，
金额本身已在语义树里，且相邻的 caption/币种符号也在 —— 读屏念得出。再包一层 `Semantics` 只会
**替换**掉子节点文本（`Semantics(label:)` 是替换语义不是追加），是净退化。图表侧不一样：那是画出来的，语义树里真空。

**对比度实测（纯算式，`scripts/contrast_check.py`，WCAG 1.4.3）** —— 这项不需要设备，
但本轮只测不改：

| 令牌 | 亮·页面底 `#E5EEFE` | 亮·卡底 `#F9F9F9` | 暗·页面底 `#151A24` | 暗·卡底 `#1C2330` |
|---|---|---|---|---|
| `textPrimary` | 15.20 | 16.85 | 17.43 | 15.76 |
| `textSecondary` | **4.44** | 4.55 | 9.00 | 8.37 |
| `textTertiary` | **2.18** | **2.41** | 5.86 | 5.57 |

- 暗色全过。**亮色 `textTertiary` `#9CA3AF` 连 3.0 的大字线都不过**（177 处调用点）。
- 亮色 `textSecondary`（black54）在页面底 4.44，差 0.06。
- `textDisabled`（black26）1.87 —— 不计：WCAG 1.4.3 明确豁免 inactive/disabled 状态。
- **为什么不建议照数字直接改令牌**：算出来的合格值 `#5F6B7A`（4.65 / 5.15）与 `textSecondary`
  的实际合成色（black54 叠页面底 ≈ `#696D74`）**几乎同一个颜色** —— 三级文字会并到二级上去。
  这不是"换个合格灰"的事，是**亮色文字色阶要重排**（三级拉开到 ≥4.5 需要动 secondary 一起下移），
  属设计决策 + 视觉回归，和 U1 同一个前置。→ 记为待办 **U2-b**，本轮把数字、候选值和代价留在文档里。

**方案 §五 U2 清单里本轮没做的三项**（都不是"忘了"）：读屏实测（TalkBack/VoiceOver）、热区 ≥48×48 全量核查、
大字号下 UI 不破 —— 三者都要真机或截图，且热区核查在无设备条件下只能靠"给每个按钮包 `Semantics`"这种伪证，
不如不交。`textScaler` 放开与 Material You 动态取色按 §五 原判定继续不做。

#### 门禁

- `flutter analyze` → `No issues found!`（`.workbuddy/gates/b13_u_analyze.txt`，33.5s）。
- `flutter test` 全量 → `01:48 +1369 ~1: All tests passed!`（`.workbuddy/gates/b13_u_testfull.txt`，
  F2 后基线 1365 + 本批 4：图表语义 3 + 字号 ratchet 1；skip 数不变）。
- 单文件：`test/widgets/chart_semantics_test.dart` `00:01 +3: All tests passed!`
  （`.workbuddy/gates/b13_u2_chart3.txt`）；`test/styles/font_size_token_ratchet_test.dart` 绿
  （`.workbuddy/gates/b13_u1_ratchet2.txt`）+ 负向红（`b13_u1_ratchet_negative.txt`）。





