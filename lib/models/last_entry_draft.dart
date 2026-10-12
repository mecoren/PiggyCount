import '../data/db.dart';

/// 记账抽屉「带出上一笔」的一次性载荷。
///
/// 由 `TransactionEditorPage` 从「本机最近录入的一笔同类型交易」
/// （`TransactionRepository.getLastRecordedTransaction`）组装而成，交给记账表单
/// 装填。**只有除金额外的字段**：金额 / 原始金额 / 折算金额 / 汇率 / 发生日期 /
/// 附件一律不带出（用户口径：复刻上一笔时只需重填金额，日期保持今天）。
///
/// 为什么需要独立值对象而不是直接把 `Transaction` 传下去：
/// - 载荷里的 [category] / [accountId] 已经过「存在性 + 类型 + 隐藏 + 币种」
///   校验，可选字段为空是**有意义的结论**（该项不带出），而不是「源行没填」；
/// - [tagIds] 已按现存标签过滤，[customValues] 已解码，UI 侧无需再查库；
/// - [kind] 自带类型，供表单守卫 —— 快捷形态下支出 / 收入两份表单在
///   `IndexedStack` 里同时保活，同一份载荷会同时到达两者，必须按类型丢弃。
class LastEntryDraft {
  /// 来源类型（`expense` / `income`）。与表单的 `transactionKind` 不等时应丢弃。
  final String kind;

  /// 带出的分类（**已解析的对象**，不是 id）：装配方已经查库并校验过存在性与
  /// 类型，表单直接落进 `_category` 即可，不必再等一次异步查询。
  /// `null` = 不带出（源未选 / 已被删除 / 类型不符）。
  final Category? category;

  /// 带出的账户；`null` = 不带出（源未选 / 已删除 / 已隐藏 / 币种不符）。
  final int? accountId;

  /// 带出的备注。
  final String? note;

  /// 备注的敏感标记（设备本地标记，不参与同步）。
  ///
  /// 随备注一起带出：同一段文案沿用同一隐私处理，方向是安全侧（宁可可多掩码）。
  final bool noteSensitive;

  /// 带出的标签 id（已过滤掉不存在的标签，避免保存时悬空外键）。
  final List<int> tagIds;

  /// 不计入收支。
  final bool excludeFromStats;

  /// 不计入预算。
  final bool excludeFromBudget;

  /// 带出的币种（ISO 大写）；`null` = 不带出（源未指定，走账户 / 本位币推导）。
  final String? currencyCode;

  /// 带出的自定义字段值（fieldSyncId → value），已解码。
  final Map<String, dynamic> customValues;

  const LastEntryDraft({
    required this.kind,
    this.category,
    this.accountId,
    this.note,
    this.noteSensitive = false,
    this.tagIds = const [],
    this.excludeFromStats = false,
    this.excludeFromBudget = false,
    this.currencyCode,
    this.customValues = const {},
  });
}
