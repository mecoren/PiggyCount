import 'quote.dart';
import 'quote_capability.dart';

/// 行情源统一接口。
///
/// 与 `flutter_cloud_sync` 的 `CloudProvider` / `flutter_ai_kit` 的 provider 接口
/// 同构：本包只定义契约，具体行情商（东方财富 / Yahoo / CoinGecko …）各写自己的
/// 子包。接口签名**不依赖任何应用主工程类型**（币种、市场一律用字符串），
/// 保证子包能独立复用、不与 `lib/` 耦合。
///
/// 实现约定：
/// - 所有失败一律抛 [QuoteException]（不要抛裸 `Exception`），编排层只 catch 一种；
/// - [fetchQuotes] 返回**命中的子集**（未拉到的标的不出现在 map 里），
///   编排层据此保留旧缓存、绝不写脏值；
/// - 不要在这里做节流 / 缓存 / 落库 —— 那是编排层（`QuoteService`）的职责，
///   行情源只负责「把请求变成价格」。
abstract class QuoteProvider {
  /// 稳定标识，用于持久化用户选择与快照里的 `quote_source_id`
  /// （如 `manual` / 将来的 `eastmoney`）。**改它等于换源**，旧缓存按源区分。
  String get providerId;

  /// 开发者可读名（如 `Eastmoney`）。
  ///
  /// ⚠️ **不是面向用户的文案**：设置页必须用 [providerId] 映射 l10n key，
  /// 不要把这个字符串直接渲染出去（否则中文环境下会出现英文源名）。
  String get providerName;

  /// 能力声明
  QuoteCapability get capability;

  /// 初始化（凭据等）。默认无操作 —— 免密钥的公开源无需重写。
  ///
  /// 抛 [QuoteException]（kind = `notConfigured`）表示配置无效。
  Future<void> initialize(Map<String, dynamic> config) async {}

  /// 拉取行情。返回 `QuoteRequestItem.key → Quote`。
  Future<Map<String, Quote>> fetchQuotes(QuoteRequest request);

  /// 释放资源（连接池 / 定时器）。默认无操作。
  Future<void> dispose() async {}
}
