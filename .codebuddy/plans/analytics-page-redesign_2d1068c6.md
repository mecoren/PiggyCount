---
name: analytics-page-redesign
overview: 参考截图风格全面优化洞察（analytics）页：新增周报维度（周/月/年/全部四视角）、类型切换改为三段胶囊（支出/收入/结余）、汇总卡/趋势折线图/柱状图/环形图外置标签/分类排行全面美化，配色跟随用户主题色，所有金额支持大金额紧凑显示（万/k）。
design:
  styleKeywords:
    - 克制优雅
    - 报表卡片
    - 主题色强调
    - 大圆角白卡
    - 紧凑数字
  fontSystem:
    fontFamily: PingFang SC
    heading:
      size: 18px
      weight: 700
    subheading:
      size: 15px
      weight: 600
    body:
      size: 14px
      weight: 400
  colorSystem:
    primary:
      - "#F8C91C"
      - "#3B82F6"
    background:
      - "#F3F3F3"
      - "#FFFFFF"
    text:
      - "#111827"
      - "#6B7280"
      - "#9CA3AF"
    functional:
      - "#22C55E"
      - "#EF4444"
      - "#F59E0B"
todos:
  - id: week-scope-utils
    content: 新建 week_range.dart 周周期工具并添加边界单测
    status: completed
  - id: l10n-keys
    content: 新增周报/分类构成/笔数等 l10n key（四语言）并运行 gen-l10n
    status: completed
  - id: repo-category-count
    content: 扩展 totalsByCategoryWithHierarchy 返回分类笔数（接口+本地实现+门面）
    status: completed
  - id: chart-upgrades
    content: 升级折线图（平滑曲线/Y轴万缩写/点按气泡）与柱状图（标题+badge+轴本地化），新增 formatCompactAxis
    status: completed
    dependencies:
      - l10n-keys
  - id: analytics-page-revamp
    content: 重构 analytics_page：周报维度、四段周期胶囊、周期导航行、三段收支胶囊
    status: completed
    dependencies:
      - week-scope-utils
      - l10n-keys
      - chart-upgrades
  - id: category-composition
    content: 分类构成改造：环形图外置标签+主/子分类切换+排行榜常驻（序号/笔数/调色板/紧凑金额）
    status: completed
    dependencies:
      - repo-category-count
      - analytics-page-revamp
  - id: verify-regression
    content: 运行 flutter analyze 与相关测试，核查横滑/分享/空态/hideAmounts 无回归
    status: completed
    dependencies:
      - category-composition
---

## 用户需求

参考三张「收支报表」截图，对洞察页（AnalyticsPage）进行全面优化：风格参考截图但保持克制、整体优雅，跟随用户主题色；所有金额数字支持大金额显示（万/k/M 紧凑格式，不溢出）。

## 产品概述

洞察页升级为类似截图的报表式布局：顶部四段周期胶囊（周/月/年/全部）+ 周期导航行（‹ 周期范围 › + 支出/收入/结余三段胶囊），内容区依次为：2×2 汇总卡（蓝色 marker 竖条+大字号金额）、趋势折线图卡（平滑曲线+Y轴大金额缩写+点按气泡）、趋势柱状图卡（标题+右上角汇总 badge）、分类构成卡（环形图外置标签+主/子分类切换）、分类排行榜（序号+图标+名称笔数+彩色进度条+百分比+紧凑金额）。

## 核心功能

- 新增「周报」维度：周一~周日为一周，周期导航支持前后周切换与日期跳转，同比上期=上周；保留「全部」，共 周/月/年/全部 四个维度
- 收支视角从下拉菜单改为三段胶囊切换（支出/收入/结余），结余逻辑与四格指标含义保持不变
- 汇总卡四指标全部支持大金额紧凑显示，周报下标签为「本周支出/日均/比上周/收支结余」
- 折线图：平滑曲线、左侧 Y 轴大金额缩写标签（如 3.1万）、点按数据点显示气泡 tooltip（日期+类型+金额）
- 柱状图：卡片标题（如「支出趋势」）+ 右上角主题色 badge（总额+周期范围），Y 轴缩写本地化（万，非英文 w/k）
- 分类构成：环形图外置标签（名称+百分比）常驻显示，排行榜常驻，新增主分类/子分类小胶囊切换（子分类模式打平展示）
- 排行榜行：排名序号、分类笔数（如「转账 1笔」）、每类颜色与环形图调色板一致、金额紧凑显示
- 配色全部跟随用户主题色与收支配色方案（PiggyTokens），亮暗模式自适应，不硬编码蓝色
- 不回归：横滑手势、分享按钮（周报回退到月报海报）、外币补折算横幅/脚注、空态、隐藏金额（hideAmounts）

## 技术栈

- 沿用现有栈：Flutter + Dart + Riverpod + fl_chart + drift（本地 SQLite）
- 样式：PiggyTokens/PiggyDimens/PiggyChartTokens 令牌体系（禁止魔法数字与硬编码色）
- 金额格式化：复用 `lib/utils/format_utils.dart` 的 `formatBalance` 与 `AmountText(useCompactFormat: true)`
- 国际化：4 个 arb（zh/zh_TW/en/ko）+ `flutter gen-l10n`（l10n.yaml 已配置）

## 实现方案

### 1. 周报维度（数据与状态）

- 新增 `lib/utils/week_range.dart`：`weekRangeFor(DateTime)` 返回周一 00:00 起的半开区间 `[start, start+7d)`；`weekLabel(range)` 输出 `2026.08.03～08.09` 风格文案。默认周一起始（项目无周起始日设置，YAGNI 不新增设置项）
- `analytics_page.dart`：`_scope` 增加 `'week'`；周报选中日期用页面本地 state `_selWeek`（不复用 selectedMonthProvider，避免污染首页月份状态）；series 用现有 `repo.totalsByDay`；prevStart/prevEnd = 上周区间；周期选择器用 `showWheelDatePicker(mode: ymd)` 跳转所在周；横滑/箭头 ±7 天（下周不超过本周）
- 分享按钮：周报时回退到该周所在月的 month 海报（现有服务不改）

### 2. 顶部布局

- scope 胶囊：`WaitSlidingSegmentedControl` 扩为 4 段（周/月/年/全部）
- 新增周期导航行：‹ 箭头 + 周期文案（周=`2026.08.03～08.09`，月=`2026-08`，年=`2026`，全部=全部年份）+ › 箭头 + 右侧三段小胶囊（支出/收入/结余，复用 WaitSlidingSegmentedControl 紧凑样式）；删除 `_showTypeMenu` 下拉；保留页面级横滑切 type 手势（提示文案更新）

### 3. 大金额显示（统一策略）

- `format_utils.dart` 新增 `formatCompactAxis(double v, {required bool isChinese})`：中文 ≥1万→`x.x万`，<1万→千分位整数；英文 k/M/B；供折线/柱状 Y 轴与 tooltip 使用，替代 bar chart 里的英文 `_fmt`
- AnalyticsSummary 四格全部 `AmountText(useCompactFormat: true)`（当前仅总额用了），金额字号对超长文本用 FittedBox/缩小兜底防溢出
- CategoryRankRow 金额改 compact；环形图中心与 badge 同样 compact

### 4. 图表升级

- `line_chart.dart`（自绘 CustomPaint，谨慎扩展避免破坏其他调用方）：新增可选参数 `smooth`（三次贝塞尔 monotone 插值）、`showYAxisLabels`（左侧 4~5 档 compact 标签）、点按 tooltip（`onPointTap(index)` 回调 + 页面侧 Overlay/Stack 气泡，气泡内容 `MM.dd 支出 ¥1,918.03`）。所有新参数带默认值，旧调用方零变化
- `analytics_bar_chart.dart`：顶部加标题行（标题 + 右上角主题色 badge：compact 总额 + 周期文案）；启用 leftTitles 用 `formatCompactAxis`；柱体圆角加大、宽度自适应保留
- `category_pie_chart.dart`：扇区内百分比改为外置标签（fl_chart `badgeWidget` + `badgePositionPercentageOffset>1` 实现外置「名称 xx.xx%」）；`_kPieColors` 调色板导出共享给排行榜；新增可选 `data` 来源切换（主分类聚合 / 子分类打平）

### 5. 分类笔数（repo 扩展）

- `totalsByCategoryWithHierarchy` 返回 record 增加 `int count` 字段：接口 `statistics_repository.dart`、实现 `local_statistics_repository.dart`（同一循环内累加，零额外查询）、门面 `local_repository.dart` 三处签名同步；唯一调用方 analytics_page 聚合逻辑 `_aggregateTopLevelCategories` 同步累加 L2 count 到 L1

### 6. l10n 新增 key（4 语言）

`analyticsWeek`(周)、`analyticsWeekExpense/WeekIncome`(本周支出/收入)、`analyticsComparedToLastWeek`(比上周)、`analyticsCategoryComposition`(分类构成)、`analyticsMainCategory/SubCategory`(主分类/子分类)、`analyticsTxCountShort`({count}笔)、`analyticsTrendTitle`({period}趋势)、更新 `analyticsTipHeader` 含「周」；运行 `flutter gen-l10n` 重新生成

### 性能与回归控制

- 周报不新增查询类型，与月报同为一次 `totalsByDay` + 一次分类聚合 + 笔数 count 聚合，复杂度 O(n) 不变
- 分类笔数在既有循环内累加，不引入 N+1
- LineChart/饼图改动全部以可选参数增量扩展，资产卡等其他调用方行为不变
- 横滑手势、空态、外币横幅、hideAmounts 路径保持原逻辑

## 目录结构

```
lib/
├── utils/
│   ├── week_range.dart                    # [NEW] 周周期工具：weekRangeFor/weekLabel/前后周偏移，半开区间约定与 month_range 一致
│   └── format_utils.dart                  # [MODIFY] 新增 formatCompactAxis（中文万/英文 k/M/B 的轴标签缩写），供图表 Y 轴/tooltip/badge 复用
├── pages/main/
│   └── analytics_page.dart                # [MODIFY] 核心改造：'week' scope 及时间范围/同比/series 分支；顶部四段 scope 胶囊+周期导航行+三段 type 胶囊（删 _showTypeMenu）；分类区改为环形图+排行榜常驻+主/子分类切换；周报分享回退月报海报
├── widgets/
│   ├── analytics/
│   │   ├── analytics_summary.dart         # [MODIFY] 周报标签（本周支出/比上周等）；四格金额统一 useCompactFormat + 溢出兜底；样式保持现有 marker 竖条克制风格
│   │   └── category_rank_row.dart         # [MODIFY] 增加排名序号、笔数文案、按索引取调色板颜色（进度条/图标圈与环形图一致）、金额 compact
│   └── charts/
│       ├── line_chart.dart                # [MODIFY] 可选 smooth 曲线、showYAxisLabels（formatCompactAxis）、onPointTap 点按气泡回调；全部默认参数向后兼容
│       ├── analytics_bar_chart.dart       # [MODIFY] 卡片标题行+主题色汇总 badge；leftTitles 用 formatCompactAxis；圆角微调
│       └── category_pie_chart.dart        # [MODIFY] 外置标签（badgeWidget 外移）、导出调色板供排行榜共享、支持子分类打平数据源
├── data/repositories/
│   ├── statistics_repository.dart         # [MODIFY] totalsByCategoryWithHierarchy 返回 record 增加 count 字段
│   └── local/
│       ├── local_statistics_repository.dart # [MODIFY] 聚合循环内同步累加 count
│       └── local_repository.dart          # [MODIFY] 门面签名同步
├── l10n/                                  # [MODIFY] app_zh/app_zh_TW/app_en/app_ko.arb 新增约 10 个 key + gen-l10n 重新生成 4 个 app_localizations_*.dart
└── test/
    ├── week_range_test.dart               # [NEW] 周区间边界（跨月/跨年/周一起始）单测
    └── format_utils_compact_axis_test.dart # [NEW] 大金额缩写（万/k/M、负数、边界值）单测
```

## 设计风格

参考截图的报表式布局，但克制收敛：白底圆角卡片（radius2xl，无阴影）、浅灰页面背景、主题色作为唯一强调色（跟随用户主题色，非固定蓝）。亮暗模式自适应。

## 页面结构（单页垂直滚动，自上而下）

1. **顶部区**：PiggyHeader 内标题行（图标+周期文案+分享）→ 四段周期胶囊（周/月/年/全部）→ 周期导航行：‹ 范围文案 › 居左，支出/收入/结余三段小胶囊居右
2. **汇总卡**：2×2 网格，每格左侧 3px 主题色竖条 marker，灰色小标签（11px）+ 22px/18px 粗体金额；正负语义色（结余正绿负红，遵循用户红绿方案）
3. **趋势折线卡**：卡片标题（如「本周趋势」）+ 平滑曲线 + 左侧 Y 轴大金额缩写（3.1万）+ 点按气泡 tooltip（主题色底白字）
4. **趋势柱状卡**：标题 + 右上角主题色 badge（¥4.59万 + 周期范围）；圆角柱，高亮柱不透明、其余 35% 透明
5. **分类构成卡**：标题 + 右侧主分类/子分类小胶囊；环形图外置标签（名称+百分比）
6. **排行榜**：序号（前三名主题色）、圆形分类图标、名称+笔数、彩色细进度条（颜色与环形图扇区一致）、右侧百分比+紧凑金额+›

## 交互

- 横滑图表切周期、横滑页面切收支视角（保留现有手势）
- 胶囊切换带滑动动画（复用 WaitSlidingSegmentedControl）
- 折线点按出现气泡，再次点击/滑动消失

## Agent Extensions

### SubAgent

- **code-explorer**
- Purpose: 实施前核查 LineChart/CategoryPieChart 的全部调用方与 l10n 生成命令，确认新增可选参数的兼容性边界
- Expected outcome: 产出调用方清单与兼容性结论，确保图表 API 扩展零回归