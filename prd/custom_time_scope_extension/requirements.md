# 洞察页自定义时间档位（季度 / 任意起止区间）— 需求文档

> **状态：已落地**（2026-10-13，Q1–Q6 均按推荐方案执行，编码完成，见文末「落地状态」）
> 前置批次：`prd/analytics_scope_enum_refactor/`（已落地，commit 9b476305）——
> `AnalyticsScope` 枚举 + 周期计算纯函数层。本批次是该重构预留的扩展方向：
> 旧设计文档 §三 明示「自定义档位需要**锚点携带起止日期**（record 形状扩展）」。

## 一、需求理解

在洞察页现有「周 / 月 / 年 / 全部」四档时间维度上，新增**季度**与**任意起止日期**
两个档位，让用户能按自然季度复盘、或对任意感兴趣的时间段（如旅行前后、发薪周期、
大促期间）做与月/年视角同构的洞察（摘要卡 + 趋势图 + 分类排行 + 海报分享）。

## 二、功能需求

### F1 季度档位（`AnalyticsScope.quarter`）

- 分段控件在「月」「年」之间插入「季」段，成为 周 / 月 / **季** / 年 / 全部。
- 周期口径**跟随账本 `monthStartDay`（1-28）**，与「年」档位同哲学（账期口径）：
  - startDay=1（默认）：Q1=1/1~4/1、Q2=4/1~7/1、Q3=7/1~10/1、Q4=10/1~次年1/1（半开区间）。
  - startDay=10：Q1=1/10~4/10 … Q4=10/10~次年1/10，周期命名为起始月所在季度。
  - 「当前季度」判定用区间包含（与周/年一致），当前季度 `end` 截断到今天+1 天。
- 选期器：点导航行文案弹出季度选择（复用 wheel picker 年 + 季两列，或年月选择后吸附到
  该月所在季度；实现细节见 design.md）。
- 左右滑 / 箭头：前后各平移一个季度；**前进钳制**「不进未来季度」（与年档位同口径）。
- 上期对比（摘要卡第二格）：**同比去年同季度**（待拍板 Q2），对比文案复用「较去年」。
- 趋势图 6 桶：**本季度 + 前 5 个季度**（环比序列，按季度分桶），x 轴标签如 `26Q3`；
  高亮最后一桶。
- 摘要卡平均值标签：**日均**（与周/月一致；待拍板 Q3 备选「季均」）。
- 分享海报：回退到该季度所在**年报**（待拍板 Q5）。

### F2 任意起止区间档位（`AnalyticsScope.custom`）

- 分段控件「全部」左侧插入「自定义」段；首次切入默认区间 = **近 30 天（含今天）**。
- 选期器：点导航行文案弹出项目统一区间抽屉 `showPiggyRangePickerSheet`
  （与 RangeReportPage 同款，含节假日上下文），选定 `[start, end)` 半开区间。
- 导航行文案：`yyyy-MM-dd ~ yyyy-MM-dd`（含端展示，与 RangeReportPage._rangeText 同风格）。
- 左右滑 / 箭头：**等长平移**整个区间（前移 / 后移一个区间长度，与
  RangeReportPage 的平移交互一致），不做未来钳制（用户显式选的区间自由平移）。
- 上期对比：**等长环比**（紧邻本期之前、等长的窗口 = `RangeReportPage.momWindow` 语义），
  对比文案新增 l10n「较上一区间」（待拍板 Q4）。
- 趋势图：自适应分桶——区间 ≤ 31 天按天、超过按月滚桶（复用 RangeReportPage 的
  `dayChartLimit`（=31）/ `rollToMonths` 先例）；不高亮任何桶（区间无「当前周期」概念）。
- 摘要卡平均值标签：**日均**，除数 = 区间实际天数；区间不截断（用户选哪段就是哪段，
  待拍板 Q6）。
- 分享海报：**隐藏分享按钮**（区间无对应海报模板）（待拍板 Q5）。

### F3 既有口径不回改

- 四个既有档位（周/月/年/全部）的 6 条「行为冻结」口径逐条保留，见
  `prd/analytics_scope_enum_refactor/design.md` §四；新档位不携带旧档位的口径不一致。
- 顺带归位（低风险清理）：`range_report_page.dart:574` 对 `CategoryRankRow` 传
  `scope: AnalyticsScope.month` 的权宜值改传 `AnalyticsScope.custom`（语义归位，
  该组件的分支语义「非 all 透传区间」不变，断言语义零变化）。

## 三、待拍板决策（请在评审时逐条确认或改选）

| # | 问题 | 推荐 | 备选 |
|---|------|------|------|
| Q1 | 「自定义」档位内嵌洞察页，还是只保留 RangeReportPage 入口？ | **内嵌洞察页**（洞察=概览三件套，RangeReport=明细报表含标签/环比同比双对比，定位互补） | 只做季档位，自定义维持跳转 RangeReportPage |
| Q2 | 季度摘要卡上期对比 | **同比去年同季度**（复用「较去年」文案，与月/年一致） | 环比上季度（需新文案「较上一季度」） |
| Q3 | 季度周期是否吃 `monthStartDay` | **账期口径**（与年档位同哲学） | 固定自然季度（与账期脱钩） |
| Q4 | 自定义档位上期对比 | **等长环比**（复用 momWindow 语义，新文案「较上一区间」） | 无对比（第二格像「全部」那样显示记账笔数） |
| Q5 | 分享海报 | **季→年报回退；自定义→隐藏分享** | 季→季末月月报回退；自定义→区间起始月月报 |
| Q6 | 自定义区间是否做「截断到今天」 | **不截断**（用户显式选择，选哪段就是哪段） | 统一截断口径（与冻结口径 6 一致，零特判） |

## 四、验收标准

1. 分段控件出现 5 段：周 / 月 / 季 / 年 / 全部（+自定义共 6 段时按 Q1 结论），
   穷尽 switch 全部编译通过（无 `default` 兜底）。
2. 季度档位：startDay=1 与 startDay=10 两种账本下，周期边界、当前季度截断、
   同比上期、6 季度图桶、前进钳制各有单元测试钉住（红→绿）。
3. 自定义档位：默认近 30 天、区间抽屉改期、等长平移、环比上期、天/月自适应图桶，
   各有单元测试钉住。
4. 既有 4 档位行为零变化：`test/utils/analytics_scope_test.dart` 22 个特征测试原样通过。
5. `flutter analyze` 0 issue；全量 `flutter test` 绿；
   `git diff --stat` 波及面仅限本批点名文件（**不得跑 `dart format .`**）。
6. 真机（MuMu `127.0.0.1:16384`，dev flavor）UI 回归：6 段切换、季度/区间选期、
   左右滑、图表、摘要卡、海报入口按 Q5 结论各验一遍。

## 五、边界条件

- 账期口径季度的跨年借位：startDay=28、Q4=10/28~次年1/28，DateTime 自动进位，测试钉住。
- 自定义超长区间（数年）：`totalsByDay` 单查询返回数千行、内存按月滚桶，可接受；
  不新增 repo 方法（数据层零改动）。
- 自定义区间 start==end（空区间）：选期器约束 start < end（区间抽屉既有约束）。
- 未来日期：区间抽屉允许选到今天之后，数据自然为空，图表空态走既有空态分支。
- U8 记忆化缓存键已含 `start|end`，自定义档位天然按区间隔离，无需改 memoKey。

## 六、落地状态（2026-10-13 回填）

- Q1–Q6 全部按推荐方案执行（内嵌洞察页 / 季度同比 / 账期口径 / 等长环比 /
  季→年报回退 + 自定义隐藏分享 / 不截断）。
- 与文档初稿的 2 处口径修正：
  1. F2 图表阈值「≤ 60 天」实为 **31 天**（对齐 `RangeReportPage.dayChartLimit = 31` 既有先例）。
  2. 对比文案沿用现有措辞体系「比上周 / 比上年」，新 key `analyticsComparedToPrevRange`
     实际落地为「**比上一区间**」（初稿写「较上一区间」）。
- 改动面：`lib/utils/analytics_scope.dart`（枚举 + 纯函数，43 单测绿）、
  `lib/pages/main/analytics_page.dart`（6 段控件、选期器、图表分支簇）、
  `lib/widgets/analytics/analytics_summary.dart` / `category_rank_row.dart`（穷尽 switch 补臂）、
  `lib/pages/report/range_report_page.dart`（权宜值归位 `AnalyticsScope.custom`）、
  l10n 四语种 +5 key（`analyticsQuarter` / `analyticsCustom` / `analyticsThisQuarter` /
  `analyticsSelectedRange` / `analyticsComparedToPrevRange`）、
  `test/utils/analytics_scope_test.dart`（22 个特征测试原样保留 + 21 个新断言）。
- 门禁结果：`flutter analyze` 0 issue；全量 `flutter test` **2359 个全部通过**
  （基线 2338 + 新增 21）；`git diff --stat` 仅含本批点名文件；未跑 `dart format .`。
  详细记录见 `design.md` §八。
