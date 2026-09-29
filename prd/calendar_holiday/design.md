# 技术设计：日历节假日与月历样式（calendar_holiday）

> **2026-09-29 修订（按用户需求，第二/三轮之后的增量）**：
> 1. 自动更新由「每日固定时刻」改为「**每月一次**」——`shouldUpdateNow` 去掉 `fixedHour` 参数，口径改为「上次成功日历月 ≠ 当前月即更新」；`holiday_update_meta.fixedHour` 列、「每日更新时刻」设置项与 `setFixedHour` 一并下线（v49 未发布，直接改表定义，无迁移负担）。
> 2. 「按年份获取」升级为「**按年份范围获取**」——设置页双年滚轮抽屉（`showHolidayYearRangePicker`）选起止年份，`HolidayService.fetchYearRange` 补写，单年失败跳过不中止，toast 汇总「成功 N + 失败 M」。
> 3. **2026-09-30 修订（修「选 2000-2017 全部失败」）**：实测数据源下界为 2013（2000 / 2007 / 2008 / 2010 / 2012 均返回空，2013 起完整），`yearMin` 由 2000 收紧为 2013；范围补写改为两阶段流水线——分片并发拉取（4 并发、单年收发超时 10s）+ 串行落库，连续失败 3 次熔断剩余年份，整次操作记账一次（`failureCount` 只 +1，全成功清零），全失败时 toast 报具体原因（`shortError`），设置页加进度弹窗 + 取消。
> 下文与「每日 / fixedHour / 单年滚轮」相关的描述保留原文作历史背景，以本注记为准。

## 0. 结构总览

```text
UI      calendar_page.dart（月历日格 + 金额保留）
        holiday_settings_page.dart（缓存查看 / 立即更新 / 每月自动更新开关 / 按年份范围获取，新）
          └─> Provider：holiday_providers.dart（列表 / 记账 / 刷新触发器）
                └─> Service：holiday_service.dart（网络拉取 + 预置按年兜底 + 每月判定 + fetchYear / fetchYearRange 按年补写，新）
                │            holiday_scheduler.dart（分钟级 tick + 纯函数判定，新）
                │   utils/lunar/{lunar_calendar,chinese_almanac}.dart（历法副标签，纯函数，新）
                └─> Repository：HolidayRepository 抽象 + LocalHolidayRepository（DB 唯一入口，新）
                      └─> Data：db.dart 新增 holiday_entries / holiday_update_meta（schemaVersion 49）
```

分层严格遵循 `AGENTS.md`：UI 只碰 Provider；Service 只调 Repository；Repository 是 DB 唯一入口。历法副标签是无状态纯函数工具，放 `lib/utils/`，UI 可直接调用（与 `lib/utils/` 现有工具同口径）。

## 1. 关键技术决策

### 决策 1：历法副标签移植为纯 Dart 工具（`lib/utils/lunar/`）

**选择**：整体移植 orbit 的 `lunar_calendar.dart`（214 行，农历换算 + 干支表）与 `chinese_almanac.dart`（24 节气 sTermInfo 压缩表 1900–2100 + 公历/农历节日表 + 副标签优先级）。

**理由**：
- 二者均为**无状态纯函数**，零依赖（不引第三方农历包，保持「离线优先 / 无额外依赖」），可直接复用 orbit 已验证的表数据，避免自造轮子踩农历闰月/节气误差。
- 放 `lib/utils/lunar/` 而非 `services/`：它是**计算工具**不是业务编排，UI 每格直接调用即可（和 `lib/utils/currencies.dart` 同定位）。
- 单文件 214 / 约 260 行，均 < 500 行上限，无需拆分。

**代价**：引入约 200 项压缩表常量（hex 字符串），代码体积增加；用单测锚定已知日期（2026-02-17 = 农历正月初一 / 春节、2026-09-23 秋分、2026-10-01 国庆节、2026 → 丙午马年）防止移植抄错。

### 决策 2：节假日缓存落本地 Drift 表，独立 schemaVersion 49

**选择**：`db.dart` 新增两张表并升版：

```dart
/// 中国法定节假日本地缓存（date 主键,整年替换）。随时可整表重建
/// → **不进云同步 / 不进备份**（与 ExchangeRates 同定位,README D2）。
class HolidayEntries extends Table {
  TextColumn get date => text()();      // 'YYYY-MM-DD'
  IntColumn get year => integer()();
  BoolColumn get isHoliday => boolean()(); // true 放假 / false 调休补班
  TextColumn get name => text()();      // '春节' / '春节后补班'
  DateTimeColumn get fetchedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {date};
}

/// 节假日更新记账（单行,id 恒 1）。本地调度状态,不进同步 / 备份。
class HolidayUpdateMeta extends Table {
  IntColumn get id => integer()();              // 恒 1
  IntColumn get lastUpdateMs => integer().withDefault(const Constant(0))();
  IntColumn get lastAttemptMs => integer().withDefault(const Constant(0))();
  IntColumn get failureCount => integer().withDefault(const Constant(0))();
  BoolColumn get autoEnabled => boolean().withDefault(const Constant(true))();
  IntColumn get fixedHour => integer().withDefault(const Constant(8))();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column> get primaryKey => {id};
}
```

迁移（追加到 `onUpgrade` 末尾，幂等）：

```dart
if (from < 49) {
  // v49: 日历节假日本地缓存 + 更新记账（本地配置类表,不进同步白名单/备份）
  await migrator.createTable(holidayEntries);
  await migrator.createTable(holidayUpdateMeta);
  await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_holiday_entries_year ON holiday_entries(year);');
}
```

**理由**：
- **不用 SharedPreferences**：项目约定「数据落 DB 经 Repository」，且需要 `year` 维度查询（按年分组展示 / 整年替换），表结构比 JSON blob 更自然；升版 + 幂等迁移是项目改 schema 的标准动作。
- **不挂 `updated_at` 触发器、不进 `SYNCABLE_TABLES` / 指纹 / diff / 备份**：这是「随时可重建的本地缓存」，与 `ExchangeRates` 完全同构。若误挂触发器或进白名单，会导致（a）云同步回流幻影变更、（b）契约穷举守门测试（`sync_contract_coverage_test.dart`）变红。**这是本设计最需要 review 的边界**。
- `year` 建普通索引：整年替换按 `year` 批量删，设置页按 `year` 分组读，读写比高。

### 决策 3：Repository 只做 DB，网络与判定在 Service

**选择**：
- `HolidayRepository`（抽象，无 `I` 前缀）+ `LocalHolidayRepository`：`getAll()` / `getByYear(year)` / `replaceYear(year, rows)`（**事务内先删该年再插**）/ `getMeta()` / `saveMeta(meta)` / `getByDate(date)`。写入**不**调 `trackerGetter()?.recordUserGlobalChange`（非同步实体，注释说明理由）。
- `HolidayService`：拼 URL、带 UA 的 dio 请求、响应解析、预置兜底、`shouldUpdateNow` 纯函数、`yearsToFetch`、`updateNow(force:)` 编排（网络 → `replaceYear` → `saveMeta`）。

**理由**：整年替换的**原子性**是 Repository 的职责（DB 唯一入口，事务边界不外泄）；网络 / 重试 / 判定是 Service 职责。这样 Repository 单测只需内存库，Service 单测只需 fake repository + 固定时钟，互不耦合。

### 决策 4：调度对齐既有 `BackupScheduler` 范式

**选择**：`lib/services/calendar/holiday_scheduler.dart` 结构照抄 `BackupScheduler`：`Duration checkInterval = 1min`、`Timer.periodic` + `_checking` 互斥、**触发条件做成静态纯函数** `shouldTriggerNow({enabled, lastUpdateMs, now})` 供单测。`lib/app.dart` `initState` 后帧回调里挂载（紧邻既有 `_backupScheduler`），并在挂载时立即触发一次「启动补更」。

**理由**：项目已有一个「App 运行期分钟级 tick + 纯函数判定 + onCheck 注入」的成熟范式，复用同一范式让 review / 测试成本最低，也避免新造第二套调度机制。无后台常驻能力沿用既有已声明非目标。

### 决策 5：年份扩展（按年补写）与预置表「按年合并」（第二轮）

**背景**：第一轮 `loadAll()` 的语义是「DB 有行就以 DB 为准，DB 为空回落 `builtinHolidays()`（2026 预置）」。第二轮要支持补写任意历史年份，一旦 DB 里出现 2022 年的行，`rows.isEmpty == false`，**2026 预置兜底会整体消失**——日历上 2026 的休/班徽标全没。这是必须修掉的硬伤。

**选择**：

1. **`loadAll()` 改为按年合并**：以「年份」为粒度，而非「整表空否」为粒度。

```dart
Future<List<HolidayEntry>> loadAll() async {
  final rows = await _repo.getAll();
  if (rows.isEmpty) return builtinHolidays();
  // 已缓存年份集合：这些年份完全以 DB 为准（含用户补写的历史年份）
  final cachedYears = rows.map((r) => r.year).toSet();
  // 预置表里未被 DB 覆盖的年份（典型：用户只补了 2022，2026 预置需继续兜底）
  final fallback = builtinHolidays()
      .where((r) => !cachedYears.contains(r.year));
  return [...rows, ...fallback];
}
```

  合并结果**不写库**——它是「读时视图」，DB 始终保持用户实际拉取的内容。这样 `replaceYear(2022, ...)` 不会污染 2026 兜底，也不需要把预置表灌进 DB（避免「假缓存」让概览条数虚高）。

2. **新增公开 `fetchYear(int year)`**（供设置页按年补写）：单年 `_fetchYear` → `_repo.replaceYear(year, rows)` → 按 AC-E6 记 `meta`。

```dart
/// 返回记录：更新记账 + 该年实际返回行数（rowCount == 0 = 该年线上无数据）
Future<({HolidayUpdateMetaData meta, int rowCount})> fetchYear(int year) async {
  final now = DateTime.now();
  final rows = await _fetchYear(year);          // 失败抛 HolidayFetchException
  await _repo.replaceYear(year, rows);          // 事务内先删该年再插
  return _recordSuccess(year, now, rows.length,
      isAutoScope: yearsToFetch(now).contains(year));
}
```
（`rowCount` 让 UI 区分「已更新」与「该年无数据」二者，见 §5 / AC-E7。）

3. **记账口径（AC-E6）**：`lastUpdateMs` 是「每月自动更新」的去重依据，**只有 `yearsToFetch(now).contains(year)` 时才写**（即今年 / 12 月的明年）。手动补写历史年份（如 2022）**只写 `lastAttemptMs`**（并清零 `failureCount`），否则会把本月本该触发的自动更新压掉（自动更新永远拉不到历史年份，而本月真正要拉的今年数据被误判为「本月已成功」）。

4. **年份边界**：`yearMin = 2013`（timor.tech 实测有数据的最早年份：2000 / 2007 / 2008 / 2010 / 2012 均返回空，2013 起完整），`yearMax(now) = now.year + 1`（与 `yearsToFetch` 的 12 月跨年口径一致）。设置页年滚轮用 `WheelDatePicker.minDate/maxDate` 约束。

**理由**：
- 按年合并是**最小改动**修复硬伤，不引入新表 / 新字段，纯读侧逻辑。
- `fetchYear` 复用既有 `_fetchYear` 私有方法（第一轮 `_update` 内部已有），只需抽成「公开入口 + 记账策略差异」，不新增网络代码路径。
- AC-E6 的差异化记账是**必须**的：否则「手动补 2022」会静默抑制当天自动更新，属于隐性数据新鲜度 bug。

**代价**：`fetchYear` 与 `updateNow` 各有一条「成功 → 写 meta」路径，需靠单测锁住两者差异（`fetchYear(2022)` 后 `lastUpdateMs` 不变、`fetchYear(thisYear)` 后 `lastUpdateMs` 更新）。

## 2. 文件清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `lib/utils/lunar/lunar_calendar.dart` | 新增 | 移植 orbit：农历换算 + 月/日标签 + 干支生肖 |
| `lib/utils/lunar/chinese_almanac.dart` | 新增 | 移植 orbit：节气压缩表 + 节日表 + `daySubLabel` |
| `lib/data/db.dart` | 改 | +2 表、`tables` 列表、schemaVersion 49、迁移块、`year` 索引 |
| `lib/data/repositories/holiday_repository.dart` | 新增 | 抽象接口 + `HolidayEntry` / `HolidayUpdateMeta` 领域模型 |
| `lib/data/repositories/local/local_holiday_repository.dart` | 新增 | Drift 实现（事务整年替换、记账 upsert） |
| `lib/data/repositories/local_repository.dart` | 改 | 聚合持有第 13 个子 Repository |
| `lib/services/calendar/holiday_service.dart` | 新增 | 网络 + 兜底 + 判定 + 编排；含 `fetchYear(int year)`（按年补写）与 `loadAll()` 按年合并 |
| `lib/services/calendar/holiday_scheduler.dart` | 新增 | 分钟级 tick + 纯函数判定 |
| `lib/providers/holiday_providers.dart` | 新增 | service / list / meta / refresh 触发器 |
| `lib/providers/all_providers.dart`（及 `providers.dart` barrel） | 改 | 导出新 provider |
| `lib/pages/calendar/calendar_page.dart` | 改 | 月历日格重写（副标签 / 徽标 / 周末色 / 底色 / 今天实心 / 选中描边），保留金额 |
| `lib/pages/settings/holiday_settings_page.dart` | 新增 | 缓存查看 / 立即更新 / 开关 / 时刻选择；**第二轮**加「按年份获取」行 + 年份分组标题「更新该年」按钮 |
| `lib/pages/main/mine_page.dart` | 改 | 「功能管理」组新增「日历与节假日」入口 |
| `lib/app.dart` | 改 | 挂载 `HolidayScheduler` + 启动补更 |
| `lib/l10n/app_zh.arb` / `app_en.arb`（+ `app_zh_TW.arb` / `app_ko.arb`） | 改 | 新增 `holiday_*` 文案 |
| `test/utils/lunar/chinese_almanac_test.dart` | 新增 | 历法锚定日期 |
| `test/services/calendar/holiday_service_test.dart` | 新增 | 判定全分支 + 解析 + 兜底表 |
| `test/data/repositories/local_holiday_repository_test.dart` | 新增 | 内存库整年替换 + 记账 roundtrip |

## 3. 月历日格布局（`calendar_page.dart`）

> **2026-09-29 样式修订（对齐小米日历）**：本节为第三轮修订后的口径。变化点 —— 数字放大加粗（18 / w600，强调 w700）、选中从「主色描边」改为「实心主色圆角块 + 白字」、今天未选中改为「浅主色底 + 主色加粗数字」、补位格弱显农历副标签、卡片去掉主题色描边、`rowHeight` 78 → 72（骨架 548 → 512）、**格内容整组垂直居中**（修复「字挤在格顶、底下大片空底」的留白观感）。徽标 14px、整格内缩底色块、金额保留等口径不变。

现状：`rowHeight: 78`。数字放大到 18 后单格最多 4 行内容（数字 18 + 副标签 ~10 + 支出 12 + 收入 12 + 内边距 ~5 ≈ 55），**`rowHeight` 定为 72**（紧凑近方形，内容居中后不留空底），骨架高度 548 → **512**（6×72 + 表头 30 + header 50），与 `_buildCalendarSkeleton` 占位同步。

新日格（`_buildDateCell`）：

```text
┌──────────────┐
│         [休] │  ← 14px 圆徽标（仅当月且有节假日数据）
│   28  ← 18号 │  ← 选中(含今天被选中)=主色实心白字 / 今天未选中=浅主色底+主色粗体
│   秋分       │  ← 副标签（节日>农历节日>节气>农历日；补位格弱显农历）
│  -66         │  ← 支出（保留既有千/万缩写）
└──────────────┘
```

- **底色优先级**：选中实心主色 > 今天浅主色底（α0.12）> 放假日浅底（周末识别色 α0.10）> 调休补班压暗底（警示色 α0.07）> 无底。
- **数字色**：补位 → `textTertiary` α0.3；选中实心块 → 白；今天未选中 → 主色；周末 → 周末识别色；其余 → `textPrimary`。数字统一 w600，选中 / 今天 w700。
- **周末识别色** = `PiggyTokens.info(context)`；**补班橙** = `PiggyTokens.warning(context)`。二者均为既有语义 token，暗黑自动切换，**不新增裸色值**（AC-A9）。
- **金额色**：选中实心块内转白（α0.9，对比度兜底），其余格（含今天浅底）保持 `incomeColor/expenseColor`。
- **卡片**：日历卡与当日列表卡去掉 `borderColor: primaryColor`，回到 SectionCard 默认细边 + 阴影（小米的素卡口径）。
- `headerTitleBuilder`（「20xx年xx月 ▾」可点跳转）、横滑翻月、`onDaySelected`、下方「该日记账」列表与按钮**全部保持不变**（不在本轮范围）。

**边界与风险**：`rowHeight` 固定 → 系统大字号下 4 行内容可能溢出。兜底：副标签与金额均 `maxLines: 1` + `overflow: ellipsis`，副标签与金额整块套 `Flexible` + `FittedBox(scaleDown)`（loose 保持居中、超出钳住缩小），并在 `test/pages/calendar` 加一个 textScale 1.3 的渲染回归。

## 4. 节假日数据层要点

**数据源**：`GET https://timor.tech/api/holiday/year/{year}`，头 `User-Agent: Mozilla/5.0 ... Chrome/120 ...`（无 UA 被 Cloudflare 拦）、`Accept: application/json`、20s 超时。响应 `{"code":0,"holiday":{"MM-DD":{"holiday":true,"name":"春节","date":"2026-02-15"}}}`；`date` 字段优先，缺失时用 `MM-DD + year` 拼。

**预置兜底**：`builtinHolidays()` 内置 2026 年全量放假 + 调休补班行（与 orbit 同源，国办发明电〔2025〕10 号）。**按年合并语义**（第二轮修订，见决策 5）：以「年份」为粒度——DB 已缓存的年份完全以 DB 为准，预置表里**未被 DB 覆盖的年份**继续兜底，二者拼接返回。这样补写了 2022 年也不会让 2026 预置徽标消失（AC-E5）。合并结果只作读时视图、不写库。更早年份线上无数据（2000 起可查但多半为空，空 map 属正常）。

**年份边界**：`yearMin = 2013`（timor.tech 实测下界，见上）；`yearMax(now) = now.year + 1`。设置页年滚轮用此边界约束可选范围（AC-E7）。

**按年补写**：公开 `fetchYear(int year)` = `_fetchYear(year)` → `_repo.replaceYear(year, rows)` → 记 meta。记账按 AC-E6 区分：`yearsToFetch(now).contains(year)`（今年 / 12 月的明年）时写 `lastUpdateMs`；历史年份只写 `lastAttemptMs` 并清零 `failureCount`，避免抑制本月自动更新。空响应（`holiday == {}`）视为成功、该年替换为空集（清掉旧数据），不抛错。

**每月判定**（纯函数，2026-09-29 修订）：

```dart
/// 从未成功 → true；上次成功的日历月 ≠ 当前月（跨月首查）→ true；否则 false
static bool shouldUpdateNow({required int lastUpdateMs, required DateTime now})
```

**年份集合**：`yearsToFetch(now)` = `[thisYear]`，`now.month == 12` 时 `[thisYear, thisYear+1]`。

**失败语义**：请求失败 → 记 `lastAttemptMs` + `failureCount++`，**保留旧缓存**，下次 tick / 下次启动按缺额重试；成功 → `lastUpdateMs = now`、`failureCount = 0`。整年替换失败整体回滚（Repository 事务），不留半截年份。

**隐私**：新增一个第三方出网请求，与「无追踪 / 离线优先」定位需显式披露——请求仅带**年份**，不含任何账本 / 账户 / 设备标识；提供「每日自动更新」开关可彻底关闭（关闭后仅手动更新）。文档侧在隐私政策/同步说明里补一句（本轮在 design 记录，代码侧用开关兑现 AC-C4）。

## 5. 设置页（`holiday_settings_page.dart`）

- 概览卡：`共 N 条（放假 X · 补班 Y）` / `覆盖年份：2026–2027` / `上次成功更新：M月D日 HH:mm`（或「从未成功」）/ `连续失败 N 次（旧缓存保留可用）`（>0 才显示）。
- 「立即更新」`FilledButton.icon`：进行中显示 16px spinner 并禁用；成功 `节假日数据已更新`，失败提示错误（`WaitToast`/项目既有提示组件，实现时按 `lib/widgets/ui` 现有能力选型）。
- 「每月自动更新」`SettingsToggleItem` → 写 `holiday_update_meta.autoEnabled`（2026-09-29 修订）。
- ~~「每日更新时刻」`SettingsNavItem`~~ → **2026-09-29 修订下线**：自动更新改为每月一次后无时刻语义，`fixedHour` 列随之下线。
- **「按年份范围获取」（第二轮 → 2026-09-29 修订）** `SettingsNavItem`（图标 `Icons.event_available_outlined`）→ 点开双年滚轮抽屉 `showHolidayYearRangePicker(minYear: 2000, maxYear: 明年)`（`lib/pages/settings/widgets/holiday_year_range_picker.dart`，结构对齐 WheelDatePicker 双轮口径，起止联动钳制 start ≤ end）；确定后调 `HolidayService.fetchYearRange(start, end)` 逐年补写：全部成功按有无数据分别 toast 汇总（`holidayFetchRangeDone` / `holidayFetchRangeDoneNoData`），单年失败跳过不中止，收尾按 `holidayFetchRangePartial(updated, count)` 汇总提示；单年范围退化用 `holidayFetchYearDone` / `holidayYearNoData` 单年文案。成功后 `invalidate(holidayListProvider)` + `holidayMetaProvider`。
- **年份分组标题右侧「更新该年」（第二轮）**：`_buildYearGroups` 的年份小标题行由裸 `SettingsSectionLabel` 改为 `Row`（左 `SettingsSectionLabel` + 右 `IconButton`/`InkWell` 小图标 `Icons.refresh`），点击调 `fetchYear(该年)`。**取舍**：与「按年份获取」是同一能力的两处入口——前者面向「我知道要哪年但列表里还没有」，后者面向「列表里已有该年，就地刷新」；都走同一个 `fetchYear`，无重复逻辑。
- 按年倒序分组：`M月D日` + 休/班徽标 + 名称（复用 `SectionCard`，徽标配色与日历页同源）。
- 全部写操作经 `HolidayService` → `HolidayRepository`，成功后 `ref.invalidate(holidayListProvider)` + `holidayMetaProvider`。

## 6. l10n key（`holiday_` 前缀）

`holidaySettingsTitle` / `holidaySettingsDesc` / `holidayCacheOverview` / `holidayCacheCount`（占位 count/off/work）/ `holidayCoverYears` / `holidayFixedHourLabel` / `holidayLastUpdate` / `holidayNeverUpdated` / `holidayFailureCount` / `holidayUpdateNow` / `holidayUpdating` / `holidayUpdateSuccess` / `holidayUpdateFailed`（占位 error）/ `holidayAutoUpdate` / `holidayAutoUpdateDesc` / `holidayYearGroup`（占位 year/count）/ `holidayBadgeOff`（休）/ `holidayBadgeWork`（班）/ `holidayEmptyCache` / `holidayLoadFailed`。

**第二轮新增**：`holidayFetchByYear`（「按年份获取」）/ `holidayFetchByYearDesc`（副标题：支持 2000 年至明年）/ `holidayUpdateYear`（分组标题按钮 tooltip / 无障碍标签）/ `holidayFetchYearDone`（占位 year）/ `holidayYearNoData`（占位 year）/ `holidayFetchYearFailed`（占位 error）。均按 `app_zh.arb` → `app_en.arb` → `app_zh_TW.arb` → `app_ko.arb` 顺序补齐，编号动作后缀 `_title` / `_desc` / `_btn` / `_hint` 口径（见 AGENTS.md i18n 约定）。

## 7. 测试计划

| 层 | 文件 | 覆盖 |
|---|---|---|
| 工具 | `test/utils/lunar/chinese_almanac_test.dart` | 2026-02-17→春节、2026-10-01→国庆节、节气日命中、初一显示农历月名、2026→丙午马年、非节日回落农历日 |
| 服务 | `test/services/calendar/holiday_service_test.dart` | `shouldUpdateNow` 全分支（从未成功 / 到点 / 同日不重复 / 错过补更 / 自定义时刻）、`yearsToFetch` 12 月含明年、响应解析形状、预置表覆盖关键日、无网络时回落预置表；**第二轮**：`fetchYear` 成功 / 空响应（`{}` 视为成功清空该年）/ 失败（抛 `HolidayFetchException`、旧缓存保留）三分支，`fetchYear(历史年)` 不改 `lastUpdateMs`、`fetchYear(今年)` 改 `lastUpdateMs`（AC-E6），`loadAll()` 按年合并回归（DB 有 2022 + 预置 2026 → 两者都在，AC-E5） |
| 仓库 | `test/data/repositories/local_holiday_repository_test.dart` | 内存库 `replaceYear` 整年替换（旧行删除、跨年不误删）、`getMeta` 默认值、`saveMeta` roundtrip、`fixedHour` clamp |
| 页面 | `test/pages/calendar/calendar_cell_test.dart`（新增或并入既有） | 休/班徽标渲染、副标签渲染、textScale 1.3 不溢出 |
| 回归 | `test/widgets/calendar_month_jump_test.dart` | 既有年月跳转不受影响（不修改，仅确认全绿） |

`NativeDatabase.memory()` 用例在 Windows 本地需 `sqlite3.dll` 在 PATH（见 `AGENTS.md`）。

## 8. 实施步骤

1. 移植 `lib/utils/lunar/` 两个纯函数文件 + 单测（先红后绿）。
2. `db.dart` 加两表 + schemaVersion 49 + 幂等迁移；`dart run build_runner build --delete-conflicting-outputs` 生成 `db.g.dart`。
3. `HolidayRepository` 抽象 + 本地实现 + 聚合接线 + 单测。
4. `HolidayService`（网络 / 兜底 / 判定 / 编排）+ `HolidayScheduler` + 单测。
5. `holiday_providers.dart` + barrel 导出；`app.dart` 挂调度 + 启动补更。
6. `holiday_settings_page.dart` + `mine_page.dart` 入口 + l10n（zh/en/zh_TW/ko）+ `flutter gen-l10n`。
7. 重写 `calendar_page.dart` 日格（副标签 / 徽标 / 周末色 / 底色 / 今天实心 / 选中描边）+ 骨架高度 + 页面回归测试。
8. 门禁：`flutter analyze --fatal-infos`、`flutter test`，暗黑模式人工核对。

**第二轮（年份扩展）**：

9. `HolidayService`：加 `yearMin = 2013`（2026-09-30 由 2000 收紧，数据源实测下界）/ `yearMax(now)` / 公开 `fetchYear(int year)`；`loadAll()` 改按年合并；补 `holiday_service_test.dart`（fetchYear 三分支 + AC-E6 记账差异 + loadAll 合并回归），并更新既有 `loadAll`「DB 有行即返回」用例为新合并语义。设置页加「按年份获取」行 + 年份分组标题「更新该年」按钮；4 个 arb 补 6 个 key + `flutter gen-l10n`；门禁同上。

## 9. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 误把新表纳入同步 / 备份 / `updated_at` 触发器 | 幻影变更、契约守门测试变红、备份体积无谓增大 | 表格与指纹/diff/`_updatedAtTouchTables`/备份清单**均不改动**；review 时重点核对 |
| `timor.tech` 限流 / 变更 / 不可达 | 无新数据 | 预置兜底 + 静默失败保留旧缓存 + 失败计数可观测 |
| 农历表移植抄错（hex 压缩表） | 副标签错日 | 单测锚定多个已知日期 |
| `rowHeight` 增大 + 副标签导致溢出 | 视觉红条 | `maxLines`/`ellipsis` + 骨架同高 + textScale 回归 |
| 新增出网请求与「无追踪」定位冲突 | 信任问题 | 仅传年份、默认开但可关、文档披露 |
| 迁移不幂等 / 老库升级崩溃 | App 打不开 | `CREATE ... IF NOT EXISTS` 语义 + `migrator.createTable`；不触碰后续版本才建的表 |
| `dart format` 口径漂移（项目已知坑） | 大量无关 diff | 只改本批文件，不跑全仓 `dart format .`；手工对齐旧式换行风格 |
| `loadAll()` 合并写错（第二轮） | 补写历史年份后 2026 预置徽标消失，或 DB / 预置年份重复渲染 | 以「年份」为粒度合并；AC-E5 合并回归单测（DB 2022 + 预置 2026 → 两者都在） |
| 手动补写历史年份误写 `lastUpdateMs`（第二轮） | 当天自动更新被误判「已成功」而跳过，今年数据不新鲜 | AC-E6 差异化记账：历史年份只写 `lastAttemptMs`；单测锁住 `fetchYear` 与 `updateNow` 的 meta 差异 |
| 历史年份线上无数据（空 map，第二轮） | 用户以为拉取失败 | 空响应按成功处理并提示 `holidayYearNoData(year)`，不抛错、不记 failure |