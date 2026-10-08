/// 行情异常分类。
///
/// **刻意是枚举而不是自由文本**：编排层要按类别决定降级策略
/// （未配置 → 提示去设置；不支持市场 → 跳过该持仓；限流 → 退避到下一个窗口；
/// 网络 → 保留旧缓存重试），而 UI 文案由应用层按类别映射 l10n
/// （接口层不塞面向用户的文案）。
enum QuoteErrorKind {
  /// 行情源未配置（缺 API Key / 未选源）
  notConfigured,

  /// 该市场不被当前行情源支持
  unsupportedMarket,

  /// 网络失败（超时 / 连接失败 / 非 2xx）
  network,

  /// 被限流（429 等），应按退避窗口重试
  rateLimited,

  /// 响应解析失败（结构变了 / 字段缺失 / 非预期格式）
  parse,

  /// 其它未归类错误
  unknown,
}

/// 行情源统一异常。所有 [QuoteProvider] 实现都应抛它（而不是各自的异常类型），
/// 这样编排层只需 catch 一种。
class QuoteException implements Exception {
  const QuoteException(this.kind, this.message, {this.cause});

  final QuoteErrorKind kind;

  /// 开发者可读的诊断信息（**不是**面向用户的文案）
  final String message;

  final Object? cause;

  @override
  String toString() =>
      'QuoteException(${kind.name}): $message${cause == null ? '' : ' ← $cause'}';
}
