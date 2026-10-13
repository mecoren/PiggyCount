# 需求文档：洞察卡片注册表 + 命名数据包（缺口②）

> **状态：待评审**（2026-10-13 拟稿）
> 批次序列：可扩展性路线图「先③后②」——本批为②（结构重构），前置批
> `prd/analytics_custom_field_card/`（③自定义字段卡片）先落地，本批把它收编进注册表。
> 前置已落地：`prd/analytics_scope_enum_refactor/`（枚举 + 纯函数层，穷尽 switch）。

## 一、需求理解

对洞察页做一次**纯结构重构**：把 `List<dynamic>` 位次数据包换成命名（类型化）数据包，
把硬编码的卡片清单换成数据驱动的卡片注册表。行为零变化，收益是「位次越界/跨形状串数据」
从运行时静默错值变成**编译期不可能**，以及新增卡片只需在清单加一项。

## 二、背景与用户价值

- 现状债务（代码自认）：主数据是 `(String, List<dynamic>)`，收支口径 6 位、结余口径
  9 位**两套位次表**（`analytics_page.dart:1531, 1581` 位次注释），`:68` 注释明说
  「跨口径复用会读到 list[7] 越界」，`:1038` 用 `list[list.length - 1]` 隐式约定
  「最后一位=图表序列」；`_getSumFromSeries`（`:435-446`）按 record 形状逐个 `is`
  分派。每次动数据都要人工对位次，是页面最大的误改风险源。
- 卡片清单直接写死在 `ListView(children:…)`（`:1237-1503`）：摘要卡、趋势卡、
  分类构成、排行榜（+③批的自定义字段卡），新增/隐藏卡片要进大 build 手术。

## 三、功能范围

### F1 命名数据包（替代位次表）

- 引入 `sealed class InsightsData` 两个子类：
  - `InOutInsightsData`：分类聚合、主序列、笔数、本期收支、上期收支、图表序列；
  - `BalanceInsightsData`：分类聚合、结余序列、支出笔数、收入序列、支出序列、
    收入笔数、上期收支、图表序列。
- `_loadCategoryData` / `_loadBalanceData` 返回值从 `List<dynamic>` 改为上述类型；
  build 内 `list[0]…list[8]` 全部改命名字段读取；`:1038` 的
  `list[list.length - 1]` 隐式约定消失（chartSeries 成命名字段）。
- 在途复用的 shape 标签语义（`_shapeOf` + `tag.$1 == _shapeOf(_type)`，
  `analytics_page.dart:851-853`）**原样保留**。

### F2 卡片注册表（清单数据驱动）

- `InsightCardDef(id, visible, build)`：卡片清单收拢为**页内静态列表**，
  `ListView` 按注册表渲染（`visible` 谓词过滤 + `build` 产出卡片）。
- 首批注册项：摘要卡、趋势折线/柱状卡、分类构成卡、排行榜卡、自定义字段卡（③批），
  顺序与现状逐项一致；各卡 `visible` 谓词固化现状条件（如分类构成/排行榜/
  自定义字段 = 收支视角才显示）。
- **不做**用户可配置显隐/排序（无持久化设置、无设置页）。

### F3 `_getSumFromSeries` 收编

- 从 State 类方法挪为纯函数（与数据包同文件或 `lib/utils/`），签名收到命名字段上；
  其 day/month/year record 形状分派**保留**（那是数据形状而非 scope 分支，不在本批
  强类型化——见未纳入）。

### F4 行为零变化（冻结清单）

- 空态（`txCount == 0 || (sum == 0 && allZero)` 判定与文案/按钮）、在途复用、
  U8 记忆化缓存（memoHit 时闭包不执行）、横滑切周期、分享海报分支、
  结余视角隐藏分类卡——全部逐值保持。

## 四、验收标准

1. `List<dynamic>` 与 `list[n]` 位次读取在 `analytics_page.dart` **零残留**（grep 可证）；
   `_loadCategoryData/_loadBalanceData` 签名返回命名类型。
2. 卡片清单以注册表形态存在，`ListView` 不再手写 children 序列；五张卡顺序、
   样式、显隐条件与重构前逐像素一致（widget 测试断言不变 + 真机目检）。
3. 既有测试**不改断言**全绿：`analytics_page_test.dart`（含 finder 机械适配说明见
   `analytics_scope_enum_refactor/design.md` 页眉——本批同样只允许 finder 类型适配，
   断言语义零变化）、`analytics_scope_test.dart` 43 例、③批新测试。
4. `flutter analyze` 0 issue；全量 `flutter test` 绿；`git diff --stat` 波及面仅限
   本批点名文件（**不得跑 `dart format .`**）。

## 五、未纳入（明确不做）

- **用户可配置卡片显隐/排序**（持久化 + 设置 UI）：本批只收清单结构，配置化等真实
  需求出现再立项。
- **插件机制 / 二次开发接口**：评估已判定过度设计（`analytics_scope_enum_refactor/design.md` §三
  同结论：封闭成员不做行为族抽象）。
- **series 形状强类型化**（sealed `TotalsSeries` 收编 day/month/year 三种 record）：
  与 scope 正交、波及图表全家桶，收益/风险比不划算，维持 `dynamic` + 形状分派。
- `tag_detail_page.dart` 自有 `_scope` 字符串（语义不同源，属「统一周期语义」批次）。
- 顺手修口径（如导航钳制三口径不一）：行为冻结红线，明确拒绝混入。

## 六、边界条件与潜在风险

- **R1 最大风险是「重构顺手改行为」**：空态判定、在途复用、shape 标签都是性能/体验
  修复的沉淀（`analytics_page.dart:771-780, 846-853` 注释），重构只动结构不动语义；
  对策：既有测试不改断言全绿 + 逐像素对照。
- **R2 widget 树形状**：注册表化不得改变各卡的 widget 树结构（key、包装、顺序），
  否则 `analytics_page_test` 的 finder 会红——红了先怀疑树形变了而不是改 finder。
- **R3 sealed 类型的 switch 面**：build 内按数据形状分派处（如结余/收支两套取数）
  改用 `switch (data)` 穷尽匹配，**不加 `default` 兜底**（沿用枚举化同款约定）。
- **R4 与③批接缝**：`CustomFieldStatsCard`（自取数据）收编为注册表一员，
  `visible` 谓词 = 收支视角；其 provider/渲染零改动。
