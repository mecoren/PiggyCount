# P1-D 样式令牌收敛第一批（charts / posters / personalize）— 需求文档

## 一、背景

优化评估报告（docs/optimization-assessment-report/optimization-assessment-report.html，建议 8）指出：

1. **硬编码颜色集中在三处**：`lib/widgets/charts` + `lib/widgets/posters` 共约 87 处
   `Color(0x…)`，`personalize_page.dart` 29 处；这些值绕过令牌系统，同语义颜色
   在不同文件各自为政。
2. **本批范围内硬编码字号**：charts 17 处、posters 116 处 `fontSize:` 字面量。
3. 本次勘察发现的**实际漂移证据**（比数量更有说服力）：
   - 「收入绿」annual_report 用 `0xFF4CAF50`，month/year/ledger 三张海报用
     `0xFF51CF66`；「支出红」annual 用 `0xFFFF5252`，其余用 `0xFFFF6B6B`——
     同一语义两种取值，海报间视觉不一致。
   - 12 色分类调色板 `kAnalyticsPieColors` 定义在 category_pie_chart.dart，
     analytics_page 排行行复用——图表语义色板的单源应落在 PiggyChartTokens。
   - 默认主色 `0xFF497FF8` 在 personalize_page（首选项）与
     theme_providers.dart（primaryColorProvider 默认值）两处重复定义，仅靠注释
     维系同步。

## 二、需求范围

### R1 图表系列色板单源化

- `kAnalyticsPieColors`（12 色）迁入 `PiggyChartTokens.seriesColors`，
  两个使用方（category_pie_chart、analytics_page）改为引用令牌。
- 色值不变，纯位置收敛。

### R2 海报语义色收敛（主要收益项）

- 新增 `PiggyPosterTokens`（静态、非主题响应——海报经 RepaintBoundary.toImage
  导出为分享图片，必须与 App 明暗模式无关；PiggyDimens 静态令牌已是先例）：
  - 收入/支出语义色 + 徽章底色；
  - 海报文字三级色（主 `0xFF333333` / 次 `0xFF666666` / 弱 `0xFF999999`）；
  - 奖牌金/银/铜；年度海报深墨色标题。
- 6 张海报的散落字面量全部改引令牌。
- **有意取舍**：annual_report 的收入绿/支出红从 `4CAF50/FF5252` 统一到
  家族多数值 `51CF66/FF6B6B`（轻微视觉变化，换来跨海报一致）。

### R3 图表字号令牌化（仅语义清晰处）

- `PiggyChartTokens` 补齐语义字号槽位（tooltip/图例/区块标题/图表标题/中心数值），
  charts 17 处字面量中语义明确的改引令牌；交互态偏移（如触摸放大 +2）表达为
  `xLabelFontSize + 2`。
- line_chart 已用变量（yLabelFontSize-1 偏移），不动。

### R4 personalize 审计结论 + 默认主色单源

- 29 处 `Color(0x…)` 审计结论：**28 处为主题色板选项数据**（用户可选值本身，
  非样式违规），不迁移；补注释说明数据属性。
- 1 处真实问题：默认主色与 `primaryColorProvider` 默认值重复定义——提取共享常量
  `PiggyPersonalizeDefaults.defaultPrimaryColor`，两处引用同一常量。

## 三、验收标准

### AC-R1

- `rg "kAnalyticsPieColors" lib` 零命中；色板唯一来源 PiggyChartTokens.seriesColors。

### AC-R2

| # | 场景 | 预期 |
|---|------|------|
| 1 | 海报内收入/支出色 | 全部海报取同一令牌值（51CF66 / FF6B6B） |
| 2 | 海报文字三级色 | 333333/666666/999999 各自从令牌取 |
| 3 | 令牌静态性 | PiggyPosterTokens 无 BuildContext 依赖（导出图片不随明暗模式变） |
| 4 | annual_report 视觉 | 收入绿/支出红与 month/ledger 海报一致（已知轻微变化，经用户确认） |

### AC-R3

- charts 内 `fontSize: [0-9]` 字面量仅剩交互态表达式（如 `+ 2`）或 PiggyChartTokens
  已有槽位无法覆盖的孤例（预期 ≤2 处，逐处注释原因）。

### AC-R4

- `0xFF497FF8` 全库唯一出现位置为共享常量定义处；personalize 首选项与
  primaryColorProvider 默认值均引用它。

### AC-通用

- `flutter analyze` 无新增 error/warning。
- 相关 widget 测试（charts/posters 涉及面）+ 全量 `flutter test` 通过。

## 四、非目标

- **海报 fontSize 不收敛**：海报是 750px 定宽画布的排版作品，字号（10–100）是
  版面设计值而非 App 排版语义；强行映射 PiggyTextTokens（14/15 尺度、主题色）
  会破坏海报版式。后续若需统一，应建海报专用字阶，属下一批。
- 不处理 tokens.dart 既有静态亮色常量（primaryTextStatic 等 546–576 行）——
  需先确认其消费方是否已全部迁移，另开批次。
- 不做评估报告「图表响应式/折叠屏适配」项（另一独立专项）。
- pages 全量 338 处 fontSize 治理不在本批（第一批仅 charts/posters/personalize）。
