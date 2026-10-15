# 洞察模块自定义字段统计全链路 — 设计文档（实现计划）

> **状态：已落地**（2026-10-13 拟稿，2026-10-14 阶段 1-5 全部完成：全量回归
> 2452 例绿 + analyze 0 issue + MuMu 真机逐项验收 + 上线校验清单 10/10 核毕）。
> 对应 `requirements.md`。按 §三 阶段划分落地开发（TDD 顺序，每阶段独立门禁）。
>
> **落地偏差说明**（与拟稿不一致处，以实际实现为准）：
> 1. **CSV 编码复用 `package:csv`**（§一.5 原写「不引入第三方 CSV 依赖手写 30 行」）：
>    实际复用项目既有 `package:csv` 的 `Csv(lineDelimiter: '\n').encode(rows)`
>    （与 export_page 账本 CSV 同一依赖），`csv_builder.dart` 只做单元格公式
>    注入转义 + BOM 前置，避免手写 CSV 转义规则与既有导出格式分叉。
> 2. **分布档标签 `distLabel` 收敛为 `AmountFieldStats.distLabel` 静态方法**：
>    UI 分布行与聚合 CSV「统计项」列共用同一标签函数，消除「界面 ≥10000、
>    导出 10000+」分叉风险。
> 3. **明细导出口径**：聚合与明细同源过滤（半开区间 `[start, end)` +
>    `excludeFromStats=0`）；`getTransactionsByDateRange` 为闭区间 BETWEEN，
>    页面内收口过滤保证两份 CSV 口径一致。
> 4. **聚合 CSV 金额列格式**（真机验收发现）：数值/收入/支出列统一
>    `toStringAsFixed(2)` 两位小数文本（与明细 CSV 金额列同口径），避免
>    浮点尾差（如 `144.76999999999998`）落进 Excel 且两份导出不一致；
>    笔数列保持 int。

## 一、关键技术决策与理由

### 1. 统计口径分层：旧值桶输出冻结，新口径按类型追加

- `CustomFieldStatsService` 现状输出（值桶：label/笔数/收入/支出）**逐值保留**
  ——洞察页卡片、区间报表共用它，冻结即零回归（R1）。
- 新增 `CustomFieldStats` 字段级汇总（`sum/avg/min/max`、填写率、时间分布序列、
  值桶列表），由同一遍内存聚合顺带产出（一次取行、一趟循环，延续
  `customFieldStatsRows` 无 N+1 的范式，R2）。
- 金额口径用 `nativeAmount`（与分类统计同源）；时间分布的桶粒度固定**按月**
  （分析页默认粒度，避免粒度配置化过度设计）。

### 2. 分类型统计用 sealed 结果包（延续 InsightsData 范式）

```dart
sealed class FieldStats { final String fieldSyncId; final String name; final String fieldType; final int filledCount; final int totalCount; }
// AmountFieldStats: sum/avg/min/max + 分布桶 List<(label, count, amount)>
// DateFieldStats:   按月序列 List<(month, count, amount)>（图表直接消费）
// TextLikeFieldStats: 值桶 List<(label, count, amount, ratio)>（text/singleSelect/multiSelect 共用）
```

- 形状即类型，`switch` 穷尽匹配编译期强制补全（R3 约定同款：不加 default）。
- text/singleSelect/multiSelect 共用 `TextLikeFieldStats`：三者数据形状相同，
  区别仅在值来源（单值/逐选项拆桶/文本原文），形状上无差异，不强造三类。

### 3. 下钻页路由与数据自取

- 新页 `lib/pages/analytics/custom_field_analysis_page.dart`：
  `CustomFieldAnalysisPage(start, end, type, fieldSyncId?)`——区间/视角从洞察页
  带入（与卡片参数同构），fieldSyncId 可选（默认第一字段）。
- 数据经 `customFieldStatsDetailProvider`（family：ledgerId+start+end+type+
  refreshTick）自取，与 `customFieldStatsForRangeProvider` 同款缓存语义。
- 下钻明细：**复用现有明细列表组件 + 筛选模型**加字段值条件，不开新明细页。

### 4. 筛选模型扩展方式

- 现有交易筛选模型增加 `customFieldConditions: List<(fieldSyncId, op, value)>`
  （op: eq/between；金额型区间用 between）；解析下沉到查询层一处（避免 UI
  各处自拼 where）。chips 展示与移除逻辑沿用现有筛选 chip 组件范式。

### 5. CSV 生成为纯函数服务

- `lib/services/export/csv_builder.dart`：`List<Map<String, Object?>> rows +
  列定义 → String`，纯函数可单测；**公式注入转义**（=+-@ 开头单元格前置
  `'`）在 builder 内统一处理（R3）。UTF-8 BOM 头 + 系统分享通道导出。
- 不引入第三方 CSV 依赖（列结构简单，手写 30 行足够，YAGNI）。

## 二、模块与文件清单

| 模块 | 文件 | 动作 |
|---|---|---|
| 统计服务 | `lib/services/custom_field_stats_service.dart` | 扩展：字段级汇总 + sealed 结果包 |
| 查询层 | `lib/data/repositories/statistics_repository.dart` | 扩展：字段值筛选查询 |
| 数据包 | `lib/services/custom_field_stats_service.dart`（或独立 model 文件） | 新增 sealed FieldStats |
| Provider | `lib/providers/custom_field_providers.dart` | 新增 detail provider |
| 分析页 | `lib/pages/analytics/custom_field_analysis_page.dart` | 新建 |
| 分类型图表 | `lib/widgets/analytics/field_dist_chart.dart` 等 1-2 个 | 新建（复用 LineChart/条形范式） |
| 洞察卡入口 | `lib/widgets/analytics/custom_field_stats_card.dart` | 小改：加「进入分析」入口（渲染逐像素不动） |
| 筛选 | 明细筛选模型 + 查询层 | 扩展 |
| CSV | `lib/services/export/csv_builder.dart` | 新建纯函数 |
| 字段管理 | `lib/pages/settings/custom_field_manage_page.dart` | 小改：「已填写 n 笔」计数 |
| l10n | 4 个 arb + generated | 新增文案 |
| 测试 | services/providers/widgets/csv/页面 测试文件 | 新建/扩展 |

**不动**：`analytics_page.dart` 注册表与数据包（分析页自取数据，不并入主链路）、
洞察卡现有渲染、数据表结构（字段值存储现状满足需求，零迁移）。

## 三、阶段划分（TDD，每阶段独立门禁）

### 阶段 1 统计服务分类型口径（核心，先行）

1. RED：`custom_field_stats_service` 分类型特征测试——金额型 sum/avg/min/max/
   分布、日期型按月序列、文本/单选/多选值桶与填写率、多选拆桶、空值不计入
   分子、旧值桶输出逐值兼容（冻结回归）。
2. GREEN：sealed `FieldStats` + 一趟聚合扩展，旧输出不动。
3. 门禁：`flutter analyze` 0 issue + 相关测试绿 + 旧测试零改动。

### 阶段 2 分析页 + 下钻（可视化）

1. RED：分析页 widget 测试（字段切换 chips、分类型渲染、结余隐藏、空态、
   下钻跳转参数）。
2. GREEN：`custom_field_analysis_page.dart` + 分类型图表 widget + 洞察卡入口。
3. 门禁：analyze + 测试绿 + 洞察页既有测试零改动（树形红线）。

### 阶段 3 字段值筛选（下钻即筛选）

1. RED：筛选模型字段值条件单测（eq/between、chips 移除、与现有条件正交）。
2. GREEN：筛选模型扩展 + 查询层解析 + 下钻联动 + chips UI。
3. 门禁：既有筛选测试断言零改动全绿。

### 阶段 4 导出（双份 CSV）+ 配置侧小增强

1. RED：`csv_builder` 纯函数测试（列序、中文、BOM、公式注入转义、空值）+
   聚合/明细两份导出内容测试。
2. GREEN：builder + 分析页导出按钮（分享通道）+ 字段管理页计数。
3. 门禁：analyze + 测试绿。

### 阶段 5 全量回归 + 真机验收

1. 全量 `flutter test`（既有断言零改动）+ `flutter analyze` 0 issue。
2. 真机（MuMu 127.0.0.1:16384 dev flavor）五类字段逐一目检 + 下钻 + 导出
   文件打开验证 + 结余隐藏口径。
3. 回填本页眉「已落地」与偏差说明。

## 四、测试验证标准

- **特征测试先行**：金额四指标、日期月分布、填写率、多选拆桶、旧值桶兼容
  都要有钉死用例（数值可断言，不靠目检）。
- **既有断言零改动**：全量测试红了先怀疑行为被改，禁止改断言迁就实现。
- 每阶段门禁 = `flutter analyze` 0 issue + 该阶段测试绿 + 波及面 grep/
  diff 核对（不得跑 `dart format .`）。
- widget 测试注意「A Timer is still pending」坑（收尾 `tester.pump(3s)` 或
  ProviderScope 注入 `currentLedgerProvider`）。
- 导出验收：真实文件生成 → 用 Excel/记事本打开验证中文与列数。

## 五、上线校验清单（release 前逐项勾选，2026-10-14 全部核毕）

1. [x] 五类字段分类型统计口径与 F1 表逐项一致（测试证据）。
   证据：`custom_field_stats_service_test` 分类型特征 + `custom_field_stats_csv_test`（金额四指标/5 档、日期月行、文本系值排行）全绿。
2. [x] 下钻链路：洞察卡→分析页→值筛选明细，全程可达、条件可移除。
   证据：`custom_field_analysis_page_test` 下钻参数用例 + 真机「RunS: r ×」chip 直达明细 1 条、chip 可移除。
3. [x] 聚合/明细 CSV 双份导出成功、中文无乱码、公式注入转义验证。
   证据：`csv_builder_test`（=+-@ 转义）+ `custom_field_stats_csv_test`；真机导出文件头 `EF BB BF` BOM、11 列/21 行明细与 UI 吻合。
4. [x] 结余视角隐藏、空态、含外币折算文案与现状口径一致。
   证据：真机结余视角滚动到底无自定义字段卡；「无定义/无人填写」空态用例绿；折算文案沿用现状（本需求零改动）。
5. [x] 全量 `flutter test` 绿（既有断言零改动）+ `flutter analyze` 0 issue。
   证据：2451 例全绿（1 skip）+ `No issues found!`。
6. [x] l10n 四语言（zh/zh_TW/en/ko）齐全，无硬编码文案。
   证据：grep 硬编码中文零命中；新增键四 arb 齐全已 gen-l10n。
7. [x] 真机目检（MuMu）：分析页图表、下钻、筛选 chips、导出分享全链路。
   证据：MuMu 127.0.0.1:16384 逐项目检（金额四指标/分布、日期趋势、值排行、导出菜单/分享、下钻 chip）。
8. [x] 性能抽验：4 万交易数据集分析页首开无卡顿（聚合一趟完成）。
   证据：`custom_field_stats_perf_test`（4 万行 × 5 字段种子数据）——聚合
   一趟完成 **192ms**（时限 5s 只拦病态复杂度），且求和/填写率/值桶计数与
   逐行期望精确一致（性能优化不换口径）；真机大账本分析页首开流畅。
9. [x] 同步/备份不受影响（本批零表结构迁移，快照导出无变化）。
   证据：`schemaVersion` 仍 57（v57 为前批必填字段迁移），本需求未触碰迁移/快照/指纹代码；全量回归绿。
10. [x] 既有可访问性要求覆盖新交互元素（Semantics，项目约束）。
    证据：下钻可点行（值排行行+分布档行）补 `Semantics(button:true, label)`（与洞察卡入口同规格），
    `custom_field_analysis_page_test`「下钻可点行带 button Semantics」用例绿。

## 六、边界条件与潜在风险（同 requirements.md §六，实现侧补充）

- 聚合扩展注意**不改变旧输出顺序**（按字段定义顺序、值桶 topN=8+其他）。
- 分析页数据自取失败：落日志不渲染（附属卡失败不拖垮主链路范式），禁空 catch。
- 导出文件走系统分享（临时文件用完清理，延续「临时脚本/文件不残留」约束）。
