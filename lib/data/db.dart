import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart';
import '../l10n/app_localizations.dart';
import 'encryption/db_encryption_migration.dart';
import 'encryption/sqlcipher_capability.dart';
import '../services/data/category_service.dart';
import '../services/data/seed_service.dart';
import '../services/system/logger_service.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'db.g.dart';

// --- Tables ---

class Ledgers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  TextColumn get type =>
      text().withDefault(const Constant('personal'))(); // personal
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // 跨设备同步唯一标识：跟 accounts/categories/tags 的 syncId 同语义，
  // 历史上对齐 PiggyCount Cloud server 的 ledger.external_id(该服务已
  // 下线)。快照同步沿用该字段做设备间账本匹配,而不是本地 autoIncrement
  // id(A/B 本地 id 必然不一致)。v21 migration 里已为旧数据把 id 回填成
  // syncId 以兼容。
  TextColumn get syncId => text().nullable()();
  // v27: 自定义每月起始日(1-28),统计/预算/小部件按 [当月N日, 次月N日) 聚合,
  // 1=自然月。随 sync 跨设备(payload key `monthStartDay`,server 列
  // ledgers.month_start_day)。见 .docs/period-start-date/design.md。
  IntColumn get monthStartDay => integer().withDefault(const Constant(1))();

  /// 审计 T1（v40）：本行最后一次被**本设备写**的时刻（UTC epoch）。
  /// NULL = 本设备从未更新过该行（新建即导入的行保持 NULL，语义明确）。
  /// 由数据库触发器 trg_ledgers_touch_updated_at 在普通 UPDATE 时自动维护；
  /// 显式写入不同值（如未来 pull apply 回填远端时间）不会被触发器覆盖。
  /// 用途：本地新旧证据 / 未来 LWW 方向仲裁的基础字段。
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()(); // 保留用于v2迁移，后续会移除
  TextColumn get name => text()();
  TextColumn get type => text().withDefault(const Constant('cash'))();
  TextColumn get currency =>
      text().withDefault(const Constant('CNY'))(); // v1.15.0新增：币种
  RealColumn get initialBalance => real().withDefault(const Constant(0.0))();
  DateTimeColumn get createdAt =>
      dateTime().nullable()(); // v1.15.0: 改为可空，避免迁移问题
  DateTimeColumn get updatedAt => dateTime().nullable()();
  IntColumn get sortOrder =>
      integer().withDefault(const Constant(0))(); // 排序顺序，数字越小越靠前
  RealColumn get creditLimit => real().nullable()(); // 信用额度
  IntColumn get billingDay => integer().nullable()(); // 账单日 (1-28)
  IntColumn get paymentDueDay => integer().nullable()(); // 还款日 (1-28)
  TextColumn get bankName => text().nullable()(); // 开户行
  TextColumn get cardLastFour => text().nullable()(); // 卡号后四位
  TextColumn get note => text().nullable()(); // 备注
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)
  /// 隐藏:true 时该账户不再出现在记账/转账/周期选择器,账户管理页移入「已隐藏」分区。
  /// 仍计入账户余额、净资产、资产构成、净值趋势(.docs/account-archive/01 §二 D1)。
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();
}

/// v52：投资持仓（手动估值版，2026-10-08）。
///
/// 定位：`investment` 只是「估值型账户」，账户金额由手填 `initialBalance` 给出；
/// 本表让投资账户的金额改由 **Σ(份额 × 生效净值)** 供给（有持仓时接管、无持仓
/// 时回退 `initialBalance`，绝不双计）。见 `lib/utils/holding_metrics.dart`
/// 的 `effectiveUnitPrice` 与 `lib/data/repositories/local/local_account_repository.dart`
/// 的「有效账户金额」helper。
///
/// 作用域：与 [Accounts] 同为 **user-global** 实体 —— `ledgerId` 是与 accounts
/// 同型的 legacy 列（恒 0），业务关联走 [accountId]。快照中与账户同款**全量导出**
/// 到每个账本快照（理由见 `lib/cloud/transactions_json.dart` 的账户导出注释），
/// 恢复任意快照即可收敛持仓集合，也避免「换账本看不到投资账户持仓」的口径割裂。
///
/// ⚠️ 行情预留（避免后期再接行情时升 schema + 升快照格式版本）：
/// - **可同步**：[market]（SH/SZ/HK/US/FUND/CRYPTO，行情源匹配与代码规范化）、
///   [autoQuote]（该笔是否允许自动刷新，默认 false）。
/// - **本地专有**：[quotePrice] / [quoteFetchedAt] / [quoteSourceId] —— 行情缓存，
///   **不进快照、不进 `holdingCanon` 指纹、不写 `local_changes`**，只由行情刷新
///   写入（与 `transactions.created_by_user_id` / `last_edited_by_user_id`
///   的「本地专有列不进快照」同定位）。手滑把它们纳入指纹会让跨设备指纹
///   永久不一致、同步永不收敛 —— 守门见
///   `test/cloud/sync_contract_holdings_test.dart`。
class Holdings extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 与 accounts 同型的 legacy 列（恒 0）：保留只为两表结构对称与未来按账本
  /// 切分的余地，当前**所有查询都按 [accountId] 走**，不要拿它当业务维度。
  IntColumn get ledgerId => integer().withDefault(const Constant(0))();

  /// 所属投资账户（`accounts.id`）。账户是 user-global，本表随之为 user-global。
  IntColumn get accountId => integer()();

  /// 持仓名称（如「贵州茅台」「纳斯达克100ETF」）
  TextColumn get name => text()();

  /// 行情代码（如 `600519` / `AAPL` / `BTC`）。手填版可为空 = 只当备注用。
  TextColumn get symbol => text().nullable()();

  /// 行情市场标识：`SH` / `SZ` / `HK` / `US` / `FUND` / `CRYPTO`。
  /// 手填版不做校验（用户自填），但**一旦接行情源它就是路由键** —— 行情源按
  /// 它决定「这个代码归哪家行情商、用哪条代码规范化规则」。
  TextColumn get market => text().nullable()();

  /// 资产类别：`stock` / `fund` / `bond` / `crypto` / `other`（UI 分组与图标）。
  TextColumn get assetClass => text().withDefault(const Constant('other'))();

  /// 持仓计价币种。**可不同于账户币种**（如人民币账户持有美股）：
  /// 进账户金额前先按汇率折算到账户币种，缺汇率的持仓整条剔除（见 holding_metrics）。
  TextColumn get currency => text().withDefault(const Constant('CNY'))();

  /// 持有份额
  RealColumn get quantity => real().withDefault(const Constant(0.0))();

  /// 单位成本（手填，可同步）
  RealColumn get unitCost => real().withDefault(const Constant(0.0))();

  /// 手填当前单位净值（**用户数据、可同步**）。行情可用时展示层走「生效价」
  /// 覆盖它，但本列不清空 —— 行情失效 / 未配置时自动回退，保证可逆。
  RealColumn get unitPrice => real().withDefault(const Constant(0.0))();

  /// 该笔是否参与行情自动刷新（默认 false = 始终用手填净值；可同步）。
  BoolColumn get autoQuote => boolean().withDefault(const Constant(false))();

  TextColumn get note => text().nullable()();

  /// 账户内持仓排序，数字越小越靠前
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 跨设备同步唯一标识 (UUID)
  TextColumn get syncId => text().nullable()();

  DateTimeColumn get createdAt => dateTime().nullable()();

  /// 本地审计时间。**不进快照 / 不进指纹**（与 accounts 同款），因此行情缓存
  /// 写入被 updated_at 触碰触发器顺带刷新也无副作用。
  DateTimeColumn get updatedAt => dateTime().nullable()();

  // ── 以下三列为本地专有行情缓存（不进快照 / 不进指纹 / 不写 local_changes）──

  /// 行情源返回的最新单位价（NULL = 从未拉到过行情）
  RealColumn get quotePrice => real().nullable()();

  /// 行情拉到时刻（用于「生效价」的 TTL 判定与 UI 展示「更新于 …」）
  DateTimeColumn get quoteFetchedAt => dateTime().nullable()();

  /// 提供该行情的行情源标识（如 `manual` / 将来的 `eastmoney`）；换源后旧缓存
  /// 是否仍可用由此列与当前选中源比对决定。
  TextColumn get quoteSourceId => text().nullable()();
}

/// 自动汇率本地缓存。日期键 append-only;可随时整表重建 → **不进同步**(README D2)。
/// 方向:1 quote = rate base(rate 为 decimal 字符串)。
class ExchangeRates extends Table {
  TextColumn get baseCurrency => text()();
  TextColumn get quoteCurrency => text()();
  TextColumn get rateDate => text()(); // 'YYYY-MM-DD',取源数据自带日期
  TextColumn get rate => text()();
  TextColumn get source => text()(); // 'server'|'fawazahmed0'|'frankfurter'
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {baseCurrency, quoteCurrency, rateDate};
}

/// 手动汇率覆盖:固定生效直到删除(README D9)。user-global 同步实体,
/// 字段约定对齐 Accounts(syncId UUID)。方向同 ExchangeRates:1 quote = rate base。
/// 业务唯一键 (baseCurrency, quoteCurrency),唯一索引在 v28 迁移建。
class ExchangeRateOverrides extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().nullable()();
  TextColumn get baseCurrency => text()();
  TextColumn get quoteCurrency => text()();
  TextColumn get rate => text()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

/// 中国法定节假日本地缓存（date 主键，整年替换）。随时可整表重建
/// → **不进云同步 / 不进全量备份**（与 [ExchangeRates] 同定位）。
///
/// 语义：DB 有行以 DB 为准；DB 为空（首装 / 清库 / 更新中）由
/// `HolidayService.builtinHolidays()` 回落预置表保证冷启动可用。
/// ⚠️ 刻意**不**纳入 `local_changes` / 指纹 / diff / 备份清单，也不挂
/// `updated_at` 触碰触发器 —— 它是可重建缓存，纳管会回流幻影变更并让
/// `test/cloud/sync_contract_coverage_test.dart` 变红。
class HolidayEntries extends Table {
  /// 'YYYY-MM-DD'
  TextColumn get date => text()();

  /// 公历年（整年替换 / 设置页按年分组都靠它）
  IntColumn get year => integer()();

  /// true = 放假日；false = 调休补班日（要上班的周末）
  BoolColumn get isHoliday => boolean()();

  /// 节假日名称（如「春节」「春节后补班」）
  TextColumn get name => text()();

  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {date};
}

/// 节假日更新记账（单行，id 恒为 1）。本地调度状态 → 不进同步 / 备份。
class HolidayUpdateMeta extends Table {
  /// 恒 1
  IntColumn get id => integer()();

  /// 上次**成功**更新时间（epoch ms；0 = 从未成功）
  IntColumn get lastUpdateMs => integer().withDefault(const Constant(0))();

  /// 上次尝试时间（epoch ms；成功 / 失败都写）
  IntColumn get lastAttemptMs => integer().withDefault(const Constant(0))();

  /// 连续失败次数（成功后清零）
  IntColumn get failureCount => integer().withDefault(const Constant(0))();

  /// 「每月自动更新」开关
  BoolColumn get autoEnabled => boolean().withDefault(const Constant(true))();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // expense / income
  TextColumn get icon => text().nullable()();
  IntColumn get sortOrder =>
      integer().withDefault(const Constant(0))(); // 排序顺序，数字越小越靠前
  IntColumn get parentId => integer().nullable()(); // 父分类ID，null 表示一级分类
  IntColumn get level =>
      integer().withDefault(const Constant(1))(); // 层级：1=一级，2=二级
  // v13: 自定义图标支持
  TextColumn get iconType => text().withDefault(
      const Constant('material'))(); // material / custom / community
  TextColumn get customIconPath => text().nullable()(); // 自定义图标本地路径
  TextColumn get communityIconId => text().nullable()(); // 社区图标ID（预留）
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_categories_touch_updated_at 自动维护。
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()();
  TextColumn get type => text()(); // expense / income / transfer
  RealColumn get amount => real()();
  IntColumn get categoryId => integer().nullable()();
  IntColumn get accountId => integer().nullable()();
  IntColumn get toAccountId => integer().nullable()();
  DateTimeColumn get happenedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get note => text().nullable()();
  IntColumn get recurringId => integer().nullable()(); // 关联到重复交易模板
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)
  // v24: 交易记录人(“谁记的”显示)。**本地专有列**——不进云快照,恢复路径按
  // 同库原值搬运(见 data_import_service 的本地专有列回填与
  // test/cloud/restore_preserves_local_only_columns_test.dart)。共享账本协作
  // 下线后已无 UI 写入方(`markTxAuthor` 保留但无人调用),列本身按
  // 「不删字段」规则保留。
  // (v24 同批引入的共享账本 *SyncIdOverride 列已随功能下线,由 v51 迁移 DROP。)
  TextColumn get createdByUserId => text().nullable()();
  TextColumn get lastEditedByUserId => text().nullable()();

  /// 不计入收支:true 时从收支统计/图表/月年汇总剔除,但仍计入账户余额、净资产、
  /// 账单列表(.docs/transaction-flags/01 §二 D1)。
  BoolColumn get excludeFromStats =>
      boolean().withDefault(const Constant(false))();

  /// 不计入预算:true 时从预算用量剔除。与 excludeFromStats 完全独立(D2)。
  BoolColumn get excludeFromBudget =>
      boolean().withDefault(const Constant(false))();

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_transactions_touch_updated_at 自动维护。
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// v30 交易级多币种(.docs/multi-currency-ledger):交易币种(ISO 大写)。
  /// 有账户 → 恒等于账户 currency(账户内不混币);无账户 → 用户所选(L12,
  /// 默认账本本位币)。显式存让交易自包含(同步/统计不必每次 join 账户)。
  TextColumn get currencyCode => text().nullable()();

  /// v30:折算到账本本位币的金额快照(按记账时汇率,保存即定,不随汇率重算)。
  /// 单币种/未折算 == amount(隐含汇率 1.0)。账本维度统计读本列(?? amount),
  /// 账户维度(余额等)仍读 amount。
  RealColumn get nativeAmount => real().nullable()();

  /// v45:原始金额(记账时用户手动填写的来源/票面金额,如发票原价)。
  /// NULL = 用户未填写,语义等价于「默认金额 = 记账金额 amount」。
  /// 刻意不回填存量行 —— 物理 NULL 才能区分「未填写」与「手填了相同值」,
  /// 且历史明细的统计口径零变化。读取/统计统一走
  /// `COALESCE(original_amount, amount)`,单一口径避免散落兜底。
  RealColumn get originalAmount => real().nullable()();

  /// v46: 自定义字段值,{fieldSyncId: value} 的 JSON 对象。
  /// - 键是 [CustomFieldDefinitions.syncId](而非本地 int id),天然适配
  ///   共享账本 —— Editor 写入 Owner 定义的字段值无需 override 表。
  /// - 值为 JSON 原生类型:金额存 number、日期存 ISO-8601 字符串、文本存原文。
  /// - NULL = 该笔无任何自定义字段值(未填写/全部清空),存量行保持 NULL,
  ///   导出时**不写该键**,与 v45 original_amount 同款防漂移范式。
  /// - 仅在编辑表单读写,不参与列表/统计 SQL,所以不必可查询、无须索引。
  TextColumn get customValuesJson => text().nullable()();
}

/// v46: 账本自定义字段定义(按账本独立)。
///
/// 与 [Tags] 同属「用户自建字典」:名称/排序/创建时间 + syncId 跨设备锚定。
/// 与 tags 的差别:值不走关联表,而是以 fieldSyncId 为键落在
/// [Transactions.customValuesJson] —— 见该列注释中的取舍说明。
///
/// fieldType 取 `amount | text | date`,新增类型只改应用层分支,
/// 不动库结构(存值统一为 JSON 原生类型)。
class CustomFieldDefinitions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 所属账本:字段定义按账本隔离,账本 A 的字段不会出现在账本 B。
  IntColumn get ledgerId => integer()();

  /// 用户自定义字段名(同账本内不重名,由应用层校验)。
  TextColumn get name => text()();

  /// amount / text / date。字符串存储以便后续扩展新类型。
  TextColumn get fieldType => text()();

  /// 展示与录入门槛顺序,数字越小越靠前(与 Categories/Tags.sortOrder 同义)。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 跨设备同步唯一标识 (UUID)。字段值的 JSON 键就是本列。
  TextColumn get syncId => text().nullable()();

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_custom_field_definitions_touch_updated_at 自动维护。
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class RecurringTransactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()();

  /// 跨设备同步 syncId。v33 新增,migration 给老行补随机 hex;
  /// 语义与 budgets.syncId(v22)/accounts.syncId 一致:快照与 Cloud
  /// 链路都按此做跨设备实体锚定(cloud_recurring_sync PRD)。
  TextColumn get syncId => text().nullable()();
  TextColumn get type => text()(); // expense / income / transfer
  RealColumn get amount => real()();
  IntColumn get categoryId => integer().nullable()(); // 转账时为null
  IntColumn get accountId => integer().nullable()();
  IntColumn get toAccountId => integer().nullable()(); // 转账的目标账户
  TextColumn get note => text().nullable()();

  // 重复规则
  TextColumn get frequency => text()(); // daily / weekly / monthly / yearly
  IntColumn get interval =>
      integer().withDefault(const Constant(1))(); // 间隔（每1天、每2周等）
  IntColumn get dayOfMonth => integer().nullable()(); // 月的第几天（1-31）
  IntColumn get dayOfWeek => integer().nullable()(); // 周几（1=周一, 7=周日）
  IntColumn get monthOfYear => integer().nullable()(); // 哪个月（1-12，用于yearly）

  // 时间范围
  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get endDate => dateTime().nullable()(); // 为空表示永久
  DateTimeColumn get lastGeneratedDate =>
      dateTime().nullable()(); // 最后一次生成交易的日期

  // 状态
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// v42 周期账单币种(移植 BeeCount #444):模板币种(ISO 大写)。
  /// NULL = 账本本位币(存量语义);挂了账户时生成仍以账户币种为准(账户内不混币)。
  /// 汇率不锁在模板上 —— 每次生成按当日有效汇率折算 nativeAmount。
  TextColumn get currencyCode => text().nullable()();

  /// v47: 周期账单模板级自定义字段值,{fieldSyncId: value} 的 JSON 对象。
  /// - 生成实例时整包注入 `transactions.custom_values_json`(实例侧再改不影响
  ///   模板,下一次生成仍按模板值)。
  /// - 编解码必须走 CustomFieldValueCodec(见 models/custom_field_values.dart,
  ///   键序/数值表示统一),与交易值同款。
  /// - NULL = 模板未配置任何字段值;存量行保持 NULL,导出**不写该键**(v45/v46
  ///   同款防漂移范式:回填 `{}` 会让"旧快照无此键"与"显式空对象"指纹不一致)。
  /// - 仅编辑表单与生成器读写,无须索引。
  TextColumn get templateFieldValues => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// AI 对话表
class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();
  @Deprecated('对话已改为全局，不再与账本关联')
  IntColumn get ledgerId => integer().nullable()();
  TextColumn get title => text().withDefault(const Constant('AI对话'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// AI 消息表
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get conversationId => integer()();
  TextColumn get role => text()(); // 'user' | 'assistant'
  TextColumn get content => text()();
  TextColumn get messageType => text()(); // 'text' | 'bill_card'
  TextColumn get metadata => text().nullable()(); // JSON (BillInfo 数据)
  IntColumn get transactionId => integer().nullable()(); // 关联的交易ID(撤销用)
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// 标签表
class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()(); // 标签名称
  TextColumn get color => text().nullable()(); // 颜色值（如 #FF5722）
  IntColumn get sortOrder => integer().withDefault(const Constant(0))(); // 排序
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)

  /// 审计 T1（v40）：见 Ledgers.updatedAt 注释。触发器
  /// trg_tags_touch_updated_at 自动维护。
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

// 本地变更追踪表（用于增量同步）
class LocalChanges extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entityType => text()(); // transaction/account/category/tag
  IntColumn get entityId => integer()(); // 本地实体ID
  TextColumn get entitySyncId => text()(); // 实体的 syncId (UUID)
  IntColumn get ledgerId => integer()(); // 关联账本ID
  TextColumn get action => text()(); // create/update/delete
  TextColumn get payloadJson => text().nullable()(); // 变更后的完整 JSON
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get pushedAt => dateTime().nullable()(); // 非null表示已推送
}

// 注：历史上的 sync_state 表（deviceId/providerType/serverCursor 游标）在
// Supabase 增量同步废弃后已无任何读写方（游标后由旧增量引擎内存 +
// entity_change_watermarks 承载），v37 迁移统一 DROP，见 onUpgrade。

/// 审计 S3：每实体已见最大服务端 change_id 水位。
/// server change_id 全局单调；回声与应用成功都推进水位，
/// 应用前拦截 changeId ≤ 水位的陈旧重放，防旧值覆盖本地较新状态。
class EntityChangeWatermarks extends Table {
  TextColumn get syncId => text()();
  IntColumn get watermark => integer()();

  @override
  Set<Column> get primaryKey => {syncId};
}

// v43（审计 P0-1）：同步操作结构化指标（本地测量，零遥测）。
//
// 每次核心同步场景（快照上传/恢复/启动检查/附件补齐/云端备份）的
// outcome 落一行，供「同步健康」卡按 30 天窗口聚合成功率：
// success / (success + failed + soft_fail)，conflict 不计入分母
// （它是并发保护正确工作的证据，不是失败）。
// soft_fail 单列（审计 P1-3）：verified=false / objectMissing / 指纹
// 交叉自检不一致等「操作报成功但数据未收敛」的信号 —— 这正是 99.9%
// 与 99% 之间的差距主体，与 failed 必须分开可查。
//
// 隐私约束（PRIVACY.md 零遥测承诺）：本表只存本地、不上云、不导出
// 除非用户主动操作「诊断包导出」；error_detail 只留错误类别枚举与
// 摘要（异常类型名 + 首行消息，截断 200 字符），不含凭据/完整堆栈。
class SyncOpLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get ts => dateTime().withDefault(currentDateAndTime)();
  TextColumn get backend => text()(); // s3 / webdav / supabase / icloud / local
  TextColumn get scenario =>
      text()(); // snapshotUpload / snapshotRestore / startupCheck / attachmentFill / cloudBackup / remoteDiscovery
  TextColumn get outcome => text()(); // success / failed / soft_fail / conflict
  TextColumn get errorClass => text()
      .nullable()(); // network_timeout / auth / gateway / precondition / data_corruption / unknown
  IntColumn get ledgerId => integer().nullable()();
  IntColumn get attempts => integer().withDefault(const Constant(1))();
  IntColumn get durationMs => integer().nullable()();
}

// v43（审计 P1-6）：换名收尾删除失败的旧远程槽位，持久化登记。
//
// 此前 _staleRemoteSlots 仅存内存：downloadRemoteLedger「先传新槽位再删
// 旧文件」两步之间删除失败（网络抖动）时，旧 slot 文件残留且 slotKey
// 不匹配任何本地账本 —— 进程重启后登记丢失，下次启动被发现流程当
// 「云端新账本」再次提示导入（2026-09-07 双端实测即踩中，B 端多出 6
// 个重复账本）。落到 DB 后跨重启存活，初始化时统一补删。
class StaleRemoteSlots extends Table {
  TextColumn get path => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {path};
}

/// v44 (F1 回收站): 软删除的交易整行搬进本表，**不是**给 transactions
/// 加 deleted_at 列。
///
/// 为什么不加列：transactions 的读路径约 75 处，其中约 50 处是手写的
/// SQL 字符串（账户余额、分类/日/月/年统计、预算用量）。"每条读都记得
/// 带 WHERE deleted_at IS NULL" 编译器管不着，漏一条就是"已删的交易仍
/// 计入余额"——静默的账目错误，比没有回收站更糟。搬空原行则既有全部
/// 查询自动正确，"回收站可见"这件事由表结构本身保证。
///
/// payload 存 drift 的 `Transaction.toJson()`：transactions 以后加列，
/// 归档与恢复都自动跟随，无需维护列清单。恢复时按 tx_id 原样回写
/// (AUTOINCREMENT 保证 id 不被复用)，所以 transaction_tags /
/// transaction_attachments 的 int 外键在归档期间保持有效且**不删**——
/// 这同时是附件文件不被 30 天孤儿 GC 吃掉的前提(main.dart 的 GC 按
/// transaction_attachments 行判断引用)。
class DeletedTransactions extends Table {
  /// 原 transactions.id，同时作主键：一笔交易最多进一次回收站。
  IntColumn get txId => integer()();
  IntColumn get ledgerId => integer()();
  TextColumn get syncId => text().nullable()();

  /// 业务时间冗余列：回收站列表排序/展示用，不必解析 payload。
  DateTimeColumn get happenedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime()();
  TextColumn get payload => text()();

  @override
  Set<Column> get primaryKey => {txId};
}

// 交易-标签关联表
class TransactionTags extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get transactionId => integer()(); // 交易ID
  IntColumn get tagId => integer()(); // 标签ID
}

// v26: sync pull 时 server 端下发的 change 在本地 apply 抛错的持久化记录。
// 健康用户这张表是空的;只在出错时写入,供 UI 暴露 + 用户重试/跳过 + 开发者
// 远程诊断。详见 .docs/full-pull-refactor/04-data-model.md。
class SyncPullErrors extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get changeId => integer().unique()(); // server change_id,唯一
  TextColumn get ledgerExternalId =>
      text().nullable()(); // user-global change 可空
  TextColumn get entityType => text()();
  TextColumn get entitySyncId => text()();
  TextColumn get action => text()(); // upsert / delete
  TextColumn get rawChangeJson => text()(); // 完整 change JSON,供诊断 + 复制给用户
  TextColumn get errorClass => text().nullable()(); // Dart exception 类名
  TextColumn get errorMessage => text().nullable()(); // exception.toString() 首行
  TextColumn get stackTrace => text().nullable()(); // 截断到 ~2KB
  DateTimeColumn get firstSeenAt => dateTime()();
  DateTimeColumn get lastAttemptAt => dateTime()();
  IntColumn get attemptCount => integer().withDefault(const Constant(1))();
  TextColumn get userAction =>
      text().nullable()(); // null / 'skip' / 'retry_requested'
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

// 交易附件表
class TransactionAttachments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get transactionId => integer()(); // 关联的交易ID
  TextColumn get fileName => text()(); // 文件名（不含路径）
  TextColumn get originalName => text().nullable()(); // 原始文件名
  IntColumn get fileSize => integer().nullable()(); // 文件大小（bytes）
  IntColumn get width => integer().nullable()(); // 图片宽度
  IntColumn get height => integer().nullable()(); // 图片高度
  IntColumn get sortOrder => integer().withDefault(const Constant(0))(); // 排序序号
  TextColumn get cloudFileId => text().nullable()(); // 云端文件ID
  TextColumn get cloudSha256 => text().nullable()(); // 云端文件SHA256

  /// 本地文件内容 SHA256(hex)。v34 新增(attachment_binary_sync):
  /// 快照链路按内容寻址上传 `attachments/<sha256>.bin`,此列是清单锚点。
  /// 不复用 cloudSha256 —— 那是 Cloud server 回填的引用,两条链路混用会
  /// 互相污染。写入时机:saveAttachment 计算文件名时同步落列;
  /// 存量行由启动后台任务 backfillLocalSha256 分批补齐。
  TextColumn get localSha256 => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// 预算表
class Budgets extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 跨设备同步 syncId(UUID)。v22 新增,migration 给老行补 UUID;之后每次 create
  /// 都必须填。server 端按此做 entity_sync_id,跨设备 LWW 合并。
  TextColumn get syncId => text().nullable()();

  /// 关联账本ID
  IntColumn get ledgerId => integer()();

  /// 预算类型：total-总预算, category-分类预算
  TextColumn get type => text().withDefault(const Constant('total'))();

  /// 关联分类ID（仅分类预算有值）
  IntColumn get categoryId => integer().nullable()();

  /// 预算金额
  RealColumn get amount => real()();

  /// 预算周期：monthly-月度, weekly-周度, yearly-年度
  TextColumn get period => text().withDefault(const Constant('monthly'))();

  /// 周期起始日（1-31，月度预算；1-7，周度预算）
  IntColumn get startDay => integer().withDefault(const Constant(1))();

  /// 是否启用
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 更新时间
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// v53: 储蓄目标(账本私有) —— 见 prd/savings_goal/requirements.md §4.1 / design.md §1.1。
// 进度来源二选一(互斥):
// - accountId 非空 = **账户模式**:进度由该账户余额实时给出,币种恒等于账户币种
//   (锁定后无需视图期汇率折算,进度条不随行情抖动);
// - accountId 为空 = **手动模式**:进度读 savedAmount,UI 用「存入/取出」调整。
// 刻意不做存入明细表:本模块只回答「离目标还差多少」,不做流水账。
class SavingsGoals extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 跨设备同步 syncId(UUID)。新建必填,server 端按此做 entity_sync_id,
  /// 跨设备 LWW 合并(与 budgets.sync_id 同构)。
  TextColumn get syncId => text().nullable()();

  /// 关联账本ID。ledger-scoped 实体:变更走
  /// `ChangeTracker.recordLedgerChange` 且 ledgerId 必须 > 0,ledger_id 同时是
  /// 快照段门控(sectionAbsent)的作用域依据。
  IntColumn get ledgerId => integer()();

  /// 目标名称
  TextColumn get name => text()();

  /// 目标金额
  RealColumn get targetAmount => real()();

  /// 目标币种(ISO 大写)。账户模式下由 UI 强制等于关联账户币种。
  TextColumn get currency => text().withDefault(const Constant('CNY'))();

  /// 关联储蓄账户(账户模式)。账户被删除时**置 NULL** 降级为手动模式,
  /// 不级联删除目标(见 design.md §1.4)。
  IntColumn get accountId => integer().nullable()();

  /// 手动累计额(仅 accountId 为空时生效)
  RealColumn get savedAmount => real().withDefault(const Constant(0.0))();

  /// 起算日(速度估算基准)
  DateTimeColumn get startDate => dateTime().withDefault(currentDateAndTime)();

  /// 期望达成日(nullable,仅用于对照展示,不做校验)
  DateTimeColumn get targetDate => dateTime().nullable()();

  /// 备注
  TextColumn get note => text().nullable()();

  /// 排序(预留,UI 本批按创建顺序展示)
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 更新时间(由 trg_savings_goals_touch_updated_at 触发器维护)
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// ============================================================================
// 共享账本(v24) — 已彻底移除
// ============================================================================

// [共享账本已下线] 共享账本协作(PiggyCount Cloud)已整体下线且项目无老用户,
// 2026-10-08 起残留由迁移整批 DROP:ledger_members(v50)、shared_ledger_
// {categories,accounts,tags} 三张镜像表、transaction_tag_overrides、ledgers 与
// transactions 上的全部共享专属列(均 v51)。相关代码(picker synthetic 替换机制、
// override 写入/回显、Editor 权限门控)已同步删除,勿再新增引用。

@DriftDatabase(tables: [
  Ledgers,
  Accounts,
  // v52：投资持仓（user-global，与 Accounts 同款全量随快照导出）
  Holdings,
  Categories,
  Transactions,
  RecurringTransactions,
  Conversations,
  Messages,
  Tags,
  CustomFieldDefinitions,
  TransactionTags,
  Budgets,
  // v53：储蓄目标（ledger-scoped，随所属账本快照导出）
  SavingsGoals,
  TransactionAttachments,
  LocalChanges,
  SyncPullErrors,
  ExchangeRates,
  ExchangeRateOverrides,
  EntityChangeWatermarks,
  SyncOpLog,
  StaleRemoteSlots,
  DeletedTransactions,
  // v49：本地缓存类表（非同步实体，见表定义处注释）
  HolidayEntries,
  HolidayUpdateMeta,
])
class PiggyDatabase extends _$PiggyDatabase {
  PiggyDatabase() : super(_openConnection());

  /// 测试专用:直接注入 [QueryExecutor](通常是 NativeDatabase.memory()),
  /// 跳过 [_openConnection] 的文件系统 / 平台副作用。test/ 下的 unit test
  /// 用这个。
  PiggyDatabase.forTesting(super.executor);

  @override
  int get schemaVersion =>
      53; // v53: 储蓄目标(账本私有) — savings_goals 表(ledger_id/name/target_amount/currency/account_id/saved_amount/start_date/target_date/note/sort_order/sync_id):进度来源二选一,account_id 非空=账户模式(进度=该账户余额,币种锁账户币种,故无视图期汇率折算),为空=手动模式(进度=saved_amount,UI「存入/取出」调整);账户删除时 account_id 置 NULL 降级为手动模式,不级联删目标;刻意不建存入明细表(只回答「离目标还差多少」);ledger-scoped 同步实体,快照格式同批 v11→v12(新增 savingsGoals 段 + 段门控 sectionAbsent('savingsGoals', 12)); v52: 投资持仓(手动估值版) — holdings 表:投资账户金额改由 Σ(份额×生效净值) 接管,无持仓时回退 initial_balance(绝不双计);同批一次性预留行情接入字段(market/auto_quote 可同步,quote_price/quote_fetched_at/quote_source_id 为**本地专有缓存列**,不进快照/指纹/local_changes),后期接 A股/美股/加密行情源无需再升 schema 与快照格式版本； v51: 共享账本残留整体移除 — DROP shared_ledger_{categories,accounts,tags} / transaction_tag_overrides 四张死表(镜像表无写入方恒空) + ledgers(my_role/member_count/is_shared/owner_user_id) 与 transactions(category/account/to_account_sync_id_override + tag_sync_ids_override 死列) 八个共享专属列;同步契约三件套(指纹/快照/diff)与守门测试同批收窄; v50: 删除 ledger_members 死表(全库零读写;共享账本协作下线且项目无老用户,无需存量兼容); v49: 日历节假日本地缓存 — holiday_entries(date 主键,整年替换) + holiday_update_meta(单行 1:上次成功/尝试时间、连续失败数、自动更新开关);两张表都是「随时可整表重建」的本地缓存,不进同步白名单/指纹/diff/备份,也不挂 updated_at 触发器(与 exchange_rates 同定位) v48: 索引修复型迁移 — 补建 v10/v11/v12 只写进 onUpgrade 分支、onCreate 遗漏的 transaction_tags ×2 / budgets ×3 / transaction_attachments ×1 索引(2026-09-26 双端实测:新装库 EXPLAIN 报 SCAN transaction_tags,合并路径 tag 批量读固定 ~0.5s); v47: 周期账单模板自定义字段值 recurring_transactions.template_field_values({fieldSyncId: value} JSON 对象,生成实例时注入); v46: 账本自定义字段 — custom_field_definitions(按账本独立定义名称/类型/排序) + transactions.custom_values_json({fieldSyncId: value} JSON 对象,不参与列表/统计); v45: 账本明细原始金额 transactions.original_amount(用户手填,NULL=未填写即按记账金额); v44: 回收站 deleted_transactions(F1 交易建模,软删除搬行而非加列); v43: 同步指标 sync_op_log(审计 P0-1,本地成功率测量) + stale_remote_slots(审计 P1-6,换名收尾补删持久化); v42: 周期账单币种 — recurring_transactions.currency_code(移植 BeeCount #444); v41: local_changes 已推送行存量清理(数据治理 G-LC,双后端实测 6143 行无界增长); v40: transactions/categories/tags/ledgers 补 updated_at 列+UPDATE 触碰触发器(审计 T1); v39: local_changes (ledger_id,pushed_at) 查询索引(审计 C7); v38: 各实体 sync_id 唯一索引(审计 TBL-M1); v37: DROP 死表 sync_state(Supabase 增量游标残留,零读写方); v36: entity_change_watermarks 实体水位表(审计 S3); v35: local_changes 部分唯一索引(F2 加固)

  /// WAL 检查点后允许残留的字节数（见 [migration] 的 beforeOpen）。
  /// 公开给回归测试取期望值，别处不要依赖。
  static const int walRetainBytes = 8 * 1024 * 1024;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        // M18（B10）连接级 PRAGMA 显式化。库跑在 `_openConnection` 起的**第二个
        // isolate**里，而 PRAGMA 是 per-connection 的 —— 挂在 beforeOpen（drift
        // 每次打开这条连接都会走）即可覆盖每条连接。
        // 2026-10-05 更正一条旧注释：`setup` 与 `createInBackground` **并不互斥** ——
        // drift 2.35.0 的 createInBackground 就有 `DatabaseSetup? setup` 形参（官方
        // 注释即"给 SQLCipher 设密钥"用的）。本仓仍用 beforeOpen 是**分工**问题：
        // `setup` 在 drift 就绪之前执行、拿不到库对象；`beforeOpen` 拿到库后跑，
        // 语义正好。`DatabaseConnection.custom` + 手动 spawn 仍不采用 —— 它会绕开
        // database_health_service 的 quick_check 通路。
        beforeOpen: (detail) async {
          // WAL：写放大从"每改一页复制整页回滚日志"降成追加 -wal，读也不再被写挡。
          // **synchronous 保持默认 FULL**：WAL+FULL 仍然每次提交 fsync，掉电不丢最后
          // 几笔；换 NORMAL 是拿账本数据换写入速度，一个记账 app 不该做这个交易。
          await customStatement('PRAGMA journal_mode=WAL');
          // -wal 检查点后的保留上限（**磁盘**占用，不是内存）：不设时一次批量导入
          // 把 -wal 顶到几十 MB 后就不回落了。
          await customStatement('PRAGMA journal_size_limit=$walRetainBytes');
          // **故意不开** cache_size / mmap_size：那是拿内存换读盘（RSS 可能 +8~24MB），
          // 与本轮降内存的目标反向。方案给这项定的门禁是"B6 真机基线之后再判"，
          // 基线还没跑（无设备），所以留 **TODO-M18**。
        },
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            // 添加 sortOrder 字段（使用原始 SQL，因为此时代码还未生成）
            await customStatement(
                'ALTER TABLE categories ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;');

            // 为现有分类设置默认的 sortOrder（按 id 顺序）
            await customStatement('''
          UPDATE categories
          SET sort_order = (
            SELECT COUNT(*)
            FROM categories AS c2
            WHERE c2.id <= categories.id
          ) - 1;
        ''');
          }
          if (from < 3) {
            // 创建重复交易表
            await migrator.createTable(recurringTransactions);

            // 为 transactions 表添加 recurring_id 字段
            await customStatement(
                'ALTER TABLE transactions ADD COLUMN recurring_id INTEGER;');
          }
          if (from < 4) {
            // 为 accounts 表添加 initial_balance 字段
            await customStatement(
                'ALTER TABLE accounts ADD COLUMN initial_balance REAL NOT NULL DEFAULT 0.0;');
          }
          if (from < 5) {
            // v5: 账户独立改造
            // 注意：数据迁移逻辑在 MigrationService 中统一处理
            // 这里只添加必要的字段

            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            final hasCurrency =
                tableInfo.any((row) => row.data['name'] == 'currency');
            final hasCreatedAt =
                tableInfo.any((row) => row.data['name'] == 'created_at');
            final hasUpdatedAt =
                tableInfo.any((row) => row.data['name'] == 'updated_at');

            if (!hasCurrency) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN currency TEXT NOT NULL DEFAULT \'CNY\';');
            }

            if (!hasCreatedAt) {
              // SQLite 不支持非常量默认值，先添加可空字段，然后更新
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN created_at INTEGER;');
              await customStatement(
                  'UPDATE accounts SET created_at = strftime(\'%s\', \'now\') WHERE created_at IS NULL;');
            }

            if (!hasUpdatedAt) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN updated_at INTEGER;');
            }

            // 注意：不在onUpgrade中更新currency数据
            // 数据迁移统一由 MigrationService 处理，避免重复逻辑
          }
          if (from < 6) {
            // v6: 二级分类支持
            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(categories)').get();
            final hasParentId =
                tableInfo.any((row) => row.data['name'] == 'parent_id');
            final hasLevel =
                tableInfo.any((row) => row.data['name'] == 'level');

            if (!hasParentId) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN parent_id INTEGER;');
            }

            if (!hasLevel) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN level INTEGER NOT NULL DEFAULT 1;');
            }

            // 确保所有现有分类的 level 都为 1（一级分类）
            await customStatement(
                'UPDATE categories SET level = 1 WHERE level IS NULL OR level = 0;');
          }
          if (from < 7) {
            logger.info('DB', '[DB Migration] 开始迁移到 v7: 周期账单支持转账');
            // v7: 周期账单支持转账
            // 需要将 category_id 改为可空，并添加 to_account_id 字段
            // SQLite 不支持修改列约束，所以需要重建表

            // 1. 创建新表
            logger.info('DB', '[DB Migration] 步骤1: 创建新表');
            await customStatement('''
              CREATE TABLE IF NOT EXISTS recurring_transactions_new (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                ledger_id INTEGER NOT NULL,
                type TEXT NOT NULL,
                amount REAL NOT NULL,
                category_id INTEGER,
                account_id INTEGER,
                to_account_id INTEGER,
                note TEXT,
                frequency TEXT NOT NULL,
                interval INTEGER NOT NULL DEFAULT 1,
                day_of_month INTEGER,
                day_of_week INTEGER,
                month_of_year INTEGER,
                start_date INTEGER NOT NULL,
                end_date INTEGER,
                last_generated_date INTEGER,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
              );
            ''');

            // 2. 复制数据
            logger.info('DB', '[DB Migration] 步骤2: 复制数据');
            await customStatement('''
              INSERT INTO recurring_transactions_new
              (id, ledger_id, type, amount, category_id, account_id, to_account_id, note,
               frequency, interval, day_of_month, day_of_week, month_of_year,
               start_date, end_date, last_generated_date, enabled, created_at, updated_at)
              SELECT id, ledger_id, type, amount, category_id, account_id,
                     NULL as to_account_id, note,
                     frequency, interval, day_of_month, day_of_week, month_of_year,
                     start_date, end_date, last_generated_date, enabled, created_at, updated_at
              FROM recurring_transactions;
            ''');

            // 3. 删除旧表
            logger.info('DB', '[DB Migration] 步骤3: 删除旧表');
            await customStatement('DROP TABLE recurring_transactions;');

            // 4. 重命名新表
            logger.info('DB', '[DB Migration] 步骤4: 重命名新表');
            await customStatement(
                'ALTER TABLE recurring_transactions_new RENAME TO recurring_transactions;');
            logger.info('DB', '[DB Migration] v7 迁移完成');
          }
          if (from < 8) {
            // v8: AI 对话助手
            logger.info('DB', '[DB Migration] 开始迁移到 v8: AI 对话助手');
            await migrator.createTable(conversations);
            await migrator.createTable(messages);
            logger.info('DB', 'v8 迁移完成: AI Chat tables created');
            logger.info('DB', '[DB Migration] v8 迁移完成');
          }
          if (from < 9) {
            // v9: 为 ledgers 表添加 type 字段（支持家庭账本）
            logger.info('DB', '[DB Migration] 开始迁移到 v9: 添加 ledgers.type 字段');

            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(ledgers)').get();
            final hasType = tableInfo.any((row) => row.data['name'] == 'type');

            if (!hasType) {
              await customStatement(
                  'ALTER TABLE ledgers ADD COLUMN type TEXT NOT NULL DEFAULT \'personal\';');
              logger.info('DB', 'v9 迁移完成: ledgers.type 字段已添加');
            } else {
              logger.info('DB', 'v9 迁移跳过: ledgers.type 字段已存在');
            }

            logger.info('DB', '[DB Migration] v9 迁移完成');
          }
          if (from < 10) {
            // v10: 添加标签功能
            logger.info('DB', '[DB Migration] 开始迁移到 v10: 添加标签功能');

            // 创建 tags 表
            await migrator.createTable(tags);
            logger.info('DB', 'v10: tags 表已创建');

            // 创建 transaction_tags 关联表
            await migrator.createTable(transactionTags);
            logger.info('DB', 'v10: transaction_tags 表已创建');

            // 创建索引以提高查询性能
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transaction_tags_transaction ON transaction_tags(transaction_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag ON transaction_tags(tag_id)');
            logger.info('DB', 'v10: 索引已创建');

            logger.info('DB', '[DB Migration] v10 迁移完成');
          }
          if (from < 11) {
            // v11: 添加预算功能
            logger.info('DB', '[DB Migration] 开始迁移到 v11: 添加预算功能');

            // 创建 budgets 表
            await migrator.createTable(budgets);
            logger.info('DB', 'v11: budgets 表已创建');

            // 创建索引以提高查询性能
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_ledger ON budgets(ledger_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_category ON budgets(category_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_ledger_type ON budgets(ledger_id, type)');
            logger.info('DB', 'v11: 预算索引已创建');

            logger.info('DB', '[DB Migration] v11 迁移完成');
          }
          if (from < 12) {
            // v12: 添加交易附件功能
            logger.info('DB', '[DB Migration] 开始迁移到 v12: 添加交易附件功能');

            // 创建 transaction_attachments 表
            await migrator.createTable(transactionAttachments);
            logger.info('DB', 'v12: transaction_attachments 表已创建');

            // 创建索引以提高查询性能
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_attachments_transaction ON transaction_attachments(transaction_id)');
            logger.info('DB', 'v12: 附件索引已创建');

            logger.info('DB', '[DB Migration] v12 迁移完成');
          }
          if (from < 13) {
            // v13: 分类自定义图标支持
            logger.info('DB', '[DB Migration] 开始迁移到 v13: 分类自定义图标支持');

            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(categories)').get();
            final hasIconType =
                tableInfo.any((row) => row.data['name'] == 'icon_type');
            final hasCustomIconPath =
                tableInfo.any((row) => row.data['name'] == 'custom_icon_path');
            final hasCommunityIconId =
                tableInfo.any((row) => row.data['name'] == 'community_icon_id');

            if (!hasIconType) {
              await customStatement(
                  "ALTER TABLE categories ADD COLUMN icon_type TEXT NOT NULL DEFAULT 'material';");
              logger.info('DB', 'v13: icon_type 字段已添加');
            }

            if (!hasCustomIconPath) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN custom_icon_path TEXT;');
              logger.info('DB', 'v13: custom_icon_path 字段已添加');
            }

            if (!hasCommunityIconId) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN community_icon_id TEXT;');
              logger.info('DB', 'v13: community_icon_id 字段已添加');
            }

            logger.info('DB', '[DB Migration] v13 迁移完成');
          }
          if (from < 14) {
            // v14: 迁移转账记录到虚拟转账分类
            logger.info('DB', '[DB Migration] 开始迁移到 v14: 迁移转账记录到虚拟转账分类');
            await SeedService.migrateTransferTransactions(this);
            logger.info('DB', 'v14 迁移完成: 转账记录已关联到虚拟转账分类');
            logger.info('DB', '[DB Migration] v14 迁移完成');
          }
          if (from < 15) {
            // v15: 交易添加 syncId 用于云同步
            logger.info('DB', '[DB Migration] 开始迁移到 v15: 添加 syncId 字段');

            // 1. 添加 sync_id 列
            await customStatement(
                'ALTER TABLE transactions ADD COLUMN sync_id TEXT;');
            logger.info('DB', 'v15: sync_id 字段已添加');

            // 2. 为所有已有交易生成 UUID v4
            // 使用 SQLite 内置函数生成简易唯一ID（hex + random）
            // 格式: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
            await customStatement('''
              UPDATE transactions SET sync_id =
                lower(hex(randomblob(4))) || '-' ||
                lower(hex(randomblob(2))) || '-4' ||
                substr(lower(hex(randomblob(2))),2) || '-' ||
                substr('89ab', abs(random()) % 4 + 1, 1) ||
                substr(lower(hex(randomblob(2))),2) || '-' ||
                lower(hex(randomblob(6)))
              WHERE sync_id IS NULL;
            ''');
            logger.info('DB', 'v15: 已为现有交易回填 syncId');

            // 3. 创建索引
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transactions_sync_id ON transactions(sync_id);');
            logger.info('DB', 'v15: syncId 索引已创建');

            logger.info('DB', '[DB Migration] v15 迁移完成');
          }
          if (from < 16) {
            // v16: 账户添加 sortOrder 排序字段
            logger.info('DB', '[DB Migration] 开始迁移到 v16: 账户排序');

            await customStatement(
                'ALTER TABLE accounts ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;');
            logger.info('DB', 'v16: sort_order 字段已添加');

            // 回填：按 type 分组，组内按 created_at 排序赋值 sortOrder
            await customStatement('''
              UPDATE accounts SET sort_order = (
                SELECT COUNT(*)
                FROM accounts AS a2
                WHERE a2.type = accounts.type
                  AND (a2.created_at < accounts.created_at
                       OR (a2.created_at = accounts.created_at AND a2.id < accounts.id)
                       OR (a2.created_at IS NULL AND accounts.created_at IS NOT NULL)
                       OR (a2.created_at IS NULL AND accounts.created_at IS NULL AND a2.id < accounts.id))
              );
            ''');
            logger.info('DB', 'v16: 已为现有账户回填 sortOrder');

            logger.info('DB', '[DB Migration] v16 迁移完成');
          }
          if (from < 17) {
            // v17: 账户添加信用卡字段
            logger.info('DB', '[DB Migration] 开始迁移到 v17: 信用卡字段');

            final tableInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            final hasCreditLimit =
                tableInfo.any((row) => row.data['name'] == 'credit_limit');
            final hasBillingDay =
                tableInfo.any((row) => row.data['name'] == 'billing_day');
            final hasPaymentDueDay =
                tableInfo.any((row) => row.data['name'] == 'payment_due_day');

            if (!hasCreditLimit) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN credit_limit REAL;');
              logger.info('DB', 'v17: credit_limit 字段已添加');
            }

            if (!hasBillingDay) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN billing_day INTEGER;');
              logger.info('DB', 'v17: billing_day 字段已添加');
            }

            if (!hasPaymentDueDay) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN payment_due_day INTEGER;');
              logger.info('DB', 'v17: payment_due_day 字段已添加');
            }

            logger.info('DB', '[DB Migration] v17 迁移完成');
          }
          if (from < 18) {
            // v18: 账户添加元信息字段
            logger.info('DB', '[DB Migration] 开始迁移到 v18: 账户元信息');

            final tableInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            final hasBankName =
                tableInfo.any((row) => row.data['name'] == 'bank_name');
            final hasCardLastFour =
                tableInfo.any((row) => row.data['name'] == 'card_last_four');
            final hasNote = tableInfo.any((row) => row.data['name'] == 'note');

            if (!hasBankName) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN bank_name TEXT;');
              logger.info('DB', 'v18: bank_name 字段已添加');
            }

            if (!hasCardLastFour) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN card_last_four TEXT;');
              logger.info('DB', 'v18: card_last_four 字段已添加');
            }

            if (!hasNote) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN note TEXT;');
              logger.info('DB', 'v18: note 字段已添加');
            }

            logger.info('DB', '[DB Migration] v18 迁移完成');
          }
          if (from < 19) {
            // v19: 同步基础设施
            logger.info('DB', '[DB Migration] 开始迁移到 v19: 同步基础设施');

            // 1. 为 accounts 添加 sync_id
            final accountInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            if (!accountInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN sync_id TEXT;');
              // 回填 UUID
              await customStatement('''
                UPDATE accounts SET sync_id =
                  lower(hex(randomblob(4))) || '-' ||
                  lower(hex(randomblob(2))) || '-4' ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  substr('89ab', abs(random()) % 4 + 1, 1) ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  lower(hex(randomblob(6)))
                WHERE sync_id IS NULL;
              ''');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_accounts_sync_id ON accounts(sync_id);');
              logger.info('DB', 'v19: accounts.sync_id 已添加并回填');
            }

            // 2. 为 categories 添加 sync_id
            final categoryInfo =
                await customSelect('PRAGMA table_info(categories)').get();
            if (!categoryInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN sync_id TEXT;');
              await customStatement('''
                UPDATE categories SET sync_id =
                  lower(hex(randomblob(4))) || '-' ||
                  lower(hex(randomblob(2))) || '-4' ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  substr('89ab', abs(random()) % 4 + 1, 1) ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  lower(hex(randomblob(6)))
                WHERE sync_id IS NULL;
              ''');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_categories_sync_id ON categories(sync_id);');
              logger.info('DB', 'v19: categories.sync_id 已添加并回填');
            }

            // 3. 为 tags 添加 sync_id
            final tagInfo = await customSelect('PRAGMA table_info(tags)').get();
            if (!tagInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE tags ADD COLUMN sync_id TEXT;');
              await customStatement('''
                UPDATE tags SET sync_id =
                  lower(hex(randomblob(4))) || '-' ||
                  lower(hex(randomblob(2))) || '-4' ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  substr('89ab', abs(random()) % 4 + 1, 1) ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  lower(hex(randomblob(6)))
                WHERE sync_id IS NULL;
              ''');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_tags_sync_id ON tags(sync_id);');
              logger.info('DB', 'v19: tags.sync_id 已添加并回填');
            }

            // 4. 创建 local_changes 表
            await migrator.createTable(localChanges);
            logger.info('DB', 'v19: local_changes 表已创建');

            // （历史上的第 5 步 sync_state 建表已移除：该表 v37 起 DROP，
            //   不再属于 schema。）

            logger.info('DB', '[DB Migration] v19 迁移完成');
          }
          if (from < 20) {
            // v20: 附件云端同步字段
            logger.info('DB', '[DB Migration] 开始迁移到 v20: 附件云端同步字段');

            final tableInfo =
                await customSelect('PRAGMA table_info(transaction_attachments)')
                    .get();
            final hasCloudFileId =
                tableInfo.any((row) => row.data['name'] == 'cloud_file_id');
            final hasCloudSha256 =
                tableInfo.any((row) => row.data['name'] == 'cloud_sha256');

            if (!hasCloudFileId) {
              await customStatement(
                  'ALTER TABLE transaction_attachments ADD COLUMN cloud_file_id TEXT;');
              logger.info('DB', 'v20: cloud_file_id 字段已添加');
            }

            if (!hasCloudSha256) {
              await customStatement(
                  'ALTER TABLE transaction_attachments ADD COLUMN cloud_sha256 TEXT;');
              logger.info('DB', 'v20: cloud_sha256 字段已添加');
            }

            logger.info('DB', '[DB Migration] v20 迁移完成');
          }
          if (from < 21) {
            // v21: ledgers 加 syncId（跨设备同步 ledger 匹配）
            logger.info('DB', '[DB Migration] 开始迁移到 v21: ledgers.sync_id');

            final ledgerInfo =
                await customSelect('PRAGMA table_info(ledgers)').get();
            if (!ledgerInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE ledgers ADD COLUMN sync_id TEXT;');
              // 把现有 ledger.id 回填成 syncId（转字符串）。这样旧 A 设备已推
              // 到 server 的 external_id（= 当时的 id.toString()）对得上新列，
              // 后续 push/pull 都走 syncId，无脑兼容。
              await customStatement(
                  "UPDATE ledgers SET sync_id = CAST(id AS TEXT) WHERE sync_id IS NULL;");
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_ledgers_sync_id ON ledgers(sync_id);');
              logger.info('DB', 'v21: ledgers.sync_id 已添加并回填');
            }

            logger.info('DB', '[DB Migration] v21 迁移完成');
          }
          if (from < 22) {
            // v22: budgets 加 syncId(跨设备同步 budget 匹配)
            logger.info('DB', '[DB Migration] 开始迁移到 v22: budgets.sync_id');

            final budgetInfo =
                await customSelect('PRAGMA table_info(budgets)').get();
            if (!budgetInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE budgets ADD COLUMN sync_id TEXT;');
              // SQLite 没有原生 UUID。用 lower(hex(randomblob(16))) 造 32 位
              // 随机 hex,足够当 server entity_sync_id 用。格式跟 UUID 不是
              // 标准 36 位,但 server 侧校验只要求非空字符串。
              await customStatement(
                  "UPDATE budgets SET sync_id = lower(hex(randomblob(16))) WHERE sync_id IS NULL;");
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_budgets_sync_id ON budgets(sync_id);');
              logger.info('DB', 'v22: budgets.sync_id 已添加并回填');
            }

            logger.info('DB', '[DB Migration] v22 迁移完成');
          }
          if (from < 23) {
            // v23: 清理"分类图标靠 getCategoryIconByName 运行时推导"的毒瘤代码。
            // 历史上 `category.icon` 允许为 null/空,渲染时走 `getCategoryIconByName`
            // 按中文关键字模糊匹配回退推导图标。这个方案:
            //   - 改名就换图标(用户会懵)
            //   - 只认中文,英语/繁中走不到
            //   - web/server 必须复刻同一套 40 条正则,维护两份
            // v23 一次性把 icon IS NULL/'' 的分类按 byName 推算出结果写回 DB,
            // 之后渲染层 getCategoryIconData 只认 icon 字段、不再 byName 推导。
            // 结合服务端 alembic 0002 的同名 backfill,两端同步"迁 read-time 到
            // write-time"。
            logger.info('DB',
                '[DB Migration] 开始迁移到 v23: backfill category icons via byName');

            // 取所有 icon 空的分类,按 name 推导图标字符串回填
            final rows = await customSelect(
              "SELECT id, name FROM categories WHERE icon IS NULL OR icon = ''",
            ).get();
            var updated = 0;
            for (final row in rows) {
              final id = row.data['id'] as int;
              final name = row.data['name'] as String? ?? '';
              // 用 CategoryService.resolveIconNameByName(类似原 getCategoryIconByName
              // 但返回字符串名)一次性固化到 DB。此后渲染不再 byName。
              final iconName = CategoryService.resolveIconNameByName(name);
              await customStatement(
                'UPDATE categories SET icon = ? WHERE id = ?',
                [iconName, id],
              );
              updated++;
            }
            logger.info('DB', 'v23: backfilled $updated categories');
            logger.info('DB', '[DB Migration] v23 迁移完成: 回填 $updated 条分类');
          }
          if (from < 24) {
            // v24 原为共享账本完整 schema。该功能已整体移除(残留由 v51 统一
            // DROP 兜底,此处不再重建),本块仅保留仍有效的交易记录人两列。
            //
            // 重要:所有 ALTER 都包"存在则跳过"防御 — 用户从
            // 3.1.3 升级到带 bug 的 3.2.0 时 v25 ALTER 失败,但 v24 的 DDL
            // 已经隐式 commit(SQLite DDL 不可回滚),user_version 仍 23。
            // 装新版本再跑 onUpgrade(from=23) 时 v24 第一句又会 duplicate column
            // 卡死。每条都要幂等。
            logger.info('DB', '[DB Migration] 开始迁移到 v24: 交易记录人列');

            await _addColumnIfMissing('transactions', 'created_by_user_id',
                "ALTER TABLE transactions ADD COLUMN created_by_user_id TEXT;");
            await _addColumnIfMissing('transactions', 'last_edited_by_user_id',
                "ALTER TABLE transactions ADD COLUMN last_edited_by_user_id TEXT;");

            logger.info('DB', '[DB Migration] v24 迁移完成');
          }
          if (from < 26) {
            // v26: 新增 sync_pull_errors 表。健康用户为空,只在 pull apply
            // 抛错时写入,UI 据此显示"同步异常"banner + 重试/跳过操作。
            // 详见 .docs/full-pull-refactor/04-data-model.md
            logger.info('DBMigration', '开始迁移到 v26: sync_pull_errors');
            await _createTableIfMissing(
                migrator, 'sync_pull_errors', syncPullErrors);
            logger.info('DBMigration', 'v26 迁移完成');
          }
          if (from < 27) {
            logger.info('DBMigration', '开始迁移到 v27: ledgers.month_start_day');
            // v27: 账本自定义每月起始日(1-28),默认 1=自然月
            // W5:改走幂等 helper。裸 ALTER 在 partial state 重跑(上次迁移
            // 中途崩溃)时会 duplicate column 卡死,违反本项目迁移纪律。
            await _addColumnIfMissing('ledgers', 'month_start_day',
                'ALTER TABLE ledgers ADD COLUMN month_start_day INTEGER NOT NULL DEFAULT 1;');
            logger.info('DBMigration', 'v27 迁移完成');
          }
          if (from < 28) {
            logger.info('DBMigration',
                '开始迁移到 v28: 多币种 MVP(exchange_rates / exchange_rate_overrides)');
            await _createTableIfMissing(
                migrator, 'exchange_rates', exchangeRates);
            await _createTableIfMissing(
                migrator, 'exchange_rate_overrides', exchangeRateOverrides);
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_override_pair '
                'ON exchange_rate_overrides (base_currency, quote_currency);');
            logger.info('DBMigration', 'v28 迁移完成');
          }
          if (from < 29) {
            logger.info('DBMigration', '开始迁移到 v29: 账单标记(不计入收支/不计入预算)');
            await _addColumnIfMissing('transactions', 'exclude_from_stats',
                'ALTER TABLE transactions ADD COLUMN exclude_from_stats INTEGER NOT NULL DEFAULT 0;');
            await _addColumnIfMissing('transactions', 'exclude_from_budget',
                'ALTER TABLE transactions ADD COLUMN exclude_from_budget INTEGER NOT NULL DEFAULT 0;');
            logger.info('DBMigration', 'v29 迁移完成');
          }
          if (from < 30) {
            logger.info('DBMigration',
                '开始迁移到 v30: 交易级多币种(currency_code + native_amount)');
            await _addColumnIfMissing('transactions', 'currency_code',
                'ALTER TABLE transactions ADD COLUMN currency_code TEXT;');
            await _addColumnIfMissing('transactions', 'native_amount',
                'ALTER TABLE transactions ADD COLUMN native_amount REAL;');
            // 回填:currency_code = 账户币种(无账户 → 账本本位币);
            // native_amount = amount(隐含汇率 1.0)→ 单币种账本统计结果不变。
            // ⚠️ SQL 与 test/data/migration_v30_test.dart 的常量保持一字不差。
            await customStatement('''
    UPDATE transactions SET currency_code = COALESCE(
      (SELECT a.currency FROM accounts a WHERE a.id = transactions.account_id),
      (SELECT l.currency FROM ledgers l WHERE l.id = transactions.ledger_id),
      'CNY')
    WHERE currency_code IS NULL;''');
            await customStatement(
                'UPDATE transactions SET native_amount = amount WHERE native_amount IS NULL;');
            logger.info('DBMigration', 'v30 迁移完成');
          }
          if (from < 31) {
            logger.info('DBMigration', '开始迁移到 v31: 账户隐藏(hidden)');
            await _addColumnIfMissing('accounts', 'hidden',
                'ALTER TABLE accounts ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;');
            logger.info('DBMigration', 'v31 迁移完成');
          }
          if (from < 32) {
            // v32:为最高频查询模式 WHERE ledger_id=? AND happened_at>=? AND
            // happened_at<? ORDER BY happened_at DESC 加复合索引。SQLite 复合
            // 索引前缀匹配 + 索引天然有序,同时加速 filter 与 orderBy,消除月度/
            // 年度/日期范围查询的全表扫描。CREATE INDEX IF NOT EXISTS 幂等。
            logger.info('DBMigration', '开始迁移到 v32: transactions 复合索引');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_happened '
                'ON transactions(ledger_id, happened_at);');
            logger.info('DBMigration', 'v32 迁移完成');
          }
          if (from < 33) {
            // v33: recurring_transactions 加 sync_id(sync_gap_closure G2)。
            // 周期规则此前双链路均不同步,换设备即丢;加列后快照 v8 / Cloud
            // 引擎(cloud_recurring_sync)都按此锚定实体。回填用 32 位随机
            // hex,与 v22 budgets 同款(SQLite 无原生 UUID,server 只要求非空)。
            logger.info(
                'DBMigration', '开始迁移到 v33: recurring_transactions.sync_id');
            await _addColumnIfMissing('recurring_transactions', 'sync_id',
                'ALTER TABLE recurring_transactions ADD COLUMN sync_id TEXT;');
            await customStatement(
                'UPDATE recurring_transactions SET sync_id = lower(hex(randomblob(16))) '
                'WHERE sync_id IS NULL;');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_recurring_sync_id '
                'ON recurring_transactions(sync_id);');
            logger.info('DBMigration', 'v33 迁移完成');
          }
          if (from < 34) {
            // v34: transaction_attachments 加 local_sha256(attachment_binary_sync)。
            // 只加列不回填 —— 读全量附件文件算哈希可能几百 MB I/O,放启动
            // 后台任务(attachment_service.backfillLocalSha256)分批执行,
            // 避免迁移卡启动。
            logger.info('DBMigration',
                '开始迁移到 v34: transaction_attachments.local_sha256');
            await _addColumnIfMissing('transaction_attachments', 'local_sha256',
                'ALTER TABLE transaction_attachments ADD COLUMN local_sha256 TEXT;');
            logger.info('DBMigration', 'v34 迁移完成');
          }
          if (from < 35) {
            // v35: local_changes 部分唯一索引(WHERE pushed_at IS NULL),为
            // (entity_type, entity_sync_id, action) 去重做 DB 层兜底。部分索引
            // 只约束未推送行 —— 已推送行(pushedAt 非空)退出索引,同实体同
            // action 的二次编辑(push 后再改)可正常插入,不误伤编辑流。
            // 代码层 backfill 去重已修(sync_engine_status.dart),此索引为
            // 第二道防线。详见 docs/sync-fix-drafts-2026-08-17.md F2 加固。
            //
            // 建索引前先清已存在的未推送重复行(保留 id 最小的一条),否则
            // CREATE UNIQUE INDEX 会因重复行失败。
            logger.info('DBMigration', '开始迁移到 v35: local_changes 部分唯一索引');
            await customStatement('''
              DELETE FROM local_changes
              WHERE rowid NOT IN (
                SELECT MIN(rowid) FROM local_changes
                WHERE pushed_at IS NULL
                GROUP BY entity_type, entity_sync_id, action
              )
              AND pushed_at IS NULL;
            ''');
            await customStatement('''
              CREATE UNIQUE INDEX IF NOT EXISTS idx_local_changes_unpushed_dedup
              ON local_changes (entity_type, entity_sync_id, action)
              WHERE pushed_at IS NULL;
            ''');
            logger.info('DBMigration', 'v35 迁移完成');
          }
          if (from < 36) {
            // v36: entity_change_watermarks 实体水位表（审计 S3）。
            // server change_id 全局单调；pull 应用成功与自设备回声都推进
            // 水位，应用前拦截 changeId ≤ 水位的陈旧重放，防止「先推后拉」
            // 窗口内旧远端值覆盖本地较新状态并反向污染服务端。
            logger.info(
                'DBMigration', '开始迁移到 v36: entity_change_watermarks 实体水位表');
            // W5:改走幂等 helper,理由同 v27(partial state 重跑防
            // table already exists 卡死)。
            await _createTableIfMissing(
                migrator, 'entity_change_watermarks', entityChangeWatermarks);
            logger.info('DBMigration', 'v36 迁移完成');
          }
          if (from < 37) {
            // v37: DROP 死表 sync_state。Supabase 增量同步时代的服务端游标
            // 表，全仓库零读写（游标后由旧增量引擎内存 + 水位表承载）。
            // DROP IF EXISTS 幂等：新装库（onCreate 走 createAll，本就没有
            // 此表）与极端 partial state 重跑均安全。
            logger.info('DBMigration', '开始迁移到 v37: DROP 死表 sync_state');
            await customStatement('DROP TABLE IF EXISTS sync_state');
            logger.info('DBMigration', 'v37 迁移完成');
          }
          if (from < 38) {
            // v38: 各实体 sync_id 唯一索引（审计 TBL-M1）。
            //
            // 此前 8 张表的 sync_id 只有普通索引，代码层（resolvers /
            // getTransactionBySyncId 等）却按唯一假设用 getSingleOrNull()
            // —— 一旦出现重复行（历史双链路导入竞态 / v21 回填撞号等），
            // pull 整页抛 "Too many elements" 回滚卡死。
            //
            // 建索引前先消除存量重复：**改写而非删除** —— 重复组内除最小
            // rowid 外的行回填新的随机 sync_id（v33 同款 lower(hex(...))）。
            // 相比删除的优势：不破坏 transactions 对 category/account/tag
            // 的引用、不丢任何业务数据；重复实体只是获得独立身份。
            for (final table in const [
              'ledgers',
              'accounts',
              'categories',
              'transactions',
              'tags',
              'budgets',
              'recurring_transactions',
              'exchange_rate_overrides',
            ]) {
              await customStatement(
                'UPDATE $table SET sync_id = lower(hex(randomblob(16))) '
                'WHERE sync_id IS NOT NULL AND rowid NOT IN ('
                '  SELECT MIN(rowid) FROM $table'
                '  WHERE sync_id IS NOT NULL'
                '  GROUP BY sync_id'
                ');',
              );
            }
            // 唯一索引与既有 idx_*_sync_id 普通索引并存（名字不同不冲突，
            // 普通索引继续服务非等值/前缀场景）。NULL sync_id 在 SQLite
            // UNIQUE 索引中互不冲突，legacy 未回填行不受影响。
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_ledgers_sync_id ON ledgers(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_accounts_sync_id ON accounts(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_categories_sync_id ON categories(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_transactions_sync_id ON transactions(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_tags_sync_id ON tags(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_budgets_sync_id ON budgets(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_recurring_sync_id ON recurring_transactions(sync_id);');
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_exchange_rate_overrides_sync_id ON exchange_rate_overrides(sync_id);');
            logger.info('DBMigration', 'v38 迁移完成: sync_id 唯一索引');
          }

          if (from < 39) {
            // v39: local_changes (ledger_id, pushed_at) 查询索引（审计 C7）。
            // push 前取队列（getUnpushedChangesForLedger）、方向仲裁证据
            // （_localChangeEvidence 的 unpushed 计数）、恢复清队列
            // （_purgeStaleLocalChanges）都高频走
            // `WHERE ledger_id IN (?, 0) [AND pushed_at IS NULL]`；
            // v35 部分唯一索引列序 (entity_type, entity_sync_id, action)
            // 对 ledger_id 过滤毫无帮助，长期运行设备上已推送行累积后
            // 每次同步前查询退化为全表扫描。
            logger.info('DBMigration',
                '开始迁移到 v39: local_changes (ledger_id, pushed_at) 索引');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_local_changes_ledger_pushed '
                'ON local_changes (ledger_id, pushed_at);');
            logger.info('DBMigration', 'v39 迁移完成: local_changes 查询索引');
          }
          if (from < 40) {
            // v40（审计 T1）:业务表补 updated_at + UPDATE 触碰触发器。
            // 此前 transactions/categories/tags/ledgers 完全没有 updated_at
            // （accounts 有列但几乎无人维护），本地无法做任何新旧判断，
            // 方向仲裁只能依赖 local_changes.created_at 会话证据 + 墙钟。
            // - 列可空，存量行保持 NULL =「本设备从未更新过」，不伪造时间；
            //   用户明确不考虑历史数据回填。
            // - 维护走 SQLite 触发器而非散落 ~30 处的应用层赋值 —— 后者
            //   正是 accounts.updated_at 沦为摆设的根因（漏一处即脏数据）。
            //   WHEN NEW IS OLD 守卫：显式写入不同值（未来 pull 回填远端
            //   时间戳）不被覆盖；内部自更新即使 recursive_triggers 开启
            //   也不会二次触发（新值 ≠ 旧值）。
            logger.info('DBMigration', '开始迁移到 v40: 业务表 updated_at 列 + 触碰触发器');
            for (final t in const {
              'transactions',
              'categories',
              'tags',
              'ledgers'
            }) {
              await _addColumnIfMissing(t, 'updated_at',
                  'ALTER TABLE $t ADD COLUMN updated_at INTEGER;');
            }
            await _createUpdatedAtTouchTriggers();
            logger.info('DBMigration', 'v40 迁移完成: updated_at 列 + 触发器');
          }
          if (from < 41) {
            // v41（数据治理 G-LC，双后端实测反馈）：清理 local_changes 已推送
            // 历史行。快照式同步（Path A）的 markSnapshotPushed 只标
            // pushed_at 不删行，应用层 cleanupPushedChanges（7 天保留）要
            // 到下一次上传成功才被调度——实测 A 端上传成功后 local_changes
            // 仍留着 6143 行注入时写入的量。已推送行对快照同步无消费方，
            // 一次性 DELETE 收敛存量（保留 server_marker 行 30 天窗语义：
            // 只清 30 天前的，窗口内的留给 ChangeTracker.cleanupPushedChanges
            // 的双保留窗逻辑统一处理）。
            logger.info('DBMigration', '开始迁移到 v41: 清理 local_changes 已推送历史行');
            await customStatement(
                "DELETE FROM local_changes WHERE pushed_at IS NOT NULL "
                "AND action != 'server_marker' "
                "AND pushed_at < strftime('%s','now') - 30*86400;");
            await customStatement(
                "DELETE FROM local_changes WHERE action = 'server_marker' "
                "AND pushed_at < strftime('%s','now') - 30*86400;");
            logger.info('DBMigration', 'v41 迁移完成: local_changes 存量收敛');
          }

          if (from < 42) {
            // v42(移植 BeeCount #444):周期账单模板币种。不回填 ——
            // NULL = 账本本位币/跟随账户,与迁移前生成行为一字不差。
            logger.info('DBMigration', '开始迁移到 v42: 周期账单币种(currency_code)');
            await _addColumnIfMissing('recurring_transactions', 'currency_code',
                'ALTER TABLE recurring_transactions ADD COLUMN currency_code TEXT;');
            logger.info('DBMigration', 'v42 迁移完成');
          }
          if (from < 43) {
            // v43(审计 P0-1/P1-6): 同步指标表 + 换名收尾补删持久化表。
            // 两表均为新增、零回填,用 drift 的 createTable 保持与生成代码
            // 一致的 DDL;m.createAll 已覆盖新装库,此处只管升级库。
            logger.info(
                'DBMigration', '开始迁移到 v43: sync_op_log + stale_remote_slots');
            await migrator.createTable(syncOpLog);
            await migrator.createTable(staleRemoteSlots);
            // 指标按时间窗口聚合,补 (ts) 索引避免 30 天窗口查询全表扫描。
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_sync_op_log_ts ON sync_op_log(ts);');
            logger.info('DBMigration', 'v43 迁移完成');
          }
          if (from < 44) {
            // v44(F1 回收站): deleted_transactions 表。纯新增、零回填，
            // 用 drift 的 createTable 保持与生成代码一致的 DDL(同 v43 先例)。
            // (ledger_id) 索引服务于「删账本 / 清空账本」时按账本 purge。
            logger.info('DBMigration', '开始迁移到 v44: deleted_transactions');
            await migrator.createTable(deletedTransactions);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_deleted_transactions_ledger '
                'ON deleted_transactions(ledger_id);');
            logger.info('DBMigration', 'v44 迁移完成');
          }
          if (from < 45) {
            // v45: 账本明细原始金额(用户手填的来源/票面金额)。
            // 加列后**立即回填** `original_amount = amount` —— 产品口径是
            // 「每条明细都有原始金额」,未填写即等于记账金额(差异 0)。
            // 写入路径同样兜底(见 local_transaction_repository),读取侧的
            // COALESCE 只作旧快照/手工插库的防御,不承担业务兜底。
            // ⚠️ SQL 与 test/data/migration_v45_test.dart 的常量保持一字不差。
            logger.info('DBMigration', '开始迁移到 v45: 账本明细原始金额(original_amount)');
            await _addColumnIfMissing('transactions', 'original_amount',
                'ALTER TABLE transactions ADD COLUMN original_amount REAL;');
            await customStatement(
                'UPDATE transactions SET original_amount = amount WHERE original_amount IS NULL;');
            logger.info('DBMigration', 'v45 迁移完成');
          }
          if (from < 46) {
            // v46: 账本自定义字段。
            // - custom_field_definitions:按账本独立的字段定义(名称/类型/排序)。
            // - transactions.custom_values_json:{fieldSyncId: value} JSON 对象。
            // 两处都是**纯新增、零回填**:值列保持 NULL = 该笔没有自定义字段值,
            // 存量行导出结果与 v45 逐字节一致(导出侧 NULL 不写键)。不回填是刻意的
            // —— 回填成 `{}` 会让"旧快照无此键"与"显式空对象"指纹不一致,引发
            // 永不收敛的假冲突(v45 original_amount 同款教训)。
            logger.info('DBMigration', '开始迁移到 v46: 自定义字段定义 + 交易自定义值');
            await _createTableIfMissing(
                migrator, 'custom_field_definitions', customFieldDefinitions);
            // (ledger_id) 索引服务「按账本取定义」这一唯一高频查询。
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_custom_field_definitions_ledger '
                'ON custom_field_definitions(ledger_id);');
            // 与 v38 各实体 sync_id 唯一索引同构:防同一定义被重复锚定。
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_custom_field_definitions_sync_id '
                'ON custom_field_definitions(sync_id);');
            await _addColumnIfMissing('transactions', 'custom_values_json',
                'ALTER TABLE transactions ADD COLUMN custom_values_json TEXT;');
            // 新表纳入 updated_at 触碰触发器(幂等,顺带补齐其它表)。
            await _createUpdatedAtTouchTriggers();
            logger.info('DBMigration', 'v46 迁移完成');
          }
          if (from < 47) {
            // v47: 周期账单模板级自定义字段值。
            // 纯新增、零回填:NULL = 模板未配置字段值,存量行导出结果与 v46
            // 逐字节一致(导出侧 NULL 不写键)。不回填是刻意的 —— 回填成 `{}`
            // 会让"旧快照无此键"与"显式空对象"指纹不一致,引发永不收敛的
            // 假冲突(v45 original_amount / v46 custom_values_json 同款教训)。
            logger.info('DBMigration', '开始迁移到 v47: 周期账单模板自定义字段值');
            await _addColumnIfMissing(
                'recurring_transactions',
                'template_field_values',
                'ALTER TABLE recurring_transactions ADD COLUMN template_field_values TEXT;');
            logger.info('DBMigration', 'v47 迁移完成');
          }
          if (from < 48) {
            // v48: 索引修复型迁移（2026-09-26 双端实测发现的存量缺陷）。
            // v10/v11/v12 的 6 个索引当时只写进了对应 onUpgrade 分支，从未进
            // onCreate；而本文件的「onCreate 补建」是逐次打补丁修的，没有配套
            // 修复型迁移 —— 于是**版本已越过 v12 的存量库**（`from < 10/11/12`
            // 永不成立）与**全部新装库**都永远没有这些索引。另开版本号无条件
            // IF NOT EXISTS 补建，幂等可重入。
            logger.info(
                'DBMigration', '开始迁移到 v48: 补建缺失的 tag/budget/attachment 索引');
            await _createV48RepairIndexes();
            logger.info('DBMigration', 'v48 迁移完成');
          }
          if (from < 49) {
            // v49: 日历节假日本地缓存 + 更新记账。
            // 两张表都是「随时可整表重建」的本地缓存（与 exchange_rates 同定位）：
            // **刻意不进** local_changes / 指纹 / diff / 备份清单，也**不挂**
            // updated_at 触碰触发器 —— 纳管会回流幻影变更，并让契约穷举守门
            // 测试（sync_contract_coverage_test.dart）变红。
            logger.info('DBMigration', '开始迁移到 v49: 日历节假日本地缓存与更新记账');
            await _createTableIfMissing(
                migrator, 'holiday_entries', holidayEntries);
            await _createTableIfMissing(
                migrator, 'holiday_update_meta', holidayUpdateMeta);
            // year 是整年替换（按年批量删）与设置页按年分组读取的唯一谓词。
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_holiday_entries_year '
                'ON holiday_entries(year);');
            logger.info('DBMigration', 'v49 迁移完成');
          }
          if (from < 50) {
            // v50: 删除 ledger_members 死表 —— 全库零读写(仅 v24 建表,从未有
            // 写入方或读取方)。共享账本协作已下线且项目尚无老用户,无需存量兼容。
            // deleteTable 内部即 DROP TABLE IF EXISTS,幂等可重入。
            logger.info('DBMigration', '开始迁移到 v50: 删除 ledger_members 死表');
            await migrator.deleteTable('ledger_members');
            logger.info('DBMigration', 'v50 迁移完成');
          }
          if (from < 51) {
            // v51: 共享账本残留整体移除(2026-10-08)。镜像表无写入方恒空、
            // 项目无老用户,v50 DROP ledger_members 同款决策。
            // 幂等性:表用 deleteTable(即 DROP TABLE IF EXISTS);列用 PRAGMA
            // 存在性检查 — from<24 直升 v51 的库这些列从未创建,DROP 必须跳过。
            // SQLite 3.35+ 支持 ALTER TABLE DROP COLUMN(sqlite3_flutter_libs
            // 捆绑 3.4x,满足);这些列上无索引/触发器依赖,可安全 DROP。
            logger.info('DBMigration', '开始迁移到 v51: 移除共享账本残留表与列');
            await migrator.deleteTable('shared_ledger_categories');
            await migrator.deleteTable('shared_ledger_accounts');
            await migrator.deleteTable('shared_ledger_tags');
            await migrator.deleteTable('transaction_tag_overrides');
            await _dropColumnIfPresent('ledgers', 'my_role');
            await _dropColumnIfPresent('ledgers', 'member_count');
            await _dropColumnIfPresent('ledgers', 'is_shared');
            await _dropColumnIfPresent('ledgers', 'owner_user_id');
            await _dropColumnIfPresent('transactions', 'category_sync_id_override');
            await _dropColumnIfPresent('transactions', 'account_sync_id_override');
            await _dropColumnIfPresent('transactions', 'to_account_sync_id_override');
            await _dropColumnIfPresent('transactions', 'tag_sync_ids_override');
            logger.info('DBMigration', 'v51 迁移完成');
          }
          if (from < 52) {
            // v52: 投资持仓（手动估值版，2026-10-08）。
            // holdings 与 accounts 同为 user-global 实体（ledger_id 恒 0 的 legacy
            // 列，业务关联走 account_id），快照里与账户同款**全量导出** —— 每个
            // 账本快照都携带同一份持仓列表，恢复任意快照即可收敛持仓集合。
            //
            // 纯新增、零回填：新表无历史行，存量库升级后持仓集合为空，投资账户
            // 口径仍逐字走 initial_balance（与 v51 一致），删光持仓即回退，可逆。
            //
            // 同批一次性预留「实时行情」接入字段，避免后期再接时升 schema + 升
            // 快照格式版本 + 重走一轮契约测试：
            // - 可同步：market（行情市场标识）、auto_quote（该笔是否允许自动刷新）
            // - **本地专有**：quote_price / quote_fetched_at / quote_source_id
            //   —— 行情缓存，不进快照 / 不进 holdingCanon 指纹 / 不写
            //   local_changes，只由行情刷新写入（手滑纳入指纹会让跨设备指纹
            //   永久不一致、同步永不收敛）。
            logger.info('DBMigration', '开始迁移到 v52: 投资持仓表(含行情预留列)');
            await _createTableIfMissing(migrator, 'holdings', holdings);
            // (account_id) 服务「按账户取持仓」这一唯一高频查询，并让删除账户时的
            // 级联删除避免全表扫描。
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_holdings_account '
                'ON holdings(account_id);');
            // 与 v38 各实体 sync_id 唯一索引同构:防同一持仓被重复锚定。
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_holdings_sync_id '
                'ON holdings(sync_id);');
            // 新表纳入 updated_at 触碰触发器(幂等,顺带补齐其它表)。
            await _createUpdatedAtTouchTriggers();
            logger.info('DBMigration', 'v52 迁移完成');
          }
          if (from < 53) {
            // v53: 储蓄目标（账本私有，2026-10-09）。
            //
            // ledger-scoped 实体（同 budgets）：每本账本各持一份，随所属账本快照
            // 导出/恢复；变更走 ChangeTracker.recordLedgerChange，ledger_id 必须
            // > 0（不要并入 user-global 通道，那会让变更卡在本地永不推送）。
            //
            // 纯新增、零回填：新表无历史行，存量库升级后目标清单为空，无用户
            // 数据需要迁移。saved_amount 不是流水（刻意不建明细表），账户模式下
            // 该列不参与进度计算。
            //
            // 同步契约同批收窄到 v12：新增 `savingsGoals` 段 + `savingsGoalCanon`
            // 指纹白名单 + diff 段（段门控传引入版本 12，否则旧快照会被判成
            // 「本地目标全删」）。
            logger.info('DBMigration', '开始迁移到 v53: 储蓄目标表');
            await _createTableIfMissing(migrator, 'savings_goals', savingsGoals);
            // (ledger_id) 服务「按账本取目标」这一唯一高频查询。
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_savings_goals_ledger '
                'ON savings_goals(ledger_id);');
            // 与 v38 各实体 sync_id 唯一索引同构：防同一目标被重复锚定。
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS uq_savings_goals_sync_id '
                'ON savings_goals(sync_id);');
            // 新表纳入 updated_at 触碰触发器（幂等，顺带补齐其它表）。
            await _createUpdatedAtTouchTriggers();
            logger.info('DBMigration', 'v53 迁移完成');
          }
        },
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_override_pair '
              'ON exchange_rate_overrides (base_currency, quote_currency);');
          // v32/v33 索引也需在 onCreate 创建:新装 app 和测试内存库走 onCreate
          // 而非 migration,若不在 onCreate 建索引则新库永远没有该索引。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_happened '
              'ON transactions(ledger_id, happened_at);');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_recurring_sync_id '
              'ON recurring_transactions(sync_id);');
          // v35: local_changes 部分唯一索引(与 onUpgrade v35 同构,新装 app 走 onCreate)。
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_local_changes_unpushed_dedup '
              'ON local_changes (entity_type, entity_sync_id, action) '
              'WHERE pushed_at IS NULL;');
          // v39: local_changes (ledger_id, pushed_at) 查询索引（审计 C7，
          // 与 onUpgrade v39 同构 —— 新装库走 onCreate）。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_local_changes_ledger_pushed '
              'ON local_changes (ledger_id, pushed_at);');
          // v44: 回收站 (ledger_id) 索引(与 onUpgrade v44 同构 —— 新装库走
          // onCreate，表本身由 m.createAll 建，索引要在这里补一次)。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_deleted_transactions_ledger '
              'ON deleted_transactions(ledger_id);');
          // v46: 自定义字段定义索引(与 onUpgrade v46 同构 —— 新装库走 onCreate,
          // 表本体由上方 m.createAll 建,索引要在这里补一次)。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_custom_field_definitions_ledger '
              'ON custom_field_definitions(ledger_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_custom_field_definitions_sync_id '
              'ON custom_field_definitions(sync_id);');
          // v43: 同步指标 (ts) 索引（与 onUpgrade v43 同构）。此前 onUpgrade
          // 建了该索引但 onCreate 遗漏 —— 全新安装用户 SyncMetricsService
          // 的 30 天窗口聚合（summarize/topErrorClasses/cleanupExpired）全表
          // 扫描。表本身由 m.createAll 建，索引必须在这里补一次。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_sync_op_log_ts ON sync_op_log(ts);');
          // L4:各实体 sync_id 查询索引(与 onUpgrade v15/v19/v21/v22 分支同构)。
          // 之前只在 onUpgrade 创建 → 新装库 pull 解析按 entity_sync_id 反查
          // 实体时全表扫描(LookupCache 只缓解部分路径)。IF NOT EXISTS 幂等,
          // 与 onUpgrade 已建的索引同名不冲突。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_transactions_sync_id ON transactions(sync_id);');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_accounts_sync_id ON accounts(sync_id);');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_categories_sync_id ON categories(sync_id);');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_tags_sync_id ON tags(sync_id);');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_ledgers_sync_id ON ledgers(sync_id);');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_budgets_sync_id ON budgets(sync_id);');
          // v38: 各实体 sync_id 唯一索引（审计 TBL-M1，与 onUpgrade v38
          // 同构 —— 新装库走 onCreate 而非 migration）。
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_ledgers_sync_id ON ledgers(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_accounts_sync_id ON accounts(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_categories_sync_id ON categories(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_transactions_sync_id ON transactions(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_tags_sync_id ON tags(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_budgets_sync_id ON budgets(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_recurring_sync_id ON recurring_transactions(sync_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_exchange_rate_overrides_sync_id ON exchange_rate_overrides(sync_id);');
          // v40: updated_at 触碰触发器（审计 T1，与 onUpgrade v40 同构 ——
          // 新装库走 onCreate 而非 migration）。IF NOT EXISTS 幂等。
          await _createUpdatedAtTouchTriggers();
          // v48: 补建 v10/v11/v12 只在 onUpgrade 分支建过的 6 个索引
          // （新装库走 onCreate，漏建即永久缺失）。详见 [_v48RepairIndexes]。
          await _createV48RepairIndexes();
          // v43: 同步指标时间索引（与 onUpgrade v43 同构 —— 新装库走
          // onCreate）。表本体由上方 m.createAll 创建。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_sync_op_log_ts ON sync_op_log(ts);');
          // v49: 节假日缓存 year 索引（与 onUpgrade v49 同构 —— 新装库走
          // onCreate 而非 migration，漏建即永久缺失）。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_holiday_entries_year '
              'ON holiday_entries(year);');
          // v52: 投资持仓索引（与 onUpgrade v52 同构 —— 新装库走 onCreate 而非
          // migration，漏建即永久缺失；表本体由上方 m.createAll 创建）。
          // v48 教训：onUpgrade 与 onCreate 的索引集合必须逐一对齐。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_holdings_account '
              'ON holdings(account_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_holdings_sync_id '
              'ON holdings(sync_id);');
          // v53: 储蓄目标索引（与 onUpgrade v53 同构 —— 新装库走 onCreate 而非
          // migration，漏建即永久缺失；表本体由上方 m.createAll 创建）。
          // v48 教训：onUpgrade 与 onCreate 的索引集合必须逐一对齐。
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_savings_goals_ledger '
              'ON savings_goals(ledger_id);');
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS uq_savings_goals_sync_id '
              'ON savings_goals(sync_id);');
        },
      );

  /// v48 索引修复清单：6 个「只在 onUpgrade 历史分支建过、onCreate 从未建」
  /// 的索引。
  ///
  /// 背景（2026-09-26 双端实测发现，`lib/data/db.dart` 的 onCreate 与
  /// onUpgrade 索引集合必须保持一致）：
  /// - `idx_transaction_tags_transaction` / `idx_transaction_tags_tag`（v10）
  /// - `idx_budgets_ledger` / `idx_budgets_category` / `idx_budgets_ledger_type`（v11）
  /// - `idx_attachments_transaction`（v12）
  ///
  /// 影响实测：`transaction_tags` 1.2 万行时 `EXPLAIN QUERY PLAN` 对
  /// `WHERE transaction_id IN (...)` 报 **`SCAN transaction_tags`** —— 合并
  /// 路径每账本的 tag 批量读因此有 ~0.3~0.6 s 的**固定**成本（6 个 id 与
  /// 102 个 id 耗时几乎相同，因为代价由全表扫描决定）；按标签筛交易、预算
  /// 用量统计、附件角标与孤儿附件 GC 同样全表扫描。
  ///
  /// 两个动作缺一不可：onCreate 补建只救**新装**用户；存量库 user_version
  /// 已是 47，`from < 10/11/12` 永不执行，必须靠 v48 无条件补建。
  static const List<String> _v48RepairIndexes = [
    'CREATE INDEX IF NOT EXISTS idx_transaction_tags_transaction '
        'ON transaction_tags(transaction_id);',
    'CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag '
        'ON transaction_tags(tag_id);',
    'CREATE INDEX IF NOT EXISTS idx_budgets_ledger ON budgets(ledger_id);',
    'CREATE INDEX IF NOT EXISTS idx_budgets_category ON budgets(category_id);',
    'CREATE INDEX IF NOT EXISTS idx_budgets_ledger_type '
        'ON budgets(ledger_id, type);',
    'CREATE INDEX IF NOT EXISTS idx_attachments_transaction '
        'ON transaction_attachments(transaction_id);',
  ];

  /// 幂等补建 [_v48RepairIndexes]。
  ///
  /// 注意：本方法在 onCreate 路径也会执行，而部分纯 DB 单测不初始化平台
  /// binding（logger 单例初始化需要）——此处必须保持静默，日志由 onUpgrade
  /// 的 v48 块负责（仅真实升级路径执行），与 [_createUpdatedAtTouchTriggers]
  /// 同款纪律。
  Future<void> _createV48RepairIndexes() async {
    for (final ddl in _v48RepairIndexes) {
      await customStatement(ddl);
    }
  }

  /// Migration helper: 列不存在再 ALTER ADD,避免 partial state 重跑时
  /// "duplicate column" 把启动卡死。
  ///
  /// SQLite DDL 隐式 commit 且不可回滚;上次 onUpgrade 跑到一半失败时,前面
  /// 已成功的 ALTER 已写入文件但 user_version 没更新,下次启动同一段重跑就
  /// 报 duplicate。每条 ALTER 都通过这里走 PRAGMA 检查可幂等。
  Future<void> _addColumnIfMissing(
      String table, String column, String ddl) async {
    final cols = await customSelect("PRAGMA table_info($table)").get();
    final exists = cols.any((r) => r.read<String>('name') == column);
    if (exists) {
      logger.info('DBMigration', '$table.$column 已存在,跳过 ALTER');
      return;
    }
    await customStatement(ddl);
  }

  /// 审计 T1：需要 updated_at 触碰触发器的表（v40）。
  /// accounts 列早已存在（v1.15.0），一并纳入触发器维护。
  static const Set<String> _updatedAtTouchTables = {
    'transactions',
    'categories',
    'tags',
    'accounts',
    'ledgers',
    'custom_field_definitions',
    // v52：持仓（与 accounts 同款）。注意 holdings.updated_at 是**本地审计列**，
    // 不进快照 / 不进指纹，所以行情缓存写入被触发器顺带刷新也无副作用。
    'holdings',
    // v53：储蓄目标。updated_at 同样不进快照 / 不进指纹（契约用 syncId 做身份、
    // 业务字段做内容判等），触发器顺带刷新无副作用。
    'savings_goals',
  };

  /// 审计 T1（v40）：创建 updated_at 触碰触发器（幂等）。
  ///
  /// 设计：
  /// - `AFTER UPDATE ... WHEN NEW.updated_at IS OLD.updated_at`：语句未触碰
  ///   该列（含列值为 NULL 的存量行首次被更新）时自动盖 UTC 秒级时间戳；
  ///   语句**显式写入不同值**时守卫不成立 → 应用层/未来 pull 回填的时间
  ///   原样保留。
  /// - 内部自更新把值改成 now ≠ OLD，即便宿主开启 recursive_triggers 也
  ///   不会二次递归。
  /// - `CAST(strftime('%s','now') AS INTEGER)`：strftime 返回 TEXT，必须
  ///   显式转 INTEGER 才与 drift 的 epoch-seconds DateTime 映射一致。
  /// - INSERT 不设触发器：新建行保持 NULL =「本设备从未更新过」，语义
  ///   明确且不伪造时间；restore/import 批量插入路径零额外开销。
  Future<void> _createUpdatedAtTouchTriggers() async {
    // 注意：本方法在 onCreate 路径执行，而部分纯 DB 单测不初始化平台
    // binding（logger 单例初始化需要）。此处必须保持静默，不得触碰 logger；
    // 迁移进度日志由 onUpgrade 的 v40 块负责（仅真实升级路径执行）。
    for (final table in _updatedAtTouchTables) {
      // v40 升级路径上，v46 才建的表（custom_field_definitions）尚不存在，
      // 无守卫的 CREATE TRIGGER 会让整个迁移崩掉、App 打不开；跳过缺失表，
      // 由对应建表迁移块（如 v46）再次调用本方法补齐触发器。
      final exists = await customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        variables: [Variable<String>(table)],
      ).get();
      if (exists.isEmpty) continue;
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS trg_${table}_touch_updated_at '
        'AFTER UPDATE ON $table '
        'FOR EACH ROW '
        'WHEN NEW.updated_at IS OLD.updated_at '
        'BEGIN '
        'UPDATE $table SET updated_at = '
        "CAST(strftime('%s','now') AS INTEGER) WHERE id = NEW.id; "
        'END',
      );
    }
  }

  /// Migration helper: 表不存在再 createTable,避免 partial state 重跑时
  /// "table already exists"。
  Future<void> _createTableIfMissing(
      Migrator m, String tableName, dynamic table) async {
    final row = await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      variables: [Variable<String>(tableName)],
    ).getSingleOrNull();
    if (row != null) {
      logger.info('DBMigration', '$tableName 表已存在,跳过 createTable');
      return;
    }
    await m.createTable(table);
  }

  /// Migration helper: 列存在才 DROP(v51 共享账本残留清理)。
  ///
  /// from<24 直升 v51 的库从未创建过这些列,必须跳过;SQLite 3.35+ 才支持
  /// ALTER TABLE DROP COLUMN。幂等可重入(与 [_addColumnIfMissing] 对称)。
  Future<void> _dropColumnIfPresent(String table, String column) async {
    final cols = await customSelect("PRAGMA table_info($table)").get();
    final exists = cols.any((r) => r.read<String>('name') == column);
    if (!exists) {
      logger.info('DBMigration', '$table.$column 不存在,跳过 DROP');
      return;
    }
    await customStatement('ALTER TABLE $table DROP COLUMN $column');
  }

  // Seed minimal data
  /// [l10n] 国际化对象，如果为null则使用英文作为默认语言
  /// [currency] 货币代码
  /// [useHierarchicalCategories] 是否使用二级分类
  ///
  /// 注意：此方法只应在真正的首次初始化时调用（欢迎页完成时）
  Future<void> ensureSeed({
    AppLocalizations? l10n,
    String currency = 'CNY',
    bool useHierarchicalCategories = false,
    bool skipCategories = false,
    bool createDefaultLedger = true,
  }) async {
    logger.info('db', 'ensureSeed 被调用');
    logger.info('db', 'l10n 是否提供: ${l10n != null}');
    logger.info('db', '货币: $currency');
    logger.info('db', '使用二级分类: $useHierarchicalCategories');
    logger.info('db', '跳过分类创建: $skipCategories');
    logger.info('db', '创建默认账本: $createDefaultLedger');

    // 如果没有提供l10n，使用Lookup创建默认的英文版本
    final effectiveL10n = l10n ?? lookupAppLocalizations(const Locale('en'));
    logger.info('db', '使用的语言环境: ${l10n != null ? "提供的l10n" : "默认英文"}');

    await SeedService.seedDatabase(
      this,
      effectiveL10n,
      currency: currency,
      useHierarchicalCategories: useHierarchicalCategories,
      skipCategories: skipCategories,
      createDefaultLedger: createDefaultLedger,
    );
    logger.info('db', '数据库初始化完成');
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'piggycount.sqlite'));

    // 开发环境：如果检测到锁文件，尝试删除（仅用于调试）
    try {
      final shmFile = File(p.join(dir.path, 'piggycount.sqlite-shm'));
      final walFile = File(p.join(dir.path, 'piggycount.sqlite-wal'));

      if (shmFile.existsSync() || walFile.existsSync()) {
        // M18 起 WAL 是**显式设定**的连接模式（见 migration.beforeOpen），旁路文件
        // 上次进程被杀时留下属正常，不能再报 warning —— 恒告警等于没有告警。
        // 真正的锁问题由 `PRAGMA quick_check` 那条路（database_health_service）负责。
        logger.info('db', '存在 SQLite 旁路文件（WAL），正常残留');
        // 注意：不自动删除，可能正在使用
      }
    } catch (e) {
      logger.debug('db', '检查锁文件时出错: $e');
    }

    // 启动即记录引擎身份。本仓库踩过的最坏状态（"以为加密了、其实明文落盘"）
    // 之所以能藏住，就是因为没人知道设备上跑的到底是哪个引擎 —— 一行日志把它
    // 变成可查证的事实。
    logger.info('db', 'SQLite 引擎: ${SqlCipherCapability.describe()}');

    // 整库加密（P0，见 `prd/sqlcipher_db_encryption/`）：开库前先定密钥，
    // 必要时做一次性明文→密文迁移。两件都必须在**建立连接之前**完成 ——
    // 迁移会替换库文件，连接已经打开就晚了。
    // 密钥缺省（绝大多数现有安装）时这行不产生任何行为变化。
    final key = await const DbEncryptionMigration()
        .prepareKeyForOpen(dbPath: file.path);

    return NativeDatabase.createInBackground(
      file,
      setup: (raw) {
        // PRAGMA key 必须是该连接执行的**第一条**语句（SQLCipher 要求密钥在任何
        // 读写之前生效）；drift 的 setup 在 open 之后、drift 就绪之前执行，位置
        // 正好。该回调会被发给后台 isolate，所以只捕获 String（可跨 isolate，
        // 不捕获任何对象）。key 为 null 时完全不执行 —— 与加密前逐字一致。
        if (key != null) {
          raw.execute("PRAGMA key = \"x'$key'\"");
        }
      },
    );
  });
}

/// 开发工具：清除数据库锁文件（仅在应用完全关闭后使用）
Future<void> clearDatabaseLockFiles() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final shmFile = File(p.join(dir.path, 'piggycount.sqlite-shm'));
    final walFile = File(p.join(dir.path, 'piggycount.sqlite-wal'));

    if (shmFile.existsSync()) {
      await shmFile.delete();
      logger.info('db', '已删除 .sqlite-shm 文件');
    }

    if (walFile.existsSync()) {
      await walFile.delete();
      logger.info('db', '已删除 .sqlite-wal 文件');
    }

    logger.info('db', '数据库锁文件清理完成');
  } catch (e) {
    logger.error('db', '清理锁文件失败', e);
  }
}
