# 洞察时间维度枚举化重构 — 设计文档

> **状态：已落地**（2026-10-13）
> 门禁结果：`flutter analyze` 0 issue；全量 `flutter test` 2338 绿（含
> `test/utils/analytics_scope_test.dart` 22 个特征测试）；grep 证 `'week'/'month'/'year'/'all'`
> 字面量在点名文件零残留（剩余命中均为「未纳入」清单内文件）；`git diff --stat` 波及面
> 仅限本批点名文件，无 format 噪音。
> 唯一偏差（对 requirements.md 验收项 4）：`analytics_page_test.dart` 的 1 处 finder 从
> `find.byType(WaitSlidingSegmentedControl<String>)` 改为无泛型 `is` 谓词——scope 分段控件
> 枚举化后泛型参数变 `AnalyticsScope`，byType 精确 runtimeType 匹配兜不住两种实例化。
> 这是 finder 对类型变更的机械适配，**断言语义不变**（仍为「两个分段控件原地保留」），
> 其余断言逐字未动。

落地点：`lib/utils/analytics_scope.dart`（新建）、`lib/pages/main/analytics_page.dart`、
`lib/widgets/analytics/analytics_summary.dart`、`lib/widgets/analytics/category_rank_row.dart`、
`lib/pages/report/range_report_page.dart`（一处调用点）、`test/utils/analytics_scope_test.dart`（新建）。
**不动数据层**：`StatisticsRepository` / 查询 / U8 记忆化缓存逻辑零改动。

## 一、关键技术决策与理由

### 1. 用 Dart `enum` + 穷尽 switch，而不是常量字符串类

项目已有两种先例：`CustomFieldType` 是字符串常量类（`custom_field_values.dart:8`），
本场景选 `enum`。理由：scope 是**封闭集合**且大量参与分支；enum + 无 `default` 的
穷尽 switch 能把「新增档位漏改一处」从**静默错分支**变成**编译错误**——这正是本轮
可扩展性收益的全部落点。`CustomFieldType` 用字符串是因为它要落库、要向前兼容新类型，
场景不同。

### 2. 枚举与纯函数层放 `lib/utils/analytics_scope.dart`

与 `week_range.dart` / `month_range.dart` / `analytics_average.dart` 同层（周期算术的
既有归属），无 UI / Provider 依赖，pages 与 widgets 都可引用，纯函数可直接单测
（与 `range_report_page.dart:53-54`「窗口算术做 static 为可测」同一哲学）。

### 3. 周期计算收拢为注入式纯函数，返回 record

```dart
typedef AnalyticsPeriodRange = ({
  DateTime start,
  DateTime end,
  DateTime? prevStart,
  DateTime? prevEnd,
});

AnalyticsPeriodRange resolveAnalyticsPeriod(
  AnalyticsScope scope, {
  required DateTime anchor,   // 周=_selWeek(周一标签)；月/年=selMonth
  required int startDay,      // 账本 monthStartDay
  required DateTime now,      // 注入，测试可控
});
```

- record 是仓库既有惯用形状（repo 返回值全是 record）；`prevStart/prevEnd` 可空对应
  「全部视角无上期」。
- `now`/`startDay` 注入而非内部读 Provider：这是 `build` 里最易算错、又完全可以用纯函数
  测试钉住的部分（同 range_report 的 `momWindow/yoyWindow` 决策）。
- 导航步进同理：`DateTime? nextAnchor(scope, anchor, now)` / `DateTime? prevAnchor(scope, anchor)`，
  返回 null = no-op（全部视角 / 前进被钳制）；**状态写回仍留在页面**
  （周→`_selWeek`、月/年→`selectedMonthProvider`，这是页面状态所有权，不进纯函数层）。

### 4. 分段控件直接用泛型枚举，无字符串桥

`WaitSlidingSegmentedControl<T>` 已是泛型（`wait_sliding_segmented_control.dart:14`），
`WaitSlidingSegment<AnalyticsScope>` + `selected: _scope`（枚举）即可，`value ==`
用 enum 自然相等，不需要 `parse`/`name` 转换层。

### 5. 两个共享 widget 的 `scope` 参数同步改枚举类型

只改洞察页内部、widget 仍收字符串的话，字符串泄漏原样留着，穷尽性收益在边界处断掉。
改动：

- `AnalyticsSummary.scope` → `AnalyticsScope`：`_avgLabel` / 周标题 / 「较上周|较去年」
  三处 switch 改穷尽 switch 表达式（`analytics_summary.dart:90-99, 113, 173-175`）。
- `CategoryRankRow.scope` → `AnalyticsScope`：`scope != 'all'` 两处（`:107, 116-117`）与
  `_currentPeriodLabel` switch（`:124-133`）改枚举；`selMonth` 等其余参数不动。
- `range_report_page.dart:573` 的 `scope: 'month'` 权宜值改为 `AnalyticsScope.month`，
  **原注释保留**（它是「任意区间被塞进月档位」的既成事实说明，删注释会让后人看不懂
  为什么是 month）。根治（`includeRange` + 显式标签语义）留待后续批次。

## 二、改动面盘点（8 处分支簇，全部在 analytics_page.dart）

| # | 分支簇 | 位置 | 收拢方式 |
|---|---|---|---|
| 1 | 选期器（周=ymd / 月=ym / 年=y / all=无） | `:95-133` | 留页面（UI 型），switch 改枚举穷尽 |
| 2 | 左右滑/箭头切周期 + 钳制 | `:257-302` | `nextAnchor/prevAnchor` 纯函数 |
| 3 | 导航行周期文案 | `:330-342` | switch 改枚举穷尽、删 `default` |
| 4 | `start/end` + 「当前周期截断」 | `:403-435` | `resolveAnalyticsPeriod` |
| 5 | 上期窗口 `prevStart/prevEnd` | `:438-451` | 同上（同函数返回） |
| 6 | 取数路由（day/month/yearSeries）+ 图表 6 桶窗口 | `:470-521` | `AnalyticsSeriesKind` getter + 窗口起点纯函数 |
| 7 | 图表桶聚合选择 / x 标签 / lineTitle / 高亮 / prevTotal | `:1013-1114, 1177` | switch 改枚举穷尽 |
| 8 | 分享海报分支（周→回退月报 / 月→月报 / 年→年报 / all→账本报） | `:597-635` | switch 改枚举穷尽（**保留周回退月报语义**） |

另有 3 处类型接缝：`_scope` 声明（`:37`）、分段控件（`:652-674`）、widget 传参
（`:1168, 1399`）。memoKey 由 `start/end/refreshTick/ledgerId` 拼成（`:462-464`），
与 scope 字符串无关，**不动**。

## 三、为什么这样收拢（而不是抽个 Strategy 类）

四档位的差异是**计算参数**（窗口、粒度、钳制），不是**行为族**——没有插件化需求，
Strategy/注册表是过度设计（可扩展性评估也已判定「插件机制不建议做」）。函数级纯层 +
穷尽 switch 已满足「新增档位编译期强制补全」；若未来真加「自定义」档位，它需要的是
**锚点携带起止日期**这种数据变化，在枚举 + record 参数形状上扩展即可。

## 四、行为冻结清单（现状的不一致，原样保留）

这些是**现状口径**，重构必须逐值保持，测试逐条钉住，严禁「顺手统一」：

1. 「当前周期」判定口径不一致：月视角用**周期标签相等**（`labelForDate(now, sd)`，
   `:420-422`——6/5 在起始日 10 时属 5 月周期）；周/年视角用**区间包含**（
   `!now.isBefore(range.start) && now.isBefore(range.end)`，`:412-413, 428-429`）。
2. 前进钳制口径不一致：周=周标签比较（`nextWeek.isAfter(weekLabelFor(now))`，`:264`）、
   月=自然年月比较（`:270-271`）、年=自然年比较（`:277`）。
3. 上期窗口：周=紧邻上周 `[weekAdd(-1), 本周一)`（`:441-442`）；月=去年**同周期标签**月
   （`:444-446`）；年=去年周期（`:448-450`）；all=null。
4. 周视角分享海报**回退到该周所在月的月报**（`:597-607`），不是周报。
5. all 视角：`prevTotal` 传 null → 摘要卡第二格显示**记账笔数**（`:1177`、
   `analytics_summary.dart:172-184`）；图表不高亮（`:1083`）；无上期、无选期器。
6. 「当前周期只到今天」的 `end = today.add(Duration(days: 1))`（半开区间右端），四档位
   共用此截断语义。

## 五、实现步骤（≤5 步，TDD 顺序）

1. **先落特征测试**（红→绿的「红」对纯重构即钉现状）：新建
   `test/utils/analytics_scope_test.dart`，按 §四清单逐条写断言（对**现有实现**可先写成
   对 `weekRangeFor/periodForLabel/yearRangeFor` 的手工推导值断言），随后新建
   `lib/utils/analytics_scope.dart` 让测试过。
2. `analytics_page.dart`：`_scope` 换 `AnalyticsScope`，按 §二盘点表逐簇收拢
   （4/5/6 簇调纯函数，1/3/7/8 簇改穷尽 switch、删 `default`），分段控件换泛型枚举。
3. 两个共享 widget 参数改枚举 + `range_report_page.dart:573` 调用点适配（保留注释）。
4. 门禁：`flutter analyze` 0 issue、全量 `flutter test` 绿（既有
   `analytics_page_test.dart` 不改断言）、grep 验证 `'week'|'month'|'year'|'all'` 字面量
   在点名文件零残留；`git diff --stat` 核对波及范围防 format 噪音（见项目记忆踩坑记录，
   **不得跑 `dart format .`**）。
5. 回填 prd 文档落地状态（本文件页眉标注「已落地」+ 门禁结果）。

## 六、边界条件与风险

- **最大风险是「重构顺手改口径」**：§四 6 条全部是易被当成 bug 的现状（尤其 1、2 的
  口径不一致与 4 的海报回退）。对策：特征测试先行 + 代码评审只看「行为 diff 为零」。
- `build` 里的 8 簇与 `_rememberAnalyticsFuture` 缓存深度交织（`:459-531`），收拢取数路由
  时**不得**改变「memoHit 时闭包不执行」语义，否则退化回 P1 修复前的白发查询。
- `CategoryRankRow` 是 `ConsumerStatefulWidget` 且被 range_report 共用，参数类型变更必须
  两处调用点同批改完，否则编译失败（这恰是枚举化的收益，但批内要一次过）。
- widget 测试注意「A Timer is still pending」坑（项目记忆）：settle 辅助函数末尾
  `tester.pump(const Duration(seconds: 3))` 推完 Logger 节流定时器。
- 本轮不碰 `List<dynamic>` 位次传递与卡片清单；`_getSumFromSeries`（`:382-393`）的
  record 类型分派保留原样（它按数据形状而非 scope 分支，不在本批）。
