import '../db.dart';
import 'custom_field_values.dart';

/// 洞察页「统计时间口径」—— **单一真相源**。
///
/// 洞察页的周期档位（周 / 月 / 季度 / 年 / 自定义 / 全部）此前一律按交易的
/// 记账时间 `happened_at` 划区间与分桶；本类把「用哪一列时间统计」抽成口径，
/// 让用户可以改用某个**日期型自定义字段**的值（如「消费日期」「报销日期」）。
///
/// 两种口径：
/// - [happenedAt]：记账时间（默认），`happened_at` 列（unix 秒）；
/// - [AnalyticsTimeMetric.customField]：某个日期型自定义字段的值
///   （`custom_values_json` 里的 ISO-8601 字符串，按字段 syncId 取）。
///
/// 自定义字段口径与前者的三个本质差别：
/// 1. **没填该字段的明细不参与统计**（不是算 0，也不是回落到记账时间）——
///    所以除了时间源还要行过滤 [sqlRowFilter]；
/// 2. **日粒度**：值可能带时分秒，划区间与分桶都按其**本地日历日**判定
///    （SQL 侧 `date(<值>)`，Dart 侧 [dayOf]），与 SQLite 的 `date()` 同义；
/// 3. 时间源是**文本**而非 unix 秒，SQL 里不能再带 `'unixepoch','localtime'`
///    修饰符 —— 故拆成 [sqlSource] + [sqlModifier] 两段给调用方拼。
///
/// 与 [AnalyticsAmountMetric]（金额口径）正交：一个决定「算哪条金额」，一个
/// 决定「算哪条时间」，两者可同时生效（见 `LocalStatisticsRepository`）。
///
/// **作用范围**：吃这个口径的是**洞察页的统计链路**（`analyticsTimeMetricProvider`
/// → `LocalStatisticsRepository` 的区间聚合 / 分桶 + `countByTypeInRange` +
/// `customFieldStatsRows`）以及从洞察页下钻的**自定义字段汇总卡 / 字段分析页
/// 明细 CSV**（同一个时间轴，否则「汇总按字段日期、明细按记账时间」）。
///
/// **不吃**这个口径的入口：分类下钻明细（`CategoryDetailPage`，见
/// `analytics_page.dart` 的 `ponytail:` 注释）、报表页 / PDF 导出 / 月度总览 /
/// 小组件 —— 它们各有自己的区间来源，要扩面时先搜 [sqlSource] / [rangeSql] /
/// [inRange] 的调用方逐个想清楚，别只加页面上的 chip。
sealed class AnalyticsTimeMetric {
  const AnalyticsTimeMetric();

  /// 记账时间（默认）：与洞察页历史行为逐字一致。
  static const AnalyticsTimeMetric happenedAt = _HappenedAtTimeMetric();

  /// 日期型自定义字段口径：按 [fieldSyncId] 这个字段的日期值统计。
  ///
  /// 只有 `fieldType == CustomFieldType.date` 的字段适合进这个口径
  /// （文本里碰巧是日期的值不算 —— 由 UI 侧按定义类型过滤）。
  factory AnalyticsTimeMetric.customField(String fieldSyncId) =
      _CustomFieldTimeMetric;

  /// 持久化键（SharedPreferences）。
  static const String prefsKey = 'analytics_time_metric';

  /// 自定义字段口径的存储值前缀：`custom:<fieldSyncId>`。
  static const String customPrefix = 'custom:';

  /// 存储值 → 口径。无法识别（旧版本 / 脏值 / 空 syncId）时回落 [happenedAt]。
  ///
  /// 「字段已删」不在这里兜底（本方法拿不到定义列表）：删除字段后
  /// [fieldSyncId] 指向一个不存在的键，SQL 侧取不到值 → 该口径下全部明细被
  /// 过滤（读数归零）。UI 侧另有「定义列表里找不到就回落默认口径」的守卫，
  /// 见 `TimeMetricChip`。
  static AnalyticsTimeMetric fromStorage(Object? raw) {
    if (raw is! String) return happenedAt;
    if (raw == happenedAt.storageValue) return happenedAt;
    if (raw.startsWith(customPrefix)) {
      final sid = raw.substring(customPrefix.length).trim();
      if (sid.isNotEmpty) return AnalyticsTimeMetric.customField(sid);
    }
    return happenedAt;
  }

  /// 口径的字段 syncId（仅自定义字段口径非空）。
  String? get fieldSyncId => null;

  /// 口径 → 存储值（持久化 / 缓存键用，全局唯一）。
  String get storageValue;

  /// 是否为默认口径（UI 据此决定是否强调）。
  bool get isDefault => this == happenedAt;

  /// 是否按自定义字段取值（SQL 侧走 `json_extract` 而非 `happened_at` 列）。
  bool get isCustomField => fieldSyncId != null;

  /// SQL 侧**时间源**：[alias] 为表别名（无别名传空串）。
  ///
  /// - [happenedAt] → `happened_at`（unix 秒，后半段修饰符见 [sqlModifier]）；
  /// - 自定义字段 → `json_extract(custom_values_json, '$."<syncId>"')`
  ///   （ISO-8601 文本）。syncId 含引号 / 点这类会改写 SQL 字面量的字符时
  ///   为 `null` —— 那时该口径取不到任何时间，表现为「该口径下没有数据」，
  ///   而不是把 SQL 拼坏。
  String sqlSource({String alias = ''});

  /// 紧跟在 [sqlSource] 之后的修饰符（拼进 `date(<source><modifier>)` /
  /// `strftime(<fmt>, <source><modifier>, ...)`）。
  ///
  /// 默认口径把 unix 秒解释成设备本地时间；自定义字段口径的值本身就是本地
  /// 时间的 ISO 文本，故为空串。
  String get sqlModifier;

  /// `date(<时间源>)` —— 该明细归属的**本地日历日**（`YYYY-MM-DD`）。
  String sqlDayExpr({String alias = ''}) =>
      'date(${sqlSource(alias: alias)}$sqlModifier)';

  /// SQL 侧**附加行过滤**（不含 `AND`；空串 = 不过滤；恒假返回 `'0'`）。
  ///
  /// 只对自定义字段口径非空：没填该字段（或值不是可解析日期）的明细必须整行
  /// 排除，否则它们会以「无日期」混进年序列这类**不划区间**的聚合（`date()`
  /// 返回 NULL 会被当成一个独立分组）。调用方拼进 `WHERE` 即可。
  String sqlRowFilter({String alias = ''});

  /// 半开区间 `[start, end)` 的 SQL 过滤片段（不含前导 `AND`，占位符形态）。
  ///
  /// 占位符名由 [startVar] / [endVar] 指定，绑定值经 [rangeBinds] 给出
  /// （**恒为两个**，故调用方的 `variables:` 长度不会随口径变化）。
  String rangeSql({
    required DateTime start,
    required DateTime end,
    String alias = '',
    required String startVar,
    required String endVar,
  });

  /// 与 [rangeSql] 的占位符一一对应的绑定值（恒为两个）：
  /// 默认口径 → `[start, end]`（DateTime，drift 绑成 unix 秒）；
  /// 自定义字段口径 → 两个 `YYYY-MM-DD` 文本（日粒度）。
  List<Object> rangeBinds(DateTime start, DateTime end);

  /// 半开区间 `[start, end)` 的 SQL 过滤片段（**字面量**形态，无占位符）。
  ///
  /// 仅供 Drift 查询构造器路径（分类分布 / 排行榜）的 `CustomExpression` 用 ——
  /// 那条路无法传绑定变量。日期与 unix 秒都由本类生成（非用户输入，无注入面），
  /// 与 [rangeBinds] 同值：[sqlSource] 是 unix 秒列时用整数秒，
  /// 是 ISO 文本时用 `YYYY-MM-DD` 文本。
  String rangeSqlInlined({
    required DateTime start,
    required DateTime end,
    String alias = '',
  });

  /// Dart 侧：该明细的时间（自定义字段口径下无值 / 不可解析 → null）。
  ///
  /// 保留时刻，供展示类用途；划区间请用日粒度的 [dayOf] / [inRange]。
  DateTime? timeOf(Transaction t);

  /// Dart 侧：该明细归属的**本地日历日**（[sqlDayExpr] 的同义实现）。
  DateTime? dayOf(Transaction t);

  /// Dart 侧行判定：该明细是否落在半开区间 `[start, end)`（[rangeSql] 的同义
  /// 实现，日粒度）。Drift 查询构造器路径（分类分布 / 排行榜）逐行判定用它 ——
  /// 漏判会让同一页的环形图与排行榜口径分叉。
  bool inRange(Transaction t, {required DateTime start, required DateTime end});

  /// 口径相等判定：按 [storageValue]（自定义字段按 syncId 比较）。
  @override
  bool operator ==(Object other) =>
      other is AnalyticsTimeMetric && other.storageValue == storageValue;

  @override
  int get hashCode => storageValue.hashCode;
}

/// 记账时间口径（默认）。
final class _HappenedAtTimeMetric extends AnalyticsTimeMetric {
  const _HappenedAtTimeMetric();

  @override
  String get storageValue => 'happenedAt';

  @override
  String get sqlModifier => ", 'unixepoch', 'localtime'";

  @override
  String sqlSource({String alias = ''}) =>
      alias.isEmpty ? 'happened_at' : '$alias.happened_at';

  @override
  String sqlRowFilter({String alias = ''}) => '';

  @override
  String rangeSql({
    required DateTime start,
    required DateTime end,
    String alias = '',
    required String startVar,
    required String endVar,
  }) =>
      '${sqlSource(alias: alias)} >= $startVar '
      'AND ${sqlSource(alias: alias)} < $endVar';

  @override
  List<Object> rangeBinds(DateTime start, DateTime end) => [start, end];

  @override
  String rangeSqlInlined({
    required DateTime start,
    required DateTime end,
    String alias = '',
  }) =>
      '${sqlSource(alias: alias)} >= ${_epochSeconds(start)} '
      'AND ${sqlSource(alias: alias)} < ${_epochSeconds(end)}';

  @override
  DateTime? timeOf(Transaction t) => t.happenedAt;

  @override
  DateTime? dayOf(Transaction t) => _dayOf(t.happenedAt);

  @override
  bool inRange(Transaction t, {required DateTime start, required DateTime end}) =>
      !t.happenedAt.isBefore(start) && t.happenedAt.isBefore(end);
}

/// 日期型自定义字段口径。
///
/// [path] 是**已做安全校验**的 JSON 路径（`$."<syncId>"`）；syncId 含引号 /
/// 点 / 空格这类会改写 SQL 字面量或 JSON 路径的字符时为 null —— 那时该口径取不到
/// 任何值（[sqlSource] 退化为 `null`、[sqlRowFilter] 退化为恒假），表现为「该
/// 口径下没有数据」，而不是把 SQL 拼坏。
///
/// 行级取值结果按**原串**缓存：同一份 `custom_values_json` 会在「按天 / 按月 /
/// 按分类」多轮分组里被反复解析，缓存把「每种取值组合解析一次」作为上界
/// （与 `_CustomFieldAmountMetric` / `customFieldValueBadgesProvider` 同款做法）。
final class _CustomFieldTimeMetric extends AnalyticsTimeMetric {
  _CustomFieldTimeMetric(this.fieldSyncId)
      : path = sqliteJsonPathForField(fieldSyncId);

  @override
  final String fieldSyncId;

  /// 安全 JSON 路径；syncId 不合法时为 null。
  final String? path;

  final Map<String, DateTime?> _cache = {};

  @override
  String get storageValue =>
      '${AnalyticsTimeMetric.customPrefix}$fieldSyncId';

  /// 与默认口径相反：值本身就是本地时间的 ISO 文本，不带 unix 修饰符。
  @override
  String get sqlModifier => '';

  @override
  String sqlSource({String alias = ''}) {
    final p = path;
    if (p == null) return 'null';
    final col = alias.isEmpty ? 'custom_values_json' : '$alias.custom_values_json';
    return "json_extract($col, '$p')";
  }

  @override
  String sqlRowFilter({String alias = ''}) {
    if (path == null) return '0';
    return '${sqlDayExpr(alias: alias)} IS NOT NULL';
  }

  @override
  String rangeSql({
    required DateTime start,
    required DateTime end,
    String alias = '',
    required String startVar,
    required String endVar,
  }) {
    // 日粒度：区间端点一律取本地日历日。`date()` 对「YYYY-MM-DD」与
    // 「YYYY-MM-DDTHH:MM:SS.SSS」两种存法都能解析（编辑器写
    // DateTime.toIso8601String()，导入/旧数据可能是纯日期）。
    final day = sqlDayExpr(alias: alias);
    return '$day >= $startVar AND $day < $endVar';
  }

  @override
  List<Object> rangeBinds(DateTime start, DateTime end) =>
      [_isoDay(start), _isoDay(end)];

  @override
  String rangeSqlInlined({
    required DateTime start,
    required DateTime end,
    String alias = '',
  }) {
    final day = sqlDayExpr(alias: alias);
    return "$day >= '${_isoDay(start)}' AND $day < '${_isoDay(end)}'";
  }

  @override
  DateTime? timeOf(Transaction t) {
    if (path == null) return null;
    final raw = t.customValuesJson;
    if (raw == null) return null;
    return _cache.putIfAbsent(raw, () {
      final v = CustomFieldValueCodec.decode(raw)[fieldSyncId];
      if (v is! String) return null;
      return DateTime.tryParse(v.trim());
    });
  }

  @override
  DateTime? dayOf(Transaction t) {
    final t0 = timeOf(t);
    return t0 == null ? null : _dayOf(t0);
  }

  @override
  bool inRange(Transaction t, {required DateTime start, required DateTime end}) {
    final d = dayOf(t);
    if (d == null) return false;
    return !d.isBefore(_dayOf(start)) && d.isBefore(_dayOf(end));
  }
}

/// 本地日历日（零点）—— 与 SQL 侧 `date()` 的日粒度同义。
///
/// 值为带 `Z` 的 ISO 串时 [DateTime.tryParse] 给出 UTC 实例，取其
/// year/month/day 即**字符串字面量里的那一天**，与 `date()` 一致。
DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// `YYYY-MM-DD`（SQL 字面量用；日期由本文件生成，非用户输入）。
String _isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// unix 秒（`happened_at` 的存储形态）—— 与 drift 的 DateTime → SQL 映射
/// （`millisecondsSinceEpoch ~/ 1000`）逐字同值，故字面量与绑定变量等价。
int _epochSeconds(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
