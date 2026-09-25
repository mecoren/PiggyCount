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

  static const List<String> all = [amount, text, date];

  static bool isValid(String type) => all.contains(type);
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

  /// 规范化：裁掉空键/空值，只保留可承载进 JSON 的标量。
  ///
  /// - `null`、空白字符串 → 剔除（语义 = 该字段未填）
  /// - 数值 NaN/Infinity → 剔除（非法金额）
  /// - 嵌套 map/list → 剔除（值列只承载标量；未来若需复杂类型请先扩协议）
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
  /// 返回 null 表示该值不该被承载：null、空白串、非有限数、非标量
  /// （嵌套 map/list 等）。**金额 0 是合法值**，返回 0.0。
  static dynamic normalizeValue(dynamic value) {
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
