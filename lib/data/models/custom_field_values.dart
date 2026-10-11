import 'dart:convert';

/// v46 自定义字段的类型枚举。
///
/// 存库为字符串以便后续扩展新类型（不动库结构）：新增类型只需在
/// [all] 与编辑器的输入分支里各加一处。
class CustomFieldType {
  CustomFieldType._();

  /// 金额：JSON number（与记账金额同精度语义）。
  static const String amount = 'amount';

  /// 文本：JSON string（原文，首尾空白在规范化时被裁剪）。
  static const String text = 'text';

  /// 日期：JSON string（ISO-8601，落库统一 [DateTime.toIso8601String]）。
  static const String date = 'date';

  /// v54 单选：JSON string（取自定义 options 里的某一个选项值）。
  static const String singleSelect = 'singleSelect';

  /// v54 多选：JSON array（字符串数组，选项值的子集；落库前去重 + 字典序排序）。
  static const String multiSelect = 'multiSelect';

  static const List<String> all = [
    amount,
    text,
    date,
    singleSelect,
    multiSelect,
  ];

  static bool isValid(String type) => all.contains(type);

  /// 是否为「带选项」类型（[singleSelect] / [multiSelect]）。这类字段的定义
  /// 必须携带非空选项列表，录入控件也是选项选择器而非自由输入框。
  static bool hasOptions(String type) =>
      type == singleSelect || type == multiSelect;
}

/// v46 自定义字段值的编解码与规范化。
///
/// 值以 `{ fieldSyncId: value }` 的对象落在 `transactions.custom_values_json`。
/// **本类是全链路唯一的编解码入口** —— 仓储写入、快照导出/解析、指纹白名单、
/// 差分比较都必须经这里。散落各处手写 `jsonEncode` 会让同一个值在不同链路
/// 得到不同字符串（键序 / int 与 double 表示差异），表现为假差异，进而
/// outOfSync 空转甚至互相覆盖。
///
/// 三条不变量：
/// 1. **空即缺失**：null 字符串、`{}`、全空值对象在 [canonical] 下都是 `''`。
///    旧快照"没有 customValues 键"与"显式空对象"因此指纹一致（v45
///    originalAmount 的同款教训：两侧不等价会造成永不收敛的假冲突）。
/// 2. **键序无关**：[encode] 按键排序输出，[canonical] 按键排序拼接。
/// 3. **数值表示统一**：`1` / `1.0` / `1.00` 一律规范成 `1`。
class CustomFieldValueCodec {
  CustomFieldValueCodec._();

  /// 解析存储字符串 → 值 map。
  ///
  /// null / 空白 / 非法 JSON / 非对象一律返回**空 map 且绝不抛**：坏数据
  /// （手工插库、半截写入、未来格式变更）只应表现为"该笔没有自定义字段值"，
  /// 不能拖垮明细渲染、快照导出或同步主流程。
  static Map<String, dynamic> decode(String? raw) {
    if (raw == null) return const {};
    final s = raw.trim();
    if (s.isEmpty) return const {};
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map) {
        return normalize({
          for (final e in decoded.entries) e.key.toString(): e.value,
        });
      }
    } catch (_) {
      // 坏数据按"无值"处理,静默降级。
    }
    return const {};
  }

  /// 值 map → 存储字符串。
  ///
  /// 规范化后为空 → 返回 null，调用方据此把列写成 NULL（而不是 `'{}'`），
  /// 让存量/空值行在快照里逐字节一致（不写键）。
  static String? encode(Map<String, dynamic>? values) {
    final norm = normalize(values);
    if (norm.isEmpty) return null;
    // 键排序输出:同一份值在任何设备得到逐字节相同的 JSON。
    final keys = norm.keys.toList()..sort();
    return jsonEncode({
      for (final k in keys) k: norm[k],
    });
  }

  /// 规范化：裁掉空键/空值，只保留可承载进 JSON 的标量或字符串列表。
  ///
  /// - `null`、空白字符串 → 剔除（语义 = 该字段未填）
  /// - 数值 NaN/Infinity → 剔除（非法金额）
  /// - 嵌套 map / 非字符串列表元素 → 剔除
  /// - 字符串列表（v54 多选值）→ 逐元素规范化 + 去重 + 字典序排序；空集合剔除
  /// - 文本做 trim；数值统一转 double（与 [canonical] 的表示约定配套）
  ///
  /// 注意：**金额 0 是合法值**，不会被剔除 —— 用户可能确实录了 0
  /// （如"折扣 0 元"），静默丢弃会让编辑回显莫名空掉。
  static Map<String, dynamic> normalize(Map<String, dynamic>? values) {
    if (values == null || values.isEmpty) return const {};
    final out = <String, dynamic>{};
    for (final entry in values.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      final value = normalizeValue(entry.value);
      if (value == null) continue;
      out[key] = value;
    }
    return out;
  }

  /// 单个值的规范化（[normalize] 的逐值分支，供 CSV 导入这类逐值消费方复用，
  /// 避免各处再手写一套"空串丢弃 / 数值转 double"的规则而口径分叉）。
  ///
  /// 返回 null 表示该值不该被承载：null、空白串、非有限数、嵌套 map、
  /// 空列表。**金额 0 是合法值**，返回 0.0。
  ///
  /// v54 起支持**字符串列表**（多选值）：逐元素走标量规范化 → 去重 →
  /// 字典序排序后返回 `List<String>`。排序是为了与录入/定义顺序解耦——任意
  /// 设备对同一集合得到逐字节相同的表示，指纹/差分才可比。仅收字符串：
  /// 多选值域就是选项值（字符串），混入的其它标量按脏数据剔除。
  static dynamic normalizeValue(dynamic value) {
    if (value is List) {
      final out = <String>{};
      for (final e in value) {
        final n = _normalizeScalar(e);
        if (n is String) out.add(n);
      }
      if (out.isEmpty) return null;
      return (out.toList()..sort());
    }
    return _normalizeScalar(value);
  }

  /// 标量规范化（[normalizeValue] 的分支，也是列表元素的分支）。
  static dynamic _normalizeScalar(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (value is num) {
      final dbl = value.toDouble();
      return dbl.isFinite ? dbl : null;
    }
    if (value is bool) return value;
    return null;
  }

  /// 规范化比较串：键排序 + 数值表示统一。null 与 `{}` 等价（都返回 `''`）。
  ///
  /// 指纹白名单与差分比较**必须**用本方法，不要直接 `jsonEncode(map)`。
  static String canonical(Map<String, dynamic>? values) {
    final norm = normalize(values);
    if (norm.isEmpty) return '';
    final keys = norm.keys.toList()..sort();
    final sb = StringBuffer();
    for (final k in keys) {
      sb.write(k);
      sb.write('=');
      sb.write(canonicalValue(norm[k]));
      sb.write('\u0001');
    }
    return sb.toString();
  }

  /// 单个值的规范化文本表示（[canonical] 与差分逐项比较共用）。
  static String canonicalValue(dynamic value) {
    if (value is num) {
      final dbl = value.toDouble();
      if (dbl.isFinite &&
          dbl == dbl.truncateToDouble() &&
          dbl.abs() < 1e15) {
        return dbl.toInt().toString();
      }
      return dbl.toString();
    }
    if (value is String) return value.trim();
    if (value is List) {
      // v54 多选：元素排序后以 \u0002 拼接（normalize 已排序，这里再排一次
      // 以防直调 canonicalValue 拿到未排序列表）。确定性、无歧义。
      final items = value.map((e) => canonicalValue(e)).toList()..sort();
      return items.join('\u0002');
    }
    return value?.toString() ?? '';
  }

  /// 两个值 map 在规范化意义上是否相等（差分比较用）。
  static bool equals(Map<String, dynamic>? a, Map<String, dynamic>? b) =>
      canonical(a) == canonical(b);

  /// 存储字符串 → 展示文本（编辑表单回显用）。
  ///
  /// 金额按 [fieldType] 无关的通用数字渲染（去掉无意义的尾随 0），日期保留
  /// ISO 字符串由 UI 层转本地化格式。
  static String? toDisplayString(dynamic value) {
    if (value == null) return null;
    if (value is num) return canonicalValue(value);
    if (value is String) {
      final t = value.trim();
      return t.isEmpty ? null : t;
    }
    if (value is List) {
      // v54 多选：以 ", " 连接各选项值（多设备/多语言下中性）。
      final items = [
        for (final e in value)
          if (canonicalValue(e).isNotEmpty) canonicalValue(e),
      ];
      return items.isEmpty ? null : items.join(', ');
    }
    return value.toString();
  }

  /// 展示文本 → 值（表单录入回写用）。空白输入返回 null（= 未填/清空）。
  ///
  /// [fieldType] 为 [CustomFieldType.amount] 时解析失败返回 null。
  static dynamic fromInput(String fieldType, String? input) {
    final raw = input?.trim() ?? '';
    if (raw.isEmpty) return null;
    if (fieldType == CustomFieldType.amount) {
      final parsed = double.tryParse(raw);
      if (parsed == null || !parsed.isFinite) return null;
      return parsed;
    }
    return raw;
  }
}

/// v54 自定义字段「选项列表」的编解码与规范化（定义侧数据）。
///
/// 选项以 JSON 字符串数组落在 `custom_field_definitions.options_json`
/// （`NULL` = 无选项）。每个选项**只有一个字符串** —— 它既是存储值也是显示名
/// （本项目不做「选项值 + 选项名称」双字段，避免历史值需按 id 反查）。
///
/// 与 [CustomFieldValueCodec] 同哲学：
/// - **空即缺失**：`NULL` / 空数组在 [canonical] 下都是 `''`；
/// - **确定性表示**：**保序**（顺序即展示顺序，两端由定义同步保持一致），
///   指纹直接按序拼接。数组值经 [normalize] 去重、剔空后落库。
class CustomFieldOptionsCodec {
  CustomFieldOptionsCodec._();

  /// 解析存储字符串 → 选项列表。坏数据一律返回空列表且绝不抛。
  static List<String> decode(String? raw) {
    if (raw == null) return const [];
    final s = raw.trim();
    if (s.isEmpty) return const [];
    try {
      final decoded = jsonDecode(s);
      if (decoded is List) return normalize(decoded);
    } catch (_) {
      // 坏数据按"无选项"处理，静默降级。
    }
    return const [];
  }

  /// 选项列表 → 存储字符串。规范化后为空 → null（调用方据此把列写 NULL）。
  static String? encode(List<String>? options) {
    final norm = normalize(options ?? const []);
    if (norm.isEmpty) return null;
    return jsonEncode(norm);
  }

  /// 规范化：逐项 trim、剔除空项与非字符串、去重（**保序**）。
  static List<String> normalize(List<dynamic> options) {
    final seen = <String>{};
    final out = <String>[];
    for (final o in options) {
      if (o is! String) continue;
      final t = o.trim();
      if (t.isEmpty) continue;
      if (!seen.add(t)) continue;
      out.add(t);
    }
    return out;
  }

  /// 规范化比较串（指纹白名单用）。null / 空列表都返回 `''`（空即缺失）。
  static String canonical(List<dynamic>? options) =>
      normalize(options ?? const []).join('\u0001');
}
