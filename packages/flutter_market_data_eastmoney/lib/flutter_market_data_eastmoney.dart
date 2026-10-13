/// PiggyCount 行情源子包：东方财富（Eastmoney）。
///
/// 实现 [`QuoteProvider`] 契约，覆盖 A 股（沪/深）、港股、场外基金。
/// 免密钥的公开源；所有失败一律抛 [`QuoteException`]（选对 [`QuoteErrorKind`]），
/// 「未命中」的标的（代码合法但源无数据）则不出现在返回 map 里，由编排层保留旧缓存。
library;

export 'src/eastmoney_quote_provider.dart';
export 'src/eastmoney_codec.dart';
