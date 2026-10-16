import '../db.dart';
import 'custom_field_values.dart';
import 'transaction_original_amount.dart';

/// 洞察 / 报表的「金额口径」二级选项 —— **单一真相源**。
///
/// 统计 SQL、Dart 侧聚合、海报、PDF、年度账单全部经这里取金额表达式 /
/// 取值函数。口径只定义一次的理由：`COALESCE(native_amount, amount)` 此前
/// 散落在统计仓 / 交易仓 / 预算仓 / 账本仓 / 分类仓 / 报表页 / 导出服务里
/// 共约 30 处，任何一处漏改都会造成「界面按 A 口径、导出按 B 口径」的静默
/// 分裂（报销 / 对账场景直接对不上）。
///
/// 三种口径：
/// - [recorded]：记账金额（本位币折算后的 `COALESCE(native_amount, amount)`）；
/// - [original]：原始金额（v45 票面金额，未填回落记账金额）；
/// - [AnalyticsAmountMetric.customField]：某个**金额型自定义字段**的值
///   （v46 `custom_values_json`，按字段 syncId 取）。
///
/// 自定义字段口径与前两者有一个本质差别：**没填该字段的明细不参与统计**
/// （不是算 0）。所以它除了金额表达式 [sqlExpr]，还需要行过滤
/// [sqlRowFilter]（SQL 侧）/ [matches]（Dart 侧）—— 漏掉过滤会把「没填」
/// 混进笔数 / 百分比分母，总额与占比全部对不上。
///
/// 与 [OriginalAmountMetric] 的区别：那是「原币 / 本位币折算」这一轴，
/// 本类表达的是「拿哪一列金额统计」，两者正交。
sealed class AnalyticsAmountMetric {
  const AnalyticsAmountMetric();

  /// 记账金额（默认）：`COALESCE(native_amount, amount)`，与账本本位币总览同源。
  static const AnalyticsAmountMetric recorded = _RecordedAmountMetric();

  /// 原始金额：按票面 / 原始金额统计。
  ///
  /// 未填写的明细回落**同口径记账金额**（v45 语义，见
  /// [TransactionOriginalAmountX.originalAmountOf]）——所以未填写的明细在
  /// 两个口径下数值相同，口径切换只在「填过原始金额」的明细上产生差异，
  /// 无需另加兜底，也不会把「没填」误算成 0。
  static const AnalyticsAmountMetric original = _OriginalAmountMetric();

  /// 金额型自定义字段口径：按 [fieldSyncId] 这个字段的值统计。
  ///
  /// 只有 `fieldType == CustomFieldType.amount` 的字段适合进这个口径
  /// （文本 / 日期 / 单选 / 多选没有可求和的金额）。
  factory AnalyticsAmountMetric.customField(String fieldSyncId) =
      _CustomFieldAmountMetric;

  /// 持久化键（SharedPreferences）。
  static const String prefsKey = 'analytics_amount_metric';

  /// 自定义字段口径的存储值前缀：`custom:<fieldSyncId>`。
  static const String customPrefix = 'custom:';

  /// 存储值 → 口径。无法识别（旧版本 / 脏值 / 空 syncId）时回落 [recorded]。
  ///
  /// 「字段已删」不在这里兜底（本方法拿不到定义列表）：删除字段后
  /// [fieldSyncId] 指向一个不存在的键，SQL 侧取不到值 → 该口径下全部明细
  /// 被过滤（读数归零）。UI 侧另有「定义列表里找不到就回落默认口径」的
  /// 守卫，见 `AmountMetricChip`。
  static AnalyticsAmountMetric fromStorage(Object? raw) {
    if (raw is! String) return recorded;
    if (raw == recorded.storageValue) return recorded;
    if (raw == original.storageValue) return original;
    if (raw.startsWith(customPrefix)) {
      final sid = raw.substring(customPrefix.length).trim();
      if (sid.isNotEmpty) return AnalyticsAmountMetric.customField(sid);
    }
    return recorded;
  }

  /// 口径的字段 syncId（仅自定义字段口径非空）。
  String? get fieldSyncId => null;

  /// 口径 → 存储值（持久化 / 缓存键用，全局唯一）。
  String get storageValue;

  /// 是否为默认口径（UI 据此决定是否强调）。
  bool get isDefault => this == recorded;

  /// SQL 侧金额表达式（本位币折算），[alias] 为表别名（无别名传空串）。
  ///
  /// - [recorded] → `COALESCE(native_amount, amount)`；
  /// - [original] → 未填回落记账侧；`amount = 0` 时汇率无从推断，原样保留
  ///   原币值（不产生除零）；否则按该笔隐含汇率缩放
  ///   （`original × native / amount`）；
  /// - 自定义字段 → 该字段的数值（`json_type` 判类型 + `json_extract` 取值），
  ///   非数值 / 无值返回 0（**行本身由 [sqlRowFilter] 排除**，不进分母）。
  ///
  /// 与 Dart 侧 [amountOf] 逐字同义，改任一侧必须同步另一侧。
  String sqlExpr({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    final rec = 'COALESCE(${p}native_amount, ${p}amount)';
    switch (this) {
      case _RecordedAmountMetric():
        return rec;
      case _OriginalAmountMetric():
        return 'CASE WHEN ${p}original_amount IS NULL THEN $rec '
            'WHEN ${p}amount = 0 THEN ${p}original_amount '
            'ELSE ${p}original_amount * $rec / ${p}amount END';
      case _CustomFieldAmountMetric(:final path):
        if (path == null) return '0';
        final col = '${p}custom_values_json';
        return "CASE WHEN json_type($col, '$path') IN ('integer','real') "
            "THEN CAST(json_extract($col, '$path') AS REAL) ELSE 0 END";
    }
  }

  /// SQL 侧**附加行过滤**（不含 `AND`；空串 = 不过滤；恒假返回 `'0'`）。
  ///
  /// 只对自定义字段口径非空：没填该字段的明细必须整行排除，否则它们会以
  /// 金额 0 混进笔数与百分比分母。调用方拼进 `WHERE` 即可。
  String sqlRowFilter({String alias = ''}) {
    switch (this) {
      case _RecordedAmountMetric():
      case _OriginalAmountMetric():
        return '';
      case _CustomFieldAmountMetric(:final path):
        // 路径不可用 → 恒假：该口径下没有任何明细参与（读数归零），
        // 而不是把整表当 0 算进笔数。
        if (path == null) return '0';
        final p = alias.isEmpty ? '' : '$alias.';
        return "json_type(${p}custom_values_json, '$path') "
            "IN ('integer','real')";
    }
  }

  /// Dart 侧行判定：该明细是否参与本口径统计（[sqlRowFilter] 的同义实现）。
  ///
  /// Dart 侧聚合（如 `totalsByCategory` 走 Drift 查询构造器逐行累加）必须过
  /// 这一关，否则「SQL 侧过滤了、Dart 侧没过滤」会让同一页的环形图与排行榜
  /// 口径分叉。
  bool matches(Transaction t);

  /// Dart 侧取值：对**已取出的交易行**做聚合时使用（与 [sqlExpr] 同义）。
  ///
  /// 自定义字段口径下，没填该字段的明细返回 0 —— 前提是调用方已过
  /// [matches]；直接累加未过滤的行等于把「没填」当 0 算。
  double amountOf(Transaction t);

  /// 口径相等判定：按 [storageValue]（自定义字段按 syncId 比较）。
  @override
  bool operator ==(Object other) =>
      other is AnalyticsAmountMetric && other.storageValue == storageValue;

  @override
  int get hashCode => storageValue.hashCode;
}

final class _RecordedAmountMetric extends AnalyticsAmountMetric {
  const _RecordedAmountMetric();

  @override
  String get storageValue => 'recorded';

  @override
  bool matches(Transaction t) => true;

  @override
  double amountOf(Transaction t) => t.nativeAmount ?? t.amount;
}

final class _OriginalAmountMetric extends AnalyticsAmountMetric {
  const _OriginalAmountMetric();

  @override
  String get storageValue => 'original';

  @override
  bool matches(Transaction t) => true;

  @override
  double amountOf(Transaction t) =>
      t.originalAmountOf(OriginalAmountMetric.native);
}

/// 金额型自定义字段口径。
///
/// [path] 是**已做安全校验**的 JSON 路径（`$."<syncId>"`）；syncId 含引号 /
/// 点 / 空格这类会改写 SQL 字面量或 JSON 路径的字符时为 null —— 那时口径取不到
/// 任何值（[sqlExpr] 退化为 `0`、[sqlRowFilter] 退化为恒假），表现为「该口径
/// 下没有数据」，而不是把 SQL 拼坏。
///
/// 行级 JSON 解析结果按**原串**缓存：同一份 `custom_values_json` 会在
/// 「按天 / 按月 / 按分类」多轮分组里被反复取值，缓存把「每种取值组合解析
/// 一次」作为上界（与 `customFieldValueBadgesProvider` 同款做法）。
final class _CustomFieldAmountMetric extends AnalyticsAmountMetric {
  _CustomFieldAmountMetric(this.fieldSyncId) : path = _jsonPath(fieldSyncId);

  @override
  final String fieldSyncId;

  /// 安全 JSON 路径；syncId 不合法时为 null。
  final String? path;

  final Map<String, double?> _cache = {};

  @override
  String get storageValue =>
      '${AnalyticsAmountMetric.customPrefix}$fieldSyncId';

  /// syncId → JSON 路径。**白名单式**校验：只接受 UUID 变体允许的字符集，
  /// 其它字符一律视为不可用（syncId 来自云同步，理论上可能被改坏）。
  static String? _jsonPath(String syncId) {
    if (syncId.isEmpty || syncId.length > 64) return null;
    for (final unit in syncId.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isUpper = unit >= 0x41 && unit <= 0x5A;
      final isLower = unit >= 0x61 && unit <= 0x7A;
      final isDashOrUnderscore = unit == 0x2D || unit == 0x5F;
      if (!isDigit && !isUpper && !isLower && !isDashOrUnderscore) return null;
    }
    // 引号形式：UUID 里的 '-' 在裸路径下能否解析依赖 SQLite 实现细节，
    // 双引号标签是 JSON 路径文法里明确支持的写法。
    return '\$."$syncId"';
  }

  /// 该明细填的字段值（未填 / 非数值 → null）。
  double? valueOf(Transaction t) {
    if (path == null) return null;
    final raw = t.customValuesJson;
    if (raw == null) return null;
    return _cache.putIfAbsent(raw, () {
      final v = CustomFieldValueCodec.decode(raw)[fieldSyncId];
      if (v is! num) return null;
      final d = v.toDouble();
      return d.isFinite ? d : null;
    });
  }

  @override
  bool matches(Transaction t) => valueOf(t) != null;

  @override
  double amountOf(Transaction t) => valueOf(t) ?? 0;
}
