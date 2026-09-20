# PiggyCount 优化方案（2026-09-14）——功能 / 性能 / UI / 内存

> 调查基线：commit c807100（v0.7.8，schemaVersion 43），364 个 Dart 文件 / 约 20.4 万行，149 个测试文件。
> 本文档只出方案，不含任何代码改动。所有结论均有 `file:line` 证据。
>
> **⚠️ 执行范围收窄（2026-09-14 第二轮）**：应用户要求，本轮只落地 **UI / 性能 / 内存** 三类优化；第一章「功能补齐」（模板/回收站/报销/债务/结转/规则引擎/储蓄目标等全部 P0-1~P2-11）**不在本轮范围**，方案保留供后续批次参考。已落地项见文末「七、本轮落地记录」。

## 〇、现状小结

**已经做得好的（不需要重复做）**：
- 列表渲染：`FlutterListView` 回收式懒渲染（`lib/widgets/biz/transaction_list.dart:481`），3000 条卡顿问题已修
- 数据库：`NativeDatabase.createInBackground` 后台 isolate（`lib/data/db.dart:1770`）、WAL 默认启用、`idx_transactions_ledger_happened` 复合索引已有（`db.dart:1324` / `:1560`）、N+1 已改批量查询（`getTagsForTransactions` 等）
- 多币种：6 源汇率容灾 + 手动覆盖 + 交易级折算快照
- 迁移：手写 onUpgrade v1→v43 全链路 + 迁移测试（2026-09-19 已到 **v44**，回收站表，见 `optimization-plan-2026-09-19.md` F1-a）
- 汇总类 FutureProvider 已带 key 缓存（analytics_page.dart:37 审计 U8）

**主要短板（本方案的对象）**：
1. 首页数据层是**全账本全量 watch**（不是渲染，是内存与重算）
2. **11 处 `Image.file` 无降采样**，附件原图直读解码
3. 功能面缺交易模板/再来一笔、回收站、报销、借贷、Excel 导出、标签搜索
4. 对照**开源标杆**还缺三件：预算结转（Actual Budget 核心心智，`Budgets` 表无结转字段）、用户可编辑的自动分类规则（Firefly III rules；现状 `category_matcher.dart` 是硬编码关键词表且仅作 AI 兜底）、储蓄目标（Firefly III piggy banks，全库无实体）
5. `IndexedStack` 4 Tab 全量保活、`imageCache` 无上限调优

---

## 一、功能补齐（竞品对照：商业 钱迹 / Moze / 1Money；**开源** Firefly III / Actual Budget）

### P0-1 交易模板 + 「再来一笔」（复制交易）⭐ 最高性价比
- **参考**：钱迹「常用模板」、Moze「交易样板」、1Money「快速重复」
- **现状**：无模板、无复制交易；只有周期账单（`RecurringTransactions`）承担"定期"场景，但"午饭、通勤、房租"这类**不定期重复**没有低成本入口。
- **方案**：
  - 新增 `transaction_templates` 表（字段即 Transactions 列快照 + 排序号，可复用 v42 周期账单模板币种的思路）
  - 记一笔页加「模板」入口：点模板 → prefill 编辑器直接确认
  - 交易列表项**长按菜单 → 再来一笔**：把该笔所有字段（分类/账户/金额/标签/附件开关）prefill 进编辑器，只改日期
  - 不新增独立页面骨架，编辑器复用 `TransactionEditorPage`
- **工作量**：表 + 迁移 v44 + 编辑器 prefill 钩子 + 长按菜单 ≈ 2-3 天
- **价值**：记账 App 留存第一功能——记一笔的摩擦成本直接决定日活

### P0-2 回收站（软删除）+ 删除撤销 Snackbar
- **参考**：钱迹回收站、Moze 最近删除
- **现状**：`deleteTransaction` 是**硬删除**（`local_transaction_repository.dart:579-605`，级联删标签关联、附件文件、共享 override），误删代价大（附件文件也删）；撤销只存在于 AI 对话场景（`ai_chat_page.dart:794`）。
- **方案**：
  - v44 迁移：`transactions` 加 `deleted_at`（NULL = 活跃）；`deleteTransaction` 改写 `deleted_at`
  - 所有查询/统计/预算/同步范围统一加 `deleted_at IS NULL` 谓词（repository 层收口，页面不动）
  - 回收站页：按账本列已删项、单条恢复/清空；30 天自动物理清理（挂进现有 maintenance 服务）
  - 列表删除即时 Snackbar「撤销」（5s 内 UPDATE 回 NULL），**先不做物理删**
  - 同步引擎需对齐：软删行不进同步流（或按删除墓碑语义，与 sync_id 唯一索引兼容，迁移前先做一次小审计）
- **工作量**：迁移 + 查询谓词 + 页面 + Snackbar ≈ 3-4 天（谓词收口是主要成本）

### P0-3 报销标记（待报销 / 已报销）
- **参考**：钱迹报销、Moze 报销管理、Firefly III bill 状态
- **现状**：`Transactions` 只有 `excludeFromStats/excludeFromBudget` 两个布尔（`db.dart:120-169`），无报销概念；"报销"只出现在 AI 提示词示例里。
- **方案**：
  - v44 加 `reimburse_state`（none/pending/claimed，单列而不是布尔，便于以后扩展"报销中"）
  - 记一笔页一个开关；列表项小角标；搜索页/统计页筛「待报销」
  - 报表页加「待报销总额」卡片（SQL SUM 一行的事）
- **价值**：职场用户高频——垫付的钱不记就丢，记了不跟就忘

### P0-4 搜索增强：标签筛选 + SQL 下推
- **参考**：钱迹搜索（备注/金额/分类/标签全维度）
- **现状**：`search_page.dart:206` 与 `:928` 都是 `repo.transactionsWithCategoryAll(ledgerId).first` **全量拉进内存再过滤**（200ms 防抖后仍然全量）；且无标签条件。
- **方案**：
  - 条件构造器下推到 Drift：`WHERE note LIKE ? AND happened_at BETWEEN ? AND ?` + `JOIN transaction_tags`（标签条件）+ `ORDER BY happened_at DESC LIMIT 50 OFFSET ?` 分页
  - 金额改为数值区间匹配（现在是金额字符串包含，语义反直觉）
  - 搜索结果流式分页：滚到底再取 50 条
- **收益**：功能（标签）+ 性能（万条账本搜索从全量 O(N) 内存 → 每页 50 行）一举两得

### P1-5 债务 / 借贷（借出 / 借入 / 还款 / 坏账）
- **参考**：钱迹借贷、Moze 债务中心
- **现状**：无 debt 模块。现有近似物：`loan` 账户 = 估值型负债（不走流水，`account_type_utils.dart:29`）；`receivable` 在文案里有残留（`:75,111`）但不可创建。还信用卡 = 转账。
- **方案**（复用账户体系，不另起炉灶）：
  - 激活 `receivable`（应收）类型 + 新增 `debt` 账户概念即可覆盖"借出/借入"两端：借出 500 = 从现金账户转账到「应收」账户；对方还款 = 反向转账；坏账 = 从应收账户做一笔「支出·坏账核销」
  - 账户详情页加「借款期限/到期日」字段 + 到期提醒（复用现有 `flutter_local_notifications` + `reminder_monitor_service` 基础设施）
  - 资产页「借出总额/借入总额」汇总卡（分组小计已有多币种先例 `accounts_page.dart:1052-1063`）
- **工作量**：≈ 4-5 天（大部分是 UI 与提醒，数据层几乎白送）

### P1-6 Excel（.xlsx）导出
- **参考**：竞品标配；Firefly III CSV 之外也提供 xlsx
- **现状**：导出仅 CSV（`export_page.dart`，带 BOM 保证 Excel 中文）；`excel: ^4.0.6` **已在依赖里**（现在只用于导入，`xlsx_reader.dart`）。
- **方案**：复用现有 CSV 列定义写 `Sheet`：Sheet1 明细、Sheet2 月度汇总；表头加底色/冻结首行。零新依赖。
- **工作量**：≈ 1 天

### P1-7 月度 PDF 对账单
- **现状**：无 PDF。分享海报管线已有（`share_poster_service.dart` + RepaintBoundary 截图）。
- **方案**（两档，建议先做 A）：
  - A：**图片版月度报告**（分享/存档）——复用海报服务，零新依赖，≈ 1 天
  - B：正式文本可选 PDF——引 `pdf` 包（新依赖），对账单排版，≈ 3 天
- **价值**：报销留档、给另一半对账、年度存档

### P1-8 第三方 App 导入器（钱迹 / 随手记 preset）
- **现状**：导入支持支付宝/微信/通用表头映射（`generic_parser.dart` 自动映射列），无竞品专用适配。
- **方案**：`generic_parser` 已能吃下大多数列结构，主要是补**收支方向约定/列名别名/日期格式** preset + docs 写迁移指引；提供「从钱迹迁移」一键向导文案。
- **价值**：降低迁移门槛 = 拉新入口

### P1-9 预算结转（Rollover）⭐ 开源标杆功能
- **参考**：**Actual Budget** 的信封预算核心——上月未花完的预算余额结转到下月（负结转也支持）；Firefly III 的 available budget 同思路。
- **现状**：`Budgets` 表（`db.dart:381-401`）只有 amount/period，**无任何结转字段**；每月预算独立计算，花超/剩余清零重算。
- **方案**：
  - v44 加 `rollover_mode`（none/positive/both，默认 none 兼容旧行为）到 `Budgets`
  - 预算页计算逻辑：`可用额度 = 本月预算 + 上月结转`；上月结转 = 上月预算 − 上月实际支出（按模式取 max(0,·) 或全量）
  - 展示层：预算卡显示「含结转 ¥X」，预算详情页给出结转链（近 6 个月结转轨迹）
  - 注意点：结转链计算需要按月聚合历史支出——用 SQL 聚合，不要在客户端遍历全量交易（复用性能 P0-2 的聚合思路）
- **工作量**：迁移 + 计算服务 + 预算卡 UI ≈ 2-3 天
- **价值**：预算用户最强诉求之一——"这个月剩 300，下月能买大件"是真实记账心智；信封式预算是 Actual Budget 万人 star 的核心原因。

### P1-10 自动分类规则（用户可编辑）⭐ 开源标杆功能
- **参考**：**Firefly III rules engine**（if 条件 → then 动作，可拖拽排序、可测试运行）；Moze 的自动分类规则。
- **现状**：`CategoryMatcher`（`category_matcher.dart`）是**硬编码中文关键词表**（约 20 组固定映射），仅作为 AI 解析的降级兜底（`bill_creation_service.dart:273`）；**用户完全无法自定义**——用户自己的常去商家（如楼下面馆、小区超市）永远匹配不上。
- **方案**：
  - v44 新增 `category_rules` 表（ledger_id、条件类型：备注包含/金额区间/账户/商户关键词、动作：设分类/设标签、优先级、启用开关）——同步字段 syncId/updated_at 按项目惯例补齐
  - 接线点两处：① 手动记一笔保存时对 note 跑规则（提示"已按规则匹配为 XX，可改"）；② AI/OCR 解析兜底链从硬编码 matcher 换成「用户规则 → 硬编码表」两级
  - 规则管理页：列表 + 优先级拖拽 + 单条"试运行"输入框（输入示例备注看命中）
  - 硬编码 `_categoryKeywords` 保留为出厂默认，不动
- **工作量**：表 + 匹配服务 + 管理页 + 两处接线 ≈ 3-4 天
- **价值**：记账 App 从"记"到"省心记"的分水岭；对无 AI 用户（境外/隐私敏感）这是唯一的自动化手段。

### P2-9 金额计算器运算符优先级
- **现状**：`amount_editor_sheet.dart:464-489` 明确从左到右顺序求值（1+2×3=9）。
- **方案**：改标准优先级 + 支持括号；显示行同时渲染历史（如 "1+2×"）。

### P2-10 其它
- 自定义统计周期（任意起止日期）——analytics 已有周/月/年/全部四档，恢复自定义区间选择
- 账户「冻结」：不出现在转账 picker、但计净资产（现有 `hidden` 是隐藏且仍计净资产，语义不同）
- `receivable` 图标/文案残留清理（随债务模块一起）

### P2-11 储蓄目标（存钱计划）
- **参考**：Firefly III piggy banks、钱迹存钱计划。
- **现状**：全库无对应实体（`Goals/Savings` 无表、无页面）。最接近的是普通账户 + 手动记账。
- **方案**：新表 `savings_goals`（目标名、目标金额、截止日、关联账户可选、封面 emoji）；进度 = 关联账户余额或手动累计；资产页/首页小组件位加进度卡。**不引入独立"存钱"资金流**（避免与账户体系打架），纯目标追踪 + 到期提醒（复用 reminder 基础设施）。
- **工作量**：≈ 2-3 天
- **价值**：正向激励型功能，留存利器；实现成本低（不动资金流）。

---

## 二、性能优化

### P0-1 首页全量 watch → 窗口化分页（本方案最大单点）
- **现状**：`home_page.dart:927-934` 的 StreamBuilder 订阅 `repo.transactionsWithCategoryAll(ledgerId)` —— **该账本全部交易**实时进内存；配套的共享账本 hydration（`local_transaction_repository.dart:115-140` `_watchTxJoinWithSharedHydration`）在**每次**表变更时对全量行重新 hydrate。FlutterListView 只解决"渲染"懒加载，数据层是全量的。
- **影响面**：万条账本 = 万行 Drift 对象常驻；批量导入/同步落库时（事务提交 bump table updates）触发全量 SQL 重跑 + 全量 hydration。
- **方案**：
  - 查询改 keyset 分页：首屏 `ORDER BY happened_at DESC LIMIT 200`，滚到底以 `happened_at < 末条` 追加下一页（keyset 比 OFFSET 稳定且利用已有复合索引）
  - watch 语义：只 watch 窗口内数据 + 监听 `transactions` 表更新计数；窗口外数据靠分页拉取
  - "跳转月份"（`jumpToMonth`）改按月窗口取数，而不是全量里找
- **预期收益**：万条账本首页稳态内存从 O(全量) 降 O(200)；批量写入后的重 hydration 从全量降窗口
- **风险**：`jumpToMonth`/月度汇总卡（`home_month_summary_card`）依赖全量列表的地方需要改为 SQL 聚合（月度汇总本来就是 SUM，不该依赖列表）——迁移成本 3-5 天

### P0-2 账户余额物化 / 缓存
- **现状**：`getAccountBalance` = `initialBalance + SUM(全部流水)`（`local_account_repository.dart:263-297`），账户页、净值页、小组件多处、每账本分别触发；无任何缓存。
- **方案**：
  - 查询层先做（低成本）：`watchAccountsForLedger` 合并为一条 `GROUP BY account_id` 聚合 SQL，替代逐账户循环
  - 再做（中成本）：净值趋势已有按日聚合需求（`net_worth_trend_page`），引入 `balance_snapshots`（按月末日余额物化，写入交易时增量维护），净值页直接读快照
- **预期收益**：账户页打开 SQL 数从 O(账户数×2) 降 1 条；净值趋势大账本秒开

### P1-3 statsRefreshProvider 分频道
- **现状**：全局 `statsRefreshProvider` 一 bump，`statistics_providers.dart` 里十几个 FutureProvider 全部重算（月度统计/账户统计/净值分解/预算……）。
- **方案**：拆 `txStatsRefresh(ledgerId)` / `accountStatsRefresh` / `budgetStatsRefresh` 频道，写入方按数据类别 bump；或直接改 Drift `tableUpdates` 流驱动（响应式更准）。
- **收益**：单笔记账后的重算面收窄

### P1-4 图标加载统一缓存层
- **现状**：`AccountTypeIcon` 每次 build `SvgPicture.asset`（`account_type_utils.dart:213`）；自定义分类图标 `Image.file` 无降采样（`category_icon.dart:114`，size 24 却解原图）；路径缓存 `_iconPathCache`（`:32`）进程级无上限 Map。
- **方案**：统一 `IconService`：SVG（flutter_svg 内部有 cache，但确保复用同一 `AssetLoader` 上下文）/ 自定义图 → `cacheWidth: size * devicePixelRatio` + 小规模 LRU；`_iconPathCache` 加 LRU 上限（如 200）。

### P2-5 大文件拆分（known-issues 中期项，同时是性能工作的前置）
- `annual_report_page.dart` 2128 行、`analytics_page.dart` 1699 行、`amount_editor_sheet.dart` 1422 行、`search_page.dart` 1231 行——拆 widget 文件，hot reload/分析器/编译都受益。

---

## 三、UI / UX 优化

1. **列表长按快捷菜单**：再来一笔 / 删除 / 报销开关（Material 3 菜单，配合功能 P0-1/P0-3）
2. **删除即 Snackbar 撤销**（配合回收站 P0-2）——替代现在的确认弹窗或裸删
3. **记一笔页模板入口**（配合 P0-1）：金额键盘上方横滑模板条，一点即填
4. **FutureBuilder 未缓存点位收尾**（审计遗留）：`transfer_form.dart:358`、`category_icon.dart:84`（`category_icon` 的自定义图标路径在缓存未命中时每次 build 触发新 Future → 闪烁占位图标）
5. **附件预览渐进加载**：先 `cacheWidth` 缩略图秒显 → 原图解码完成后切换（InteractiveViewer 缩放时再取原图）
6. **空状态骨架屏**：`AppEmpty` 已统一，可加 shimmer 过渡（首屏 StreamBuilder 空档期的"无记录"误现已有 `snapshot.hasData` 防护，补视觉层）
7. **搜索页筛选增强**（配合功能 P0-4）：标签 chip、报销状态 chip、金额区间输入
8. **暗色 dialogTheme 收尾**（审计 U11 遗留）

---

## 四、内存优化（专项清单）

| # | 问题 | 位置 | 方案 | 预期收益 |
|---|------|------|------|----------|
| M1 | `Image.file` 全部无 cacheWidth，原图解码（4000×3000 JPEG ≈ 45MB/张） | 11 处：`attachment_preview_page.dart:287,304`（两个目录）、`category_icon.dart:114`、`ai_chat_page.dart`、`category_edit_page.dart`、`attachment_picker.dart`、`profile_card.dart`、`user_profile_poster.dart` 等 | 全量加 `cacheWidth: (显示宽×dpr)`；预览页缩略态先降采样、放大再原图 | 单张内存 -90%+，附件重度用户峰值显著降 |
| M2 | 首页全量交易常驻 | `home_page.dart:934` | 性能 P0-1 分页窗口 | 大账本 RSS 降数十 MB |
| M3 | 4 Tab 全量保活 | `app.dart:52-57,856` IndexedStack | **懒加载 IndexedStack**：首次进入才 build、已建保活（项目内已有先例：`transaction_editor_page.dart:123` 的懒 IndexedStack 可直接复用思路） | 冷启动构建 4 Tab → 1 Tab；分析页/账户页的图表/控制器延迟分配 |
| M4 | `imageCache` 无上限调优 | `main.dart` 未配置 | `PaintingBinding.imageCache.maximumSizeBytes = 50<<20`（50MB）、maximumSize=500；启动时设置 | 防重度用户图片缓存无界增长 |
| M5 | 双份交易缓存并存 | `cachedTransactionsProvider`（预载 20 条）+ 全量 StreamBuilder 数据 | Stream 首帧到达后清空预载缓存（`cachedTransactionsProvider.state = null`），现在只在账本切换时清（`home_page.dart:615`） | 少一份 20 行×详情拷贝（小头，顺手） |
| M6 | `_iconPathCache` 无上限 | `category_icon.dart:32` | LRU 上限 200 | 防长会话慢涨 |
| M7 | 附件预览页 dispose 不 evict | `attachment_preview_page.dart` | 大图页 `dispose` 时 `ImageCache.evict(FileImage)` | 预览连续翻多张时及时释放 |
| M8 | logger 缓冲 | `logger_service.dart:400`（2s 落盘） | 确认内存 buffer 条数上限（如 500 条滚动） | 防 debug 级刷屏撑爆 |
| M9 | AI 聊天页图片 | `ai_chat_page.dart` 的 `Image.file` | 并入 M1；历史消息列表图片用缩略 | 长对话页内存 |

**验收方式**：DevTools Memory —— 灌 1 万条交易 + 200 张附件的 seed 脚本，对比冷启动 RSS、首页滚动稳态 RSS、连翻 10 张附件预览的峰值 RSS；`flutter run --profile` + Performance overlay 验证滚动无 >8ms jank。

---

## 五、实施批次建议

| 批次 | 内容 | 依赖 | 风险 |
|------|------|------|------|
| B1 纯内存/低风险 | M1 cacheWidth 全量、M4 imageCache 上限、M3 Tab 懒加载、M5/M6/M7/M8、UI-4 FutureBuilder 收尾 | 无 | 低（无 schema 变更） |
| B2 数据层 v44 迁移 | 软删除（P0-2）、报销字段（P0-3）、模板表（P0-1）、搜索 SQL 下推（P0-4）、预算结转字段（P1-9）、分类规则表（P1-10） | B1 无依赖，可与 B1 并行开发 | 中：查询谓词收口要全面；按项目惯例补 `migration_v44_test.dart` |
| B3 功能 UI | 模板页/再来一笔、长按菜单、Snackbar 撤销、报销角标与筛选、搜索标签 chip、Excel 导出（P1-6）、图片版月度报告（P1-7A）、预算结转卡与计算（P1-9）、规则管理页与接线（P1-10） | B2 | 低 |
| B4 性能深水区 | 首页分页窗口（性能 P0-1）、余额聚合/物化（P0-2）、statsRefresh 分频道 | 建议 B2 后 | 中高：`jumpToMonth`/月度卡改 SQL 聚合，需回归测试 |
| B5 大件 | 债务模块（P1-5）、余额快照表、正式 PDF（P1-7B）、导入 preset（P1-8）、储蓄目标（P2-11）、计算器优先级（P2-9） | 独立 | 各自独立评估 |

每批出口标准：`flutter analyze` 0 error、全量 `flutter test` 绿、真机冒烟（记账/改/删/同步/小组件五链路）、迁移测试覆盖新 schema 版本。

---

## 六、明确不做 / 缓做

- **SQLCipher 全库加密**、PIN 加盐与失败锁定、FLAG_SECURE：属安全项，已在 `docoments/16-known-issues.md` 短期清单，优先级独立于本方案（且 PIN 是 P0 安全债，建议先于 B2 处理）
- **Web 端 / Flutter SDK 升级**：known-issues P3，工具链锁 3.27.3 有因（pubspec.yaml:48-52 注释），不动
  - ⚠️ **2026-09-19 复核，本条已过期**：SDK 已升级到 **Flutter 3.44.3**（`pubspec.yaml:14`，且 version 单一来源注释已改写到 `pubspec.yaml:8-13`，原 `:48-52` 那段"锁 3.27.3"的注释不存在了）。"不动"结论仍然成立，但依据变成"已升到当前稳定线、无进一步升级需求"，不是"锁在旧版"。
- **实时协同**：历史项目已下线，不复活
- **性能 P1-3 statsRefresh 分频道**（本轮评估后决定不做）：全局 tick 共 35 个 bump 点 / 22 处 watch，分频道要改全部调用方且「写入类别→读取类别」对应关系易错配（同步完成影响全部类别），改动面大。M3 Tab 懒加载落地后，非活跃 Tab 的统计 provider 已无人订阅，bump 不再触发其重算——P1-3 的主要收益已被覆盖，剩余部分性价比不足。

---

## 七、本轮落地记录（2026-09-14，仅 UI/性能/内存）

**验收：`flutter analyze` 0 error（新增 0 warning，基线 250 个存量 warning 不变）；全量 `flutter test` 1158 个测试全绿（1 个历史 skip）。**

### 内存
- **M1 cacheWidth 全量落地**：11 处 `Image.file` + settings 预览页 2 处 `Image.memory` 全部按「显示尺寸×dpr」钉住解码宽度（海报场景按 750px 画布取 280px 固定值）。涉及 8 文件：两个 `attachment_preview_page.dart`、`category_icon.dart`、`attachment_picker.dart`（2 处，含待上传原图）、`profile_card.dart`（80px 头像）、`ai_chat_page.dart`（32px 头像）、`user_profile_poster.dart`、`category_edit_page.dart`（48px 图标）
- **M4 imageCache 上限**：`main.dart` 启动即设 `maximumSize=500` / `maximumSizeBytes=50MB`（首帧解码前）
- **M7 附件预览页**：缩略态按屏幕短边×dpr 解码，InteractiveViewer 放大 >1.05（TransformationController 监听 + 150ms 去抖）切原图；`dispose` 逐个 `provider.evict()` 释放本页翻过的图（注意 cacheWidth 路径 key 是 ResizeImage，必须走 provider.evict）
- **M5**：Stream 首帧到达后 post-frame 清空 `cachedTransactionsProvider`（核实切账本无重填路径，清空安全）
- **M6**：`_iconPathCache` 改 LinkedHashMap + 200 条上限（插入序淘汰最旧）
- **M8**：核实 logger 已有 2000 条滚动上限 + pendingLogs 仅启动窗口暂存，**无需改动**（方案原判断过严）

### 性能
- **P0-2 账户余额 SQL 聚合收口**：`local_account_repository.dart` 的 `getAccountBalance` / `getAccountGlobalBalance` / `getAccountBalanceInLedger` / `getAccountExpense` / `getAccountIncome` / `getAllAccountBalances`（后者由逐账户 N+1 改单条 GROUP BY）全部从「全量拉行进内存循环」改为 SQL 聚合；口径与 `getAllAccountStats` 批量 SQL 逐字对齐，由 `sql_aggregation_regression_test.dart`（批量 vs 单账户一致性）+ `account_stats_exclude_flags_test.dart` 验证通过
- **UI-4 transfer_form FutureBuilder 记忆化**：`_loadFilteredAccountsCached()` 按（账本 id, 编辑对象, 钉住账户集合）键缓存 future，rebuild 不再每次触发 `getAllAccounts` + `filterAccountsForLedger` 查询

### UI / 启动
- **M3 Tab 懒加载**：`app.dart` 新增 `_ActiveTabIndex`（InheritedWidget 广播当前 tab）+ `_LazyTab`（首次成为当前 tab 才 build，已构建保活）；分析/账户/我的三页加静态 `builder` 入口。冷启动构建 4 Tab → 1 Tab，`_pages` 保持 const

### 未落地（本轮范围外或评估后放弃）
- 功能章全部条目（范围收窄，未动代码）
- 性能 P0-1 首页分页窗口（深水区，建议 B2 后独立批次）
- P1-3 statsRefresh 分频道（见第六章评估结论）
- UI 骨架屏/搜索筛选/长按菜单（依赖功能章条目）
