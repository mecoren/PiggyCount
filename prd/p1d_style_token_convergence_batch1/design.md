# P1-D 样式令牌收敛第一批 — 设计文档

## 一、需求理解

把 charts/posters/personalize 三处硬编码颜色与 charts 硬编码字号收敛到既有
令牌层（lib/styles/tokens.dart），消除同语义多取值的漂移；海报因导出图片属性
需静态令牌而非主题响应令牌。纯收敛性重构，唯一视觉变化是 annual_report 海报
收入绿/支出红向家族多数值看齐（已经用户确认）。

## 二、关键技术决策

### 决策 1：色板迁入 PiggyChartTokens.seriesColors（而非新文件）

- PiggyChartTokens 已是图表专属令牌家（lineWidth/dotRadius/xLabelFontSize），
  色板语义同属图表域；避免再造平行体系。
- `kAnalyticsPieColors` 直接删除（仅 2 个消费方，无兼容包袱）。

### 决策 2：PiggyPosterTokens 独立成类、全静态

- 海报经 `RepaintBoundary.toImage(pixelRatio: 3.0)` 导出 PNG 分享，必须与
  App 明暗模式/主题色无关（primaryColor 由调用方作参数传入，其余色全静态）。
- 不能复用 PiggyTokens 的 context 方法（那些走 Theme 查询暗色适配）。
- 与 PiggyDimens（已静态、海报已大量使用）同一设计哲学，放同一文件
  tokens.dart，保持令牌单文件可检索。

### 决策 3：海报色值取「家族多数值」

- 收入绿 `0xFF51CF66`（month/year/ledger 3 票 vs annual 4CAF50 1 票）；
  支出红 `0xFFFF6B6B`（3 票 vs FF5252 1 票）。
- 少数服从多数，annual_report 被对齐——差异肉眼可辨但同族，换来全家族一致。

### 决策 4：图表字号用「语义槽位」而非逐值映射

PiggyChartTokens 新增（均为 double，静态）：

| 槽位 | 值 | 语义 |
|------|----|------|
| tooltipFontSize | 11 | 气泡提示文字 |
| legendFontSize | 11 | 图例行/饼图中心标签 |
| sectionTitleFontSize | 14 | 「资产构成/余额趋势/分类占比」区块标题 |
| titleFontSize | 15 | analytics_bar_chart 图表标题 |
| centerValueFontSize | 16 | 环形中心金额 |

- 存量 xLabelFontSize(10)/yLabelFontSize(10) 覆盖轴标签与外置标签。
- 交互态放大表达为 `PiggyChartTokens.xLabelFontSize + 2`（意图显式、
  随基准联动），不新增孤值槽位。
- 11 与 tooltip/legend 分开命名：两个角色允许未来独立调参。

### 决策 5：默认主色常量放 PiggyPersonalizeDefaults

- `personalize_page` 的选项列表依赖 l10n（BuildContext）不能整体常量化，
  但默认主色值可以：新 `lib/styles/personize_defaults` 不值得——直接放
  tokens.dart 同文件的顶层小类 `PiggyPersonalizeDefaults.defaultPrimaryColor`。
- theme_providers 的 primaryColorProvider 默认值与 personalize 首选项改引
  同一常量，注释说明联动关系（删除旧的双处注释）。

## 三、实现步骤

1. tokens.dart：PiggyChartTokens 增 seriesColors + 5 个字号槽位；文件尾部
   增 PiggyPosterTokens 与 PiggyPersonalizeDefaults。
2. charts 改造：category_pie_chart 删本地色板改引令牌；8 个图表文件的
   Color(0x…)/fontSize 字面量按语义槽位替换（色板外的 charts 硬编码色
   经勘察仅 category_pie 一处 12 色，其余图表文件颜色已走 PiggyTokens）。
3. posters 改造：6 张海报的语义色/文字三级色/奖牌色/徽章底色改引
   PiggyPosterTokens（annual_report 的 4CAF50/FF5252 一并对齐多数值）。
4. personalize + theme_providers：默认主色改引共享常量；补选项数据注释。
5. 验证：flutter analyze → charts/posters 相关 widget 测试 → 全量 flutter test
   → grep 复核验收标准（kAnalyticsPieColors 零命中、0xFF497FF8 唯一等）。

## 四、边界条件与风险

| 风险 | 缓解 |
|------|------|
| annual_report 绿/红取值变化用户可感 | 幅度小且同族；已作为需求决策项请用户确认 |
| 海报静态令牌误被传 context 用法 | PiggyPosterTokens 无 context 参数，编译期即阻断 |
| 图表字号替换引入视觉回归 | 槽位值与原字面量逐一相等（纯改名）；测试 + 真机抽查海报 |
| tokens.dart 体量增长 | 约 +45 行，仍在单文件可检索范围；后续批次再议拆分 |
| 奖牌/深墨色仅 annual 单处使用 | 仍入令牌——user_profile 金色 0xFFFFD700 与 annual 重复，已有第二消费方 |
